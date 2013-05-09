require 'fiber'
require 'nats/client'
require 'uri'
require 'uaa'
require 'services/api/const'
require 'catalog_manager_base'

module VCAP
  module Services
    class CatalogManagerV2 < VCAP::Services::CatalogManagerBase
      HTTP_UNAUTHENTICATED_CODE = 401

      attr_reader :logger

      def initialize(opts)
        super(opts)

        @opts = opts
        @test_mode = opts[:test_mode] || false

        required_opts = %w(cloud_controller_uri service_auth_tokens token gateway_name logger).map { |o| o.to_sym }
        required_opts.concat( %w(uaa_endpoint uaa_client_id uaa_client_auth_credentials).map { |o| o.to_sym } ) if !@test_mode

        missing_opts = required_opts.select {|o| !opts.has_key? o}
        raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?

        @gateway_name          = opts[:gateway_name]
        @cld_ctrl_uri          = opts[:cloud_controller_uri]
        @service_list_uri      = "/v2/services?inline-relations-depth=2"
        @offering_uri          = "/v2/services"
        @service_plans_uri     = "/v2/service_plans"
        @service_instances_uri = "/v2/service_instances"
        @service_bindings_uri  = "/v2/service_bindings"
        @handle_guid         = {}

        @logger               = opts[:logger]

        @service_auth_tokens  = opts[:service_auth_tokens]

        refresh_client_auth_token if !@test_mode # use for specs only

        @gateway_stats = {}
        @gateway_stats_lock = Mutex.new
        snapshot_and_reset_stats
      end

      def refresh_client_auth_token
        # Load the auth token to be sent out in Authorization header when making CCNG-v2 requests
        credentials = @opts[:uaa_client_auth_credentials]
        client_id                   = @opts[:uaa_client_id]

        if ENV["AUTHORIZATION_TOKEN"]
          uaa_client_auth_token = ENV["AUTHORIZATION_TOKEN"]
        else
          ti = CF::UAA::TokenIssuer.new(@opts[:uaa_endpoint], client_id)
          token = ti.implicit_grant_with_creds(credentials).info
          uaa_client_auth_token = "#{token["token_type"]} #{token["access_token"]}"
          expire_time = token["expires_in"].to_i
          logger.info("Successfully refresh auth token for:\
                       #{credentials[:username]}, token expires in \
                       #{expire_time} seconds.")
        end

        @cc_req_hdrs = {
          'Content-Type' => 'application/json',
          'Authorization' => uaa_client_auth_token
        }
      end

      class RetriableCloudControllerHitter
        attr_reader :max_attempts, :logger, :http_request_creator

        def initialize(max_attempts, http_request_creator, logger)
          @max_attempts = max_attempts
          @logger       = logger
          @http_request_creator = http_request_creator
        end

        def make_request(args, failed_callback, &block)
          attempts=0
          while true
            attempts += 1
            logger.debug("#{args[:method].upcase} - #{args[:uri]}")
            http = http_request_creator.call(args)
            if attempts < max_attempts &&
              http.response_header.status == HTTP_UNAUTHENTICATED_CODE
              failed_callback.call
            else
              block.call(http)
              return  http
            end
          end
        end
      end

      # wrapper of create_http_request, refresh @cc_req_hdrs if cc returns 401
      def cc_http_request(args, &block)
        retriable_hitter = RetriableCloudControllerHitter.new(args[:max_attempts]||2,
                                                              self.method(:create_http_request),
                                                              logger)
        args[:uri] = "#{@cld_ctrl_uri}#{args[:uri]}"
        retriable_hitter.make_request(args, method(:refresh_client_auth_token), &block)
      end

      def create_key(label, version, provider)
        "#{label}_#{provider}"
      end

      def perform_multiple_page_get(seed_url, description)
        url = seed_url

        logger.info("Fetching #{description} from: #{seed_url}")

        page_num = 1
        while  !url.nil? do
          cc_http_request(:uri => url,
                          :method => "get",
                          :head => @cc_req_hdrs,
                          :need_raise => true) do |http|
            result = nil
            if (200..299) === http.response_header.status
              result = JSON.parse(http.response)
            else
              raise "CCNG Catalog Manager: #{@gateway_name} - Multiple page fetch via: #{url} failed: (#{http.response_header.status}) - #{http.response}"
            end

            raise "CCNG Catalog Manager: Failed parsing http response: #{http.response}" if result == nil

            result["resources"].each { |r| yield r if block_given? }

            page_num += 1

            url = result["next_url"]
            logger.debug("CCNG Catalog Manager: Fetching #{description} pg. #{page_num} from: #{url}") unless url.nil?
          end
        end
      end

      ######### Stats Handling #########

      def snapshot_and_reset_stats
        stats_snapshot = {}
        @gateway_stats_lock.synchronize do
          stats_snapshot = @gateway_stats.dup

          @gateway_stats[:refresh_catalog_requests]     = 0
          @gateway_stats[:refresh_catalog_failures]     = 0
          @gateway_stats[:refresh_cc_services_requests] = 0
          @gateway_stats[:refresh_cc_services_failures] = 0
          @gateway_stats[:advertise_services_requests]  = 0
          @gateway_stats[:advertise_services_failures]  = 0
        end
        stats_snapshot
      end

      def update_stats(op_name, failed)
        op_key = "#{op_name}_requests".to_sym
        op_failure_key = "#{op_name}_failures".to_sym

        @gateway_stats_lock.synchronize do
          @gateway_stats[op_key] += 1
          @gateway_stats[op_failure_key] += 1 if failed
        end
      end

      ######### Catalog update functionality #######
      def update_catalog(activate, catalog_loader, after_update_callback = nil)
        f = Fiber.new do
          # Load offering from ccdb
          logger.info("CCNG Catalog Manager: Loading services from CC")
          failed = false
          begin
            @catalog_in_ccdb = load_registered_services_from_cc
          rescue => e
            failed = true
            logger.error("CCNG Catalog Manager: Failed to get currently advertized offerings from cc: #{e.inspect}")
            logger.error(e.backtrace)
          ensure
            update_stats("refresh_cc_services", failed)
          end

          # Load current catalog (e.g. config, external marketplace etc...)
          logger.info("CCNG Catalog Manager: Loading current catalog...")
          failed = false
          begin
            @current_catalog = catalog_loader.call()
          rescue => e1
            failed = true
            logger.error("CCNG Catalog Manager: Failed to get latest service catalog: #{e1.inspect}")
            logger.error(e1.backtrace)
          ensure
            update_stats("refresh_catalog", failed)
          end

          # Update
          logger.info("CCNG Catalog Manager: Updating Offerings...")
          advertise_services(activate)

          # Post-update processing
          if after_update_callback
            logger.info("CCNG Catalog Manager: Invoking after update callback...")
            after_update_callback.call()
          end
        end
        f.resume
      end


      def generate_cc_advertise_offering_request(svc, active = true)
        req = {}

        req[:unique_id]   = svc["unique_id"]
        req[:label]       = svc["id"]
        req[:version]     = svc["version"]
        req[:active]      = active
        req[:description] = svc["description"]
        req[:provider]    = svc["provider"]

        req[:acls]        = svc["acls"]
        req[:url]         = svc["url"]
        req[:timeout]     = svc["timeout"]
        req[:extra]       = svc["extra"]

        # NOTE: In CCNG, multiple versions is expected to be supported via multiple plans
        # The gateway will have to maintain a mapping of plan-name to version so that
        # the correct version will be provisioned
        plans = {}
        if svc["plans"].is_a?(Array)
          svc["plans"].each { |p|
            # If not specified, assume all plans are free
            plans[p] = { "name" => p, "description" => "#{p} plan", "free" => true }
          }
        elsif svc["plans"].is_a?(Hash)
          svc["plans"].each { |k, v|
            plan_name = k.to_s
            plans[plan_name] = {
              "unique_id"   => v[:unique_id],
              "name"        => plan_name,
              "description" => v[:description],
              "free"        => v[:free],
              "extra"       => v[:extra],
            }
          }
        else
          raise "Plans must be either an array or hash(plan_name => description)"
        end

        [ req, plans ]
      end

      def load_registered_services_from_cc
        logger.debug("CCNG Catalog Manager: Getting services listing from cloud_controller")
        registered_services = {}

        perform_multiple_page_get(@service_list_uri, "Registered Offerings") { |s|
          key = "#{s["entity"]["label"]}_#{s["entity"]["provider"]}"

          if @service_auth_tokens.has_key?(key.to_sym)
            entity = s["entity"]

            plans = {}
            logger.debug("CCNG Catalog Manager: Getting service plans for: #{entity["label"]}/#{entity["provider"]}")
            perform_multiple_page_get(entity["service_plans_url"], "Service Plans") { |p|
              plans[p["entity"]["name"]] = {
                "guid"        => p["metadata"]["guid"],
                "name"        => p["entity"]["name"],
                "description" => p["entity"]["description"],
                "free"        => p["entity"]["free"]
              }
            }

            svc = {
              "id"          => entity["label"],
              "description" => entity["description"],
              "provider"    => entity["provider"],
              "version"     => entity["version"],
              "url"         => entity["url"],
              "info_url"    => entity["info_url"],
              "plans"       => plans
            }

            registered_services[key] = {
              "guid"    => s["metadata"]["guid"],
              "service" => svc,
            }

            logger.debug("CCNG Catalog Manager: Found #{key} = #{registered_services[key].inspect}")
          end
        }

        registered_services
      end

      def advertise_service_to_cc(offering, guid, plans_to_add, plans_to_update)
        service_guid = add_or_update_offering(offering, guid)
        return false if service_guid.nil?

        return true if !offering[:active] # If deactivating, don't update plans

        logger.debug("CCNG Catalog Manager: Processing plans for: #{service_guid} -Add: #{plans_to_add.size} plans, Update: #{plans_to_update.size} plans")

        # Add plans to add
        plans_to_add.each { |plan|
          plan["service_guid"] = service_guid
          add_or_update_plan(plan)
        }

        # Update plans
        plans_to_update.each { |plan_guid, plan|
          add_or_update_plan(plan, plan_guid)
        }
        return true
      end

      def process_plans(plans_from_catalog, plans_already_in_cc)
        plans_to_add = []
        plans_to_update = {}

        catalog_plans = plans_from_catalog.keys
        registered_plans = plans_already_in_cc.keys

        # Update active plans
        # active plans = intersection of (catalog_plans & registered_plans)
        active_plans = catalog_plans & registered_plans
        active_plans.each { |plan_name|
          plan_details = plans_from_catalog[plan_name]

          # The changeable aspects are the description and free flag
          if (plan_details["description"] != plans_already_in_cc[plan_name]["description"] ||
              plan_details["free"] != plans_already_in_cc[plan_name]["free"] ||
              plan_details["extra"] != plans_already_in_cc[plan_name]["extra"])
            plan_guid = plans_already_in_cc[plan_name]["guid"]
            plans_to_update[plan_guid] = {
              "name"        => plan_name,
              "description" => plan_details["description"],
              "free"        => plan_details["free"],
              "extra"        => plan_details["extra"],
            }
            logger.debug("CCNG Catalog Manager: Updating plan: #{plan_name} to: #{plans_to_update[plan_guid].inspect}")
          else
            logger.debug("CCNG Catalog Manager: No changes to plan: #{plan_name}")
          end
        }

        # Add new plans -> catalog_plans - active_plans
        new_plans = catalog_plans - active_plans
        new_plans.each { |plan_name|
          logger.debug("CCNG Catalog Manager: Adding new plan: #{plans_from_catalog[plan_name].inspect}")
          plans_to_add << plans_from_catalog[plan_name]
        }

        # TODO: What to do with deactivated plans?
        # Should handle this manually for now?
        deactivated_plans = registered_plans - active_plans
        logger.warn("CCNG Catalog Manager: Found #{deactivated_plans.size} deactivated plans: - #{deactivated_plans.inspect}") unless deactivated_plans.empty?

        [ plans_to_add, plans_to_update ]
      end

      def add_or_update_offering(offering, guid)
        update = !guid.nil?
        uri = update ? "#{@offering_uri}/#{guid}" : @offering_uri
        service_guid = nil

        logger.debug("CCNG Catalog Manager: #{update ? "Update" : "Advertise"} service offering #{offering.inspect} to cloud_controller: #{uri}")

        method = update ? "put" : "post"
        if method == 'put'
          offering.delete(:unique_id)
        end
        cc_http_request(:uri => uri,
                        :method => method,
                        :head => @cc_req_hdrs,
                        :body => Yajl::Encoder.encode(offering)) do |http|
          if ! http.error
            if (200..299) === http.response_header.status
              response = JSON.parse(http.response)
              logger.info("CCNG Catalog Manager: Advertise offering response (code=#{http.response_header.status}): #{response.inspect}")
              service_guid = response["metadata"]["guid"]
            else
              logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}, status=#{http.response_header.status}")
            end
          else
            logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}: #{http.error}")
          end
        end

        return service_guid
      end


      def delete_offering(id, version, provider)

        # This is TERRIBLY inefficient but this function is not expected to be called
        # very often, so fine for now.
        # TODO: 2 possible approaches:
        #  1. CCNG could support more query parameters, so simple things such as offering guid could be easily looked up
        #  2. We maintain a local cache of this information for static information such as label-provider -> guid mapping

        # find the service guid for the specified offering
        offering_key = "#{id}_#{provider}"

        registered_services = load_registered_services_from_cc
        offering_guid = registered_services[offering_key]["guid"] if registered_services.has_key?(offering_key)

        if !offering_guid
          logger.error("CCNG Catalog Manager: Offering #{id} (#{provider}) is not registered")
          return
        end

        uri = "#{@offering_uri}/#{offering_guid}"
        logger.info("CCNG Catalog Manager: Deleting service offering:#{id} (#{provider}) via #{uri}")

        cc_http_request(:uri => uri,
                        :method => "delete",
                        :head => @cc_req_hdrs) do |http|
          if ! http.error
            if (200..299) === http.response_header.status
              logger.info("CCNG Catalog Manager: Successfully deleted offering: #{id} (#{provider})")
              return true
            else
              logger.error("CCNG Catalog Manager: Failed to delete offering: #{id} (#{provider}), status=#{http.response_header.status}")
            end
          else
            logger.error("CCNG Catalog Manager: Failed to delete offering: #{id} (#{provider}) due to: #{http.error}")
          end
        end

        return false
      end

      # fetch all handles for instances and bindings for caching on service gateway
      # this function allows user gateway to fetch all the instance and binding handles
      # from cloud_controller_ng with a certain service label
      def fetch_handles_from_cc(service_label, after_fetch_callback)
        logger.info("CCNG Catalog Manager:(v2) Fetching all handles from cloud controller...")
        return unless after_fetch_callback

        @fetching_handles = true

        instance_handles = fetch_all_instance_handles_from_cc
        binding_handles = fetch_all_binding_handles_from_cc(instance_handles)
        logger.info("CCNG Catalog Manager:(v2) Successfully fetched all handles from cloud controller...")

        handles = [instance_handles, binding_handles]
        handles = VCAP::Services::Api::ListHandlesResponse.decode(Yajl::Encoder.encode({:handles => handles}))
        after_fetch_callback.call(handles) if after_fetch_callback
      ensure
        @fetching_handles = false
      end

      def fetch_all_instance_handles_from_cc
        logger.info("CCNG Catalog Manager:(v2) Fetching all service instance handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}")
        instance_handle_list = {}

        registered_services = load_registered_services_from_cc

        registered_services.each_value do |registered_service|
          registered_service['service']['plans'].each_value do |plan_details|
            plan_guid = plan_details["guid"]
            instance_handles_query = "?q=service_plan_guid:#{plan_guid}"
            instance_handles = fetch_instance_handles_from_cc(instance_handles_query)
            instance_handle_list.merge!(instance_handles) if instance_handles
          end
        end
        logger.info("CCNG Catalog Manager:(v2) Successfully fetched all service instance handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}")
        instance_handle_list
      end

      def fetch_all_binding_handles_from_cc(instance_handles)
        logger.info("CCNG Catalog Manager:(v2) Fetching all service binding handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}")
        binding_handles_list = {}

        # currently we will fetch each binding handle according to instance handle
        # TODO: add a query parameter in ccng v2 to support query from service name to binding handle;
        instance_handles.each do |instance_id, _|
          binding_handles_query = "?q=service_instance_guid:#{@handle_guid[instance_id]}"
          binding_handles = fetch_binding_handles_from_cc(binding_handles_query)
          binding_handles_list.merge!(binding_handles) if binding_handles
        end
        logger.info("CCNG Catalog Manager:(v2) Successfully fetched all service binding handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}")
        binding_handles_list
      end

      # fetch instance handles from cloud_controller_ng
      # this function allows users to get a dedicated set of instance handles
      # from cloud_controller_ng using a customized query for /v2/service_binding api
      #
      # @param string instance_handles_query
      def fetch_instance_handles_from_cc(instance_handles_query)
        logger.info("CCNG Catalog Manager:(v2) Fetching service instance handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}#{instance_handles_query}")

        instance_handles = {}
        # currently we are fetching all the service instances from different plans;
        # TODO: add a query parameter in ccng v2 to support a query from service name to instance handle;
        service_instance_uri = "#{@service_instances_uri}#{instance_handles_query}"

        perform_multiple_page_get(service_instance_uri, "service instance handles") do |resources|
          instance_info = resources['entity']
          instance_handles[instance_info['credentials']['name']] = instance_info
          @handle_guid[instance_info['credentials']['name']] = resources['metadata']['guid']
        end
        instance_handles
      rescue => e
        logger.error("CCNG Catalog Manager:(v2) Error decoding reply from gateway: #{e.backtrace}")
      end

      # fetch binding handles from cloud_controller_ng
      # this function allows users to get a dedicated set of binding handles
      # from cloud_controller_ng using a customized query for /v2/service_binding api
      #
      # @param string binding_handles_query
      def fetch_binding_handles_from_cc(binding_handles_query)
        logger.info("CCNG Catalog Manager:(v2) Fetching service binding handles from cloud controller: #{@cld_ctrl_uri}#{@service_bindings_uri}#{binding_handles_query}")

        binding_handles = {}
        binding_handles_uri = "#{@service_bindings_uri}#{binding_handles_query}"

        perform_multiple_page_get(binding_handles_uri, "service binding handles") do |resources|
          binding_info = resources['entity']
          binding_handles[binding_info['gateway_name']] = binding_info
          @handle_guid[binding_info['gateway_name']] = resources['metadata']['guid']
        end
        binding_handles
      rescue => e
        logger.error("CCNG Catalog Manager:(v2) Error decoding reply from gateway: #{e}")
      end

      def update_handle_uri(handle)
        if handle['gateway_name'] == handle['credentials']['name']
          return "#{@service_instances_uri}/internal/#{handle['gateway_name']}"
        else
          return "#{@service_bindings_uri}/internal/#{handle['gateway_name']}"
        end
      end

      def update_handle_in_cc(service_label, handle, on_success_callback, on_failure_callback)
        logger.debug("CCNG Catalog Manager:(v1) Update service handle: #{handle.inspect}")
        if not handle
          on_failure_callback.call if on_failure_callback
          return
        end

        uri = update_handle_uri(handle)

        # replace the "configuration" field with "gateway_data", and remove "gateway_name" for the internal update
        handle["gateway_data"] = handle.delete("configuration")
        handle.delete("gateway_name")

        # manipulate handle to be a handle that is acceptable to ccng
        cc_handle = {
          "token"        => @service_auth_tokens.values[0],
          "credentials"  => handle["credentials"],
          "gateway_data" => handle["gateway_data"],
        }

        cc_http_request(:uri => uri,
                        :method => "put",
                        :head => @cc_req_hdrs,
                        :body => Yajl::Encoder.encode(cc_handle)) do |http|
          if ! http.error
            if http.response_header.status == 200
              logger.info("CCNG Catalog Manager:(v1) Successful update handle #{handle["service_id"]}")
              on_success_callback.call if on_success_callback
            else
              logger.error("CCNG Catalog Manager:(v1) Failed to update handle #{handle["service_id"]}: http status #{http.response_header.status}")
              on_failure_callback.call if on_failure_callback
            end
          else
            logger.error("CCNG Catalog Manager:(v1) Failed to update handle #{handle["service_id"]}: #{http.error}")
            on_failure_callback.call if on_failure_callback
          end
        end
      end

      private
      def add_or_update_plan(plan, plan_guid = nil)
        add_plan = plan_guid.nil?
        uri = add_plan ? @service_plans_uri : "#{@service_plans_uri}/#{plan_guid}"
        logger.info("CCNG Catalog Manager: #{add_plan ? "Add new plan" : "Update plan (guid: #{plan_guid}) to"}: #{plan.inspect} via #{uri}")

        method = add_plan ? "post" : "put"
        cc_http_request(:uri => uri,
                        :method => method,
                        :head => @cc_req_hdrs,
                        :body => Yajl::Encoder.encode(plan)) do |http|
          if ! http.error
            if (200..299) === http.response_header.status
              logger.info("CCNG Catalog Manager: Successfully #{add_plan ? "added" : "updated"} service plan: #{plan.inspect}")
              return true
            else
              logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}, status=#{http.response_header.status}")
            end
          else
            logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}: #{http.error}")
          end
        end

        return false
      end

      def advertise_services(active=true)
        logger.info("CCNG Catalog Manager: #{active ? "Activate" : "Deactivate"} services...")

        if !(@current_catalog && @catalog_in_ccdb)
          logger.warn("CCNG Catalog Manager: Cannot advertise services since the offerings list from either the catalog or ccdb could not be retrieved")
          return
        end

        # Set services missing from catalog offerings to inactive
        # Process all services currently in catalog
        # NOTE: Existing service offerings in ccdb will have a guid and require a PUT operation for update
        # New service offerings will not have guid and require POST operation for create

        registered_offerings = @catalog_in_ccdb.keys
        catalog_offerings = @current_catalog.keys
        logger.debug("CCNG Catalog Manager: Registered in ccng: #{registered_offerings.inspect}")
        logger.debug("CCNG Catalog Manager: Current catalog: #{catalog_offerings.inspect}")

        # POST updates to active and disabled services
        # Active offerings is intersection of catalog and ccdb offerings, we only need to update these
        active_offerings = catalog_offerings & registered_offerings
        active_offerings.each do |label|
          svc = @current_catalog[label]
          req, plans = generate_cc_advertise_offering_request(svc, active)
          guid = (@catalog_in_ccdb[label])["guid"]

          plans_to_add, plans_to_update = process_plans(plans, @catalog_in_ccdb[label]["service"]["plans"])
          logger.debug("CCNG Catalog Manager: plans_to_add = #{plans_to_add.inspect}")
          logger.debug("CCNG Catalog Manager: plans_to_update = #{plans_to_add.inspect}")

          logger.debug("CCNG Catalog Manager: Refresh offering: #{req.inspect}")
          advertise_service_to_cc(req, guid, plans_to_add, plans_to_update)
        end

        # Inactive offerings is ccdb_offerings - active_offerings
        inactive_offerings = registered_offerings - active_offerings
        inactive_offerings.each do |label|
          svc = @catalog_in_ccdb[label]
          guid = svc["guid"]
          service = svc["service"]

          req, plans = generate_cc_advertise_offering_request(service, false)

          logger.debug("CCNG Catalog Manager: Deactivating offering: #{req.inspect}")
          advertise_service_to_cc(req, guid, [], {}) # don't touch plans, just deactivate
        end

        # PUT new offerings (yet to be registered) = catalog_offerings - active_offerings
        new_offerings = catalog_offerings - active_offerings
        new_offerings.each do |label|
          svc = @current_catalog[label]
          req, plans = generate_cc_advertise_offering_request(svc, active)
          plans_to_add = plans.values
          logger.debug("CCNG Catalog Manager: plans_to_add = #{plans_to_add.inspect}")


          logger.debug("CCNG Catalog Manager: Add new offering: #{req.inspect}")
          advertise_service_to_cc(req, nil, plans_to_add, {}) # nil guid => new service, so add all plans
        end

        active_count = active ? active_offerings.size + new_offerings.size : 0
        disabled_count = inactive_offerings.size + (active ? 0 : active_offerings.size)

        logger.info("CCNG Catalog Manager: Found #{active_offerings.size} active, #{disabled_count} disabled and #{new_offerings.size} new service offerings")

        @gateway_stats_lock.synchronize do
          @gateway_stats[:active_offerings] = active_count
          @gateway_stats[:disabled_services] = disabled_count
        end
      end
    end
  end
end
