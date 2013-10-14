require 'fiber'
require 'nats/client'
require 'uri'
require 'uaa'
require 'services/api/const'
require 'catalog_manager_base'
require 'base/cloud_controller_services'
require 'base/http_handler'
require 'base/service_advertiser'

module VCAP
  module Services
    class CatalogManagerV2 < VCAP::Services::CatalogManagerBase
      attr_reader :logger

      def initialize(opts)
        super(opts)

        @opts = opts
        @test_mode = opts[:test_mode] || false

        required_opts = %w(cloud_controller_uri token gateway_name logger).map { |o| o.to_sym }
        required_opts.concat( %w(uaa_endpoint uaa_client_id uaa_client_auth_credentials).map { |o| o.to_sym } ) if !@test_mode

        missing_opts = required_opts.select {|o| !opts.has_key? o}
        raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?

        @gateway_name          = opts[:gateway_name]
        @cld_ctrl_uri          = opts[:cloud_controller_uri]
        @service_list_uri      = "/v2/services?inline-relations-depth=2"

        @service_instances_uri = "/v2/service_instances"
        @service_bindings_uri  = "/v2/service_bindings"
        @handle_guid         = {}

        @logger               = opts[:logger]

        @gateway_stats = {}
        @gateway_stats_lock = Mutex.new
        snapshot_and_reset_stats
        @http_handler = HTTPHandler.new(opts)
        @multiple_page_getter = CloudControllerServices.new(
          @http_handler.method(:cc_http_request),
          @http_handler.cc_req_hdrs,
          @logger)
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
      def update_catalog(activate, catalog_loader, after_update_callback = nil)
        f = Fiber.new do
          # Load offering from ccdb
          logger.info("CCNG Catalog Manager: Loading services from CC")
          failed = false
          begin
            catalog_in_ccdb = load_registered_services_from_cc

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
            current_catalog = catalog_loader.call().values.collect do |service_hash|
              label, _ = VCAP::Services::Api::Util.parse_label(service_hash.fetch('label'))
              Service.new(service_hash.merge('label' => label))
            end
          rescue => e1
            failed = true
            logger.error("CCNG Catalog Manager: Failed to get latest service catalog: #{e1.inspect}")
            logger.error(e1.backtrace)
          ensure
            update_stats("refresh_catalog", failed)
          end

          # Update
          logger.info("CCNG Catalog Manager: Updating Offerings...")
          advertise_services(current_catalog, catalog_in_ccdb, activate)

          # Post-update processing
          if after_update_callback
            logger.info("CCNG Catalog Manager: Invoking after update callback...")
            after_update_callback.call()
          end
        end
        f.resume
      end

      def load_registered_services_from_cc
        @multiple_page_getter.load_registered_services(@service_list_uri)
      end

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
              logger.info("CCNG Catalog Manager:(v2) Successful update handle #{handle["service_id"]}")
              on_success_callback.call if on_success_callback
            else
              logger.error("CCNG Catalog Manager:(v2) Failed to update handle #{handle["service_id"]}: http status #{http.response_header.status}")
              on_failure_callback.call if on_failure_callback
            end
          else
            logger.error("CCNG Catalog Manager:(v2) Failed to update handle #{handle["service_id"]}: #{http.error}")
            on_failure_callback.call if on_failure_callback
          end
        end
      end

      private
      def fetch_all_instance_handles_from_cc
        logger.info("CCNG Catalog Manager:(v2) Fetching all service instance handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}")
        instance_handle_list = {}

        registered_services = load_registered_services_from_cc

        registered_services.each do |registered_service|
          registered_service.plans.each do |plan_details|
            plan_guid = plan_details.guid
            instance_handles_query = "?q=service_plan_guid:#{plan_guid}"
            instance_handles = fetch_instance_handles_from_cc(instance_handles_query)
            instance_handle_list.merge!(instance_handles) if instance_handles
          end
        end
        logger.info("CCNG Catalog Manager:(v2) Successfully fetched all service instance handles from cloud controller: #{@cld_ctrl_uri}#{@service_instance_uri}")
        instance_handle_list
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

        @multiple_page_getter.each(service_instance_uri, "service instance handles") do |resources|
          instance_info = resources['entity']
          instance_handles[instance_info['credentials']['name']] = instance_info
          @handle_guid[instance_info['credentials']['name']] = resources['metadata']['guid']
        end
        instance_handles
      rescue => e
        logger.error("CCNG Catalog Manager:(v2) Error decoding reply from gateway: #{e.backtrace}")
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

      # fetch binding handles from cloud_controller_ng
      # this function allows users to get a dedicated set of binding handles
      # from cloud_controller_ng using a customized query for /v2/service_binding api
      #
      # @param string binding_handles_query
      def fetch_binding_handles_from_cc(binding_handles_query)
        logger.info("CCNG Catalog Manager:(v2) Fetching service binding handles from cloud controller: #{@cld_ctrl_uri}#{@service_bindings_uri}#{binding_handles_query}")

        binding_handles = {}
        binding_handles_uri = "#{@service_bindings_uri}#{binding_handles_query}"

        @multiple_page_getter.each(binding_handles_uri, "service binding handles") do |resources|
          binding_info = resources['entity']
          binding_handles[binding_info['gateway_name']] = binding_info
          @handle_guid[binding_info['gateway_name']] = resources['metadata']['guid']
        end
        binding_handles
      rescue => e
        logger.error("CCNG Catalog Manager:(v2) Error decoding reply from gateway: #{e}")
      end

      def advertise_services(current_catalog, catalog_in_ccdb, active=true)
        logger.info("CCNG Catalog Manager: #{active ? "Activate" : "Deactivate"} services...")

        if !(current_catalog && catalog_in_ccdb)
          logger.warn("CCNG Catalog Manager: Cannot advertise services since the offerings list from either the catalog or ccdb could not be retrieved")
          return
        end

        service_advertiser = ServiceAdvertiser.new(
          current_catalog: current_catalog,
          catalog_in_ccdb: catalog_in_ccdb,
          http_handler: @http_handler,
          logger: logger,
          active: active
        )
        service_advertiser.advertise_services

        @gateway_stats_lock.synchronize do
          @gateway_stats[:active_offerings] = service_advertiser.active_count
          @gateway_stats[:disabled_services] = service_advertiser.disabled_count
        end
      end
    end
  end
end
