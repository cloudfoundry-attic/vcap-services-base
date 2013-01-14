require 'fiber'
require 'nats/client'
require 'uri'
require 'uaa'
require 'services/api/const'
require 'catalog_manager_base'

module VCAP
  module Services
    class CatalogManagerV2 < VCAP::Services::CatalogManagerBase

      def initialize(opts)
        super(opts)

        @test_mode = opts[:test_mode] || false

        required_opts = %w(cloud_controller_uri service_auth_tokens token gateway_name logger).map { |o| o.to_sym }
        required_opts.concat( %w(uaa_endpoint uaa_client_id uaa_client_auth_credentials).map { |o| o.to_sym } ) if !@test_mode

        missing_opts = required_opts.select {|o| !opts.has_key? o}
        raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?

        @gateway_name         = opts[:gateway_name]
        @cld_ctrl_uri         = opts[:cloud_controller_uri]
        @service_list_uri     = "#{@cld_ctrl_uri}/v2/services?inline-relations-depth=2"
        @offering_uri         = "#{@cld_ctrl_uri}/v2/services"
        @service_plans_uri    = "#{@cld_ctrl_uri}/v2/service_plans"

        @logger               = opts[:logger]

        @service_auth_tokens  = opts[:service_auth_tokens]

        # Used ONLY for invoking list/update handles v1 api
        # TODO: remove this
        gateway_token_hdr = VCAP::Services::Api::GATEWAY_TOKEN_HEADER
        @cc_req_hdrs_for_v1_api = {
          'Content-Type'    => 'application/json',
          gateway_token_hdr => opts[:token]
        }

        if !@test_mode # use for specs only
          # Load the auth token to be sent out in Authorization header when making CCNG-v2 requests
          uaa_client_auth_credentials = opts[:uaa_client_auth_credentials]
          client_id                   = opts[:uaa_client_id]

          ti = CF::UAA::TokenIssuer.new(opts[:uaa_endpoint], client_id)
          token = ti.implicit_grant_with_creds(uaa_client_auth_credentials).info
          uaa_client_auth_token = "#{token["token_type"]} #{token["access_token"]}"
          @logger.info("Successfully retrieved auth token for: #{uaa_client_auth_credentials[:username]}")

          @cc_req_hdrs = {
            'Content-Type' => 'application/json',
            'Authorization' => uaa_client_auth_token
          }
        end

        @gateway_stats = {}
        @gateway_stats_lock = Mutex.new
        snapshot_and_reset_stats
      end

      def create_key(label, version, provider)
        "#{label}_#{provider}"
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

      def update_catalog(activate, load_catalog_callback, after_update_callback = nil)
        f = Fiber.new do
          # Load offering from ccdb
          @logger.info("CCNG Catalog Manager: Loading services from CC")
          failed = false
          begin
            @catalog_in_ccdb = load_registered_services_from_cc
          rescue => e
            failed = true
            @logger.error("CCNG Catalog Manager: Failed to get currently advertized offerings from cc: #{e.inspect}")
          ensure
            update_stats("refresh_cc_services", failed)
          end

          # Load current catalog (e.g. config, external marketplace etc...)
          @logger.info("CCNG Catalog Manager: Loading current catalog...")
          failed = false
          begin
            @current_catalog = load_catalog_callback.call()
          rescue => e1
            failed = true
            @logger.error("CCNG Catalog Manager: Failed to get latest service catalog: #{e1.inspect}")
          ensure
            update_stats("refresh_catalog", failed)
          end

          # Update
          @logger.info("CCNG Catalog Manager: Updating Offerings...")
          advertise_services(activate)

          # Post-update processing
          if after_update_callback
            @logger.info("CCNG Catalog Manager: Invoking after update callback...")
            after_update_callback.call()
          end
        end
        f.resume
      end

      def advertise_services(active=true)
        @logger.info("CCNG Catalog Manager: #{active ? "Activate" : "Deactivate"} services...")
        if !(@current_catalog && @catalog_in_ccdb)
          @logger.warn("CCNG Catalog Manager: Cannot advertise services since the offerings list from either the catalog or ccdb could not be retrieved")
          return
        end

        # Set services missing from catalog offerings to inactive
        # Process all services currently in catalog
        # NOTE: Existing service offerings in ccdb will have a guid and require a PUT operation for update
        # New service offerings will not have guid and require POST operation for create

        registered_offerings = @catalog_in_ccdb.keys
        catalog_offerings = @current_catalog.keys
        @logger.debug("CCNG Catalog Manager: Registered in ccng: #{registered_offerings.inspect}, Current catalog: #{catalog_offerings.inspect}")

        # POST updates to active and disabled services
        # Active offerings is intersection of catalog and ccdb offerings, we only need to update these
        active_offerings = catalog_offerings & registered_offerings
        active_offerings.each do |label|
          svc = @current_catalog[label]
          req, plans = generate_cc_advertise_offering_request(svc, active)
          guid = (@catalog_in_ccdb[label])["guid"]

          plans_to_add, plans_to_update = process_plans(plans, @catalog_in_ccdb[label]["service"]["plans"])

          @logger.debug("CCNG Catalog Manager: Refresh offering: #{req.inspect}")
          advertise_service_to_cc(req, guid, plans_to_add, plans_to_update)
        end

        # Inactive offerings is ccdb_offerings - active_offerings
        inactive_offerings = registered_offerings - active_offerings
        inactive_offerings.each do |label|
          svc = @catalog_in_ccdb[label]
          guid = svc["guid"]
          service = svc["service"]

          req, plans = generate_cc_advertise_offering_request(service, false)

          @logger.debug("CCNG Catalog Manager: Deactivating offering: #{req.inspect}")
          advertise_service_to_cc(req, guid, [], {}) # don't touch plans, just deactivate
        end

        # PUT new offerings (yet to be registered) = catalog_offerings - active_offerings
        new_offerings = catalog_offerings - active_offerings
        new_offerings.each do |label|
          svc = @current_catalog[label]
          req, plans = generate_cc_advertise_offering_request(svc, active)
          plans_to_add = plans.values

          @logger.debug("CCNG Catalog Manager: Add new offering: #{req.inspect}")
          advertise_service_to_cc(req, nil, plans_to_add, {}) # nil guid => new service, so add all plans
        end

        active_count = active ? active_offerings.size + new_offerings.size : 0
        disabled_count = inactive_offerings.size + (active ? 0 : active_offerings.size)

        @logger.info("CCNG Catalog Manager: Found #{active_offerings.size} active, #{disabled_count} disabled and #{new_offerings.size} new service offerings")

        @gateway_stats_lock.synchronize do
          @gateway_stats[:active_offerings] = active_count
          @gateway_stats[:disabled_services] = disabled_count
        end
      end

      def generate_cc_advertise_offering_request(svc, active = true)
        req = {}

        req[:label]       = svc["id"]
        req[:version]     = svc["version"]
        req[:active]      = active
        req[:description] = svc["description"]
        req[:provider]    = svc["provider"]

        req[:acls]        = svc["acls"]
        req[:url]         = svc["url"]
        req[:timeout]     = svc["timeout"]

        # NOTE: In CCNG, multiple versions is expected to be supported via multiple plans
        # The gateway will have to maintain a mapping of plan-name to version so that
        # the correct version will be provisioned
        plans = {}
        if svc["plans"].is_a?(Array)
          svc["plans"].each { |p|
            plans[p] = { "name" => p, "description" => "#{p} plan"}
          }
        elsif svc["plans"].is_a?(Hash)
          svc["plans"].each { |k, v|
            plan_name = k.to_s
            plans[plan_name] = { "name" => plan_name, "description" => v }
          }
        else
          raise "Plans must be either an array or hash(plan_name => description)"
        end

        [ req, plans ]
      end

      def load_registered_services_from_cc
        @logger.debug("CCNG Catalog Manager: Getting services listing from cloud_controller: #{@service_list_uri}")
        registered_services = {}

        req = create_http_request(:head => @cc_req_hdrs)

        f = Fiber.current
        http = EM::HttpRequest.new(@service_list_uri).get(req)
        http.callback { f.resume(http) }
        http.errback { f.resume(http) }
        Fiber.yield

        svcs = nil

        if http.error.empty?
          if http.response_header.status == 200
            svcs = JSON.parse(http.response)
          else
            raise "CCNG Catalog Manager: Failed to fetch #{@gateway_name} service from CC - status=#{http.response_header.status}"
          end
        else
          raise "CCNG Catalog Manager: Failed to fetch #{@gateway_name} service from CC: #{http.error}"
        end

        raise "CCNG Catalog Manager: Failed parsing http reponse when getting services listing from cc" if svcs == nil

        svcs["resources"].each do |s|
          key = "#{s["entity"]["label"]}_#{s["entity"]["provider"]}"

          if @service_auth_tokens.has_key?(key.to_sym)
            entity = s["entity"]

            plans = {}
            entity["service_plans"].each { |p|
              plans[p["entity"]["name"]] = {
                "guid"        => p["metadata"]["guid"],
                "name"        => p["entity"]["name"],
                "description" => p["entity"]["description"]
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

            @logger.debug("CCNG Catalog Manager: Found #{key} = #{registered_services[key].inspect}")
          end
        end

        registered_services
      end

      def advertise_service_to_cc(offering, guid, plans_to_add, plans_to_update)
        service_guid = add_or_update_offering(offering, guid)
        return false if service_guid.nil?

        return true if !offering[:active] # If deactivating, don't update plans

        @logger.debug("CCNG Catalog Manager: Processing plans for: #{service_guid} -Add: #{plans_to_add.size} plans, Update: #{plans_to_update.size} plans")

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

          # TODO: is this really necessary? keeping this for now
          # Currently the only changeable aspect is the descritption
          if plan_details["description"] != plans_already_in_cc[plan_name]["description"]
            plan_guid = plans_already_in_cc[plan_name]["guid"]
            plans_to_update[plan_guid] = { "name" => plan_name, "description" => plan_details["description"] }
            @logger.debug("CCNG Catalog Manager: Updating plan: #{plan_name} to: #{plans_to_update[plan_guid].inspect}")
          else
            @logger.debug("CCNG Catalog Manager: No changes to plan: #{plan_name}")
          end
        }

        # Add new plans -> catalog_plans - active_plans
        new_plans = catalog_plans - active_plans
        new_plans.each { |plan_name|
          @logger.debug("CCNG Catalog Manager: Adding new plan: #{plans_from_catalog[plan_name].inspect}")
          plans_to_add << plans_from_catalog[plan_name]
        }

        # TODO: What to do with deactivated plans?
        # Should handle this manually for now?
        deactivated_plans = registered_plans - active_plans
        @logger.warn("CCNG Catalog Manager: Found #{deactivated_plans.size} deactivated plans: - #{deactivated_plans.inspect}") unless deactivated_plans.empty?

        [ plans_to_add, plans_to_update ]
      end

      def add_or_update_offering(offering, guid)
        update = !guid.nil?
        uri = update ? "#{@offering_uri}/#{guid}" : @offering_uri

        @logger.debug("CCNG Catalog Manager: #{update ? "Update" : "Advertise"} service offering #{offering.inspect} to cloud_controller: #{uri}")

        req = create_http_request(
          :head => @cc_req_hdrs,
          :body => Yajl::Encoder.encode(offering)
        )

        f = Fiber.current
        conn = EM::HttpRequest.new(uri)

        http = update ? conn.put(req) : conn.post(req)
        http.callback { f.resume(http) }
        http.errback { f.resume(http) }

        Fiber.yield

        if http.error.empty?
          if (200..299) === http.response_header.status
            response = JSON.parse(http.response)
            @logger.info("CCNG Catalog Manager: Advertise offering response (code=#{http.response_header.status}): #{response.inspect}")
            return response["metadata"]["guid"]
          else
            @logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}, status=#{http.response_header.status}")
          end
        else
          @logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}: #{http.error}")
        end

        return nil
      end

      def add_or_update_plan(plan, plan_guid = nil)
        add_plan = plan_guid.nil?

        url = add_plan ? @service_plans_uri : "#{@service_plans_uri}/#{plan_guid}"
        @logger.info("CCNG Catalog Manager: #{add_plan ? "Add new plan" : "Update plan (guid: #{plan_guid}) to"}: #{plan.inspect} via #{url}")

        req = create_http_request(
          :head => @cc_req_hdrs,
          :body => Yajl::Encoder.encode(plan)
        )

        f = Fiber.current

        conn = EM::HttpRequest.new(url)
        http = add_plan ? conn.post(req) : conn.put(req)
        http.callback { f.resume(http) }
        http.errback { f.resume(http) }

        Fiber.yield

        if http.error.empty?
          if (200..299) === http.response_header.status
            @logger.info("CCNG Catalog Manager: Successfully #{add_plan ? "added" : "updated"} service plan: #{plan.inspect}")
            return true
          else
            @logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}, status=#{http.response_header.status}")
          end
        else
          @logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}: #{http.error}")
        end

        return false
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
          @logger.error("CCNG Catalog Manager: Offering #{id} (#{provider}) is not registered")
          return
        end

        url = "#{@offering_uri}/#{offering_guid}"
        @logger.info("CCNG Catalog Manager: Deleting service offering:#{id} (#{provider}) via #{url}")

        req = create_http_request(:head => @cc_req_hdrs)

        f = Fiber.current

        http = EM::HttpRequest.new(url).delete(req)
        http.callback { f.resume(http) }
        http.errback { f.resume(http) }

        Fiber.yield

        if http.error.empty?
          if (200..299) === http.response_header.status
            @logger.info("CCNG Catalog Manager: Successfully deleted offering: #{id} (#{provider})")
            return true
          else
            @logger.error("CCNG Catalog Manager: Failed to delete offering: #{id} (#{provider}), status=#{http.response_header.status}")
          end
        else
          @logger.error("CCNG Catalog Manager: Failed to delete offering: #{id} (#{provider}) due to: #{http.error}")
        end

        return false
      end

      ######## Handles processing #########
      #TODO: This will still use V1 api for first iteration. The V2 api call is more involved as it requires
      # drilling down multiple levels into the V2 ccdb schema.

      def get_handles_uri(service_label)
        "#{@cld_ctrl_uri}/services/v1/offerings/#{service_label}/handles"
      end

      def fetch_handles_from_cc(service_label, after_fetch_callback)
        return if @fetching_handles

        handles_uri = get_handles_uri(service_label)

        @logger.info("CCNG Catalog Manager:(v1) Fetching handles from cloud controller: #{handles_uri}")
        @fetching_handles = true

        req = create_http_request(:head => @cc_req_hdrs_for_v1_api)

        f = Fiber.current
        http = EM::HttpRequest.new(handles_uri).get(req)
        http.callback { f.resume(http) }
        http.errback  { f.resume(http) }
        Fiber.yield

        @fetching_handles = false

        if http.error.empty?
          if http.response_header.status == 200
            @logger.info("CCNG Catalog Manager:(v1) Successfully fetched handles")

            begin
              resp = VCAP::Services::Api::ListHandlesResponse.decode(http.response)
              after_fetch_callback.call(resp) if after_fetch_callback
            rescue => e
              @logger.error("CCNG Catalog Manager:(v1) Error decoding reply from gateway: #{e}")
            end
          else
            @logger.error("CCNG Catalog Manager:(v1) Failed fetching handles, status=#{http.response_header.status}")
          end
        else
          @logger.error("CCNG Catalog Manager:(v1) Failed fetching handles: #{http.error}")
        end
      end

      def update_handle_in_cc(service_label, handle, on_success_callback, on_failure_callback)
        @logger.debug("CCNG Catalog Manager:(v1) Update service handle: #{handle.inspect}")
        if not handle
          on_failure_callback.call if on_failure_callback
          return
        end

        uri = "#{get_handles_uri(service_label)}/#{handle["service_id"]}"

        req = create_http_request(
          :head => @cc_req_hdrs_for_v1_api,
          :body => Yajl::Encoder.encode(handle)
        )

        f = Fiber.current
        http = EM::HttpRequest.new(uri).post(req)
        http.callback { f.resume(http) }
        http.errback  { f.resume(http) }
        Fiber.yield

        if http.error.empty?
          if http.response_header.status == 200
            @logger.info("CCNG Catalog Manager:(v1) Successful update handle #{handle["service_id"]}")
            on_success_callback.call if on_success_callback
          else
            @logger.error("CCNG Catalog Manager:(v1) Failed to update handle #{id}: http status #{http.response_header.status}")
            on_failure_callback.call if on_failure_callback
          end
        else
          @logger.error("CCNG Catalog Manager:(v1) Failed to update handle #{handle["service_id"]}: #{http.error}")
          on_failure_callback.call if on_failure_callback
        end
      end

    end
  end
end
