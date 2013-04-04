require 'fiber'
require 'nats/client'
require 'uri'
require 'catalog_manager_base'

module VCAP
  module Services
    class CatalogManagerV1 < VCAP::Services::CatalogManagerBase

      REQ_OPTS = %w(cloud_controller_uri token gateway_name logger).map {|o| o.to_sym}

      def initialize(opts)
        super(opts)

        missing_opts = REQ_OPTS.select {|o| !opts.has_key? o}
        raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?

        @gateway_name      = opts[:gateway_name]

        @cld_ctrl_uri      = opts[:cloud_controller_uri]
        @service_list_uri  = "#{@cld_ctrl_uri}/proxied_services/v1/offerings"
        @offering_uri      = "#{@cld_ctrl_uri}/services/v1/offerings"
        @logger            = opts[:logger]

        token_hdrs = VCAP::Services::Api::GATEWAY_TOKEN_HEADER
        @cc_req_hdrs  = {
          'Content-Type' => 'application/json',
          token_hdrs     => opts[:token],
        }

        @gateway_stats = {}
        @gateway_stats_lock = Mutex.new
      end

      def snapshot_and_reset_stats
        stats_snapshot = {}
        @gateway_stats_lock.synchronize do
          stats_snapshot = @gateway_stats.dup
        end
        stats_snapshot
      end

      def get_handles_uri(service_label)
        "#{@cld_ctrl_uri}/services/v1/offerings/#{service_label}/handles"
      end

      def create_key(label, version, provider)
        "#{label}-#{version}"
      end

      def update_catalog(activate, load_catalog_callback, after_update_callback = nil)
        f = Fiber.new do
          configured_services = load_catalog_callback.call()
          active_count = 0
          configured_services.values.each { |svc|
            advertise_service_to_cc(svc, activate)
            active_count += 1  if activate
          }

          @gateway_stats_lock.synchronize do
            @gateway_stats[:active_offerings] = active_count
          end

          after_update_callback.call if after_update_callback
        end
        f.resume
      end

      def generate_cc_advertise_offering_request(svc, active = true)
        plans = svc["plans"] if svc["plans"].is_a?(Array)
        if svc["plans"].is_a?(Hash)
          plans = []
          svc["plans"].keys.each { |k| plans << k.to_s }
        end

        VCAP::Services::Api::ServiceOfferingRequest.new({
          :label => svc["label"],
          :description => svc["description"],

          :provider => svc["provider"] || 'core',

          :url => svc["url"],

          :plans => plans,
          :cf_plan_id => svc["cf_plan_id"],
          :default_plan => svc["default_plan"],

          :tags => svc["tags"] || [],

          :active => active,

          :acls => svc["acls"],

          :supported_versions => svc["supported_versions"],
          :version_aliases => svc["version_aliases"],

          :timeout => svc["timeout"],
        }).encode
      end

      def load_registered_services_from_cc
        @logger.info("CC Catalog Manager: Get registred services from cloud_controller: #{@service_list_uri}")

        services = {}
        create_http_request(:uri => @service_list_uri, :method => "get", :head => @cc_req_hdrs, :need_raise => true) do |http, error|
          if !error
            if http.response_header.status == 200
              resp = JSON.parse(http.response)
              resp["proxied_services"].each {|svc|
                @logger.info("CC Catalog Manager: Fetch #{@gateway_name} service from CC: label=#{svc["label"]} - #{svc.inspect}")
                services[svc["label"]] = svc
              }
            else
              raise "CC Catalog Manager: Failed to fetch #{@gateway_name} service from CC - status=#{http.response_header.status}"
            end
          else
            raise "CC Catalog Manager: Failed to fetch #{@gateway_name} service from CC: #{http.error}"
          end
        end

        return services
      end

      def advertise_service_to_cc(svc, active = true)
        offering = generate_cc_advertise_offering_request(svc, active)

        @logger.debug("CC Catalog Manager: Advertise service offering #{offering.inspect} to cloud_controller: #{@offering_uri}")
        return false unless offering

        create_http_request(:uri => @offering_uri, :method => "post", :head => @cc_req_hdrs, :body => offering) do |http, error|
          if !error
            if http.response_header.status == 200
              @logger.info("CC Catalog Manager: Successfully advertised offering: #{offering.inspect}")
              return true
            else
              @logger.error("CC Catalog Manager: Failed to advertise offerings:#{offering.inspect}, status=#{http.response_header.status}")
            end
          else
            @logger.error("CC Catalog Manager: Failed to advertise offerings:#{offering.inspect}: #{http.error}")
          end
        end
        return false
      end

      def delete_offering(id, version, provider)
        # See: https://github.com/cloudfoundry/cloud_controller/blob/master/cloud_controller/config/routes.rb
        offering_id = "#{id}-#{version}/#{provider}"
        uri = "#{@offering_uri}/#{offering_id}"
        @logger.info("CC Catalog Manager: Delete service offering: #{offering_id}")

        create_http_request(:uri => uri, :method => "delete", :head => @cc_req_hdrs) do |http, error|
          if !error
            if http.response_header.status == 200
              @logger.info("CC Catalog Manager: Successfully deleted offering: #{offering_id}")
              return true
            else
              @logger.warn("CC Catalog Manager: Failed to delete offering: #{offering_id}, status: #{http.response_header.status}")
            end
          else
            @logger.warn("CC Catalog Manager: Failed to delete offering: #{offering_id} due to: #{http.error}")
          end
        end
        return false
      end

      ###### Handles processing #####

      def fetch_handles_from_cc(service_label, after_fetch_callback)
        return if @fetching_handles

        handles_uri = get_handles_uri(service_label)

        @logger.info("CC Catalog Manager: Fetching handles from cloud controller: #{handles_uri}")
        @fetching_handles = true

        create_http_request(:uri => handles_uri, :method => "get", :head => @cc_req_hdrs) do |http, error|
          @fetching_handles = false

          if !error
            if http.response_header.status == 200
              @logger.info("CC Catalog Manager: Successfully fetched handles")

              begin
                resp = VCAP::Services::Api::ListHandlesResponse.decode(http.response)
                after_fetch_callback.call(resp) if after_fetch_callback
              rescue => e
                @logger.error("CC Catalog Manager: Error decoding reply from gateway: #{e}")
              end
            else
              @logger.error("CC Catalog Manager: Failed fetching handles, status=#{http.response_header.status}")
            end
          else
            @logger.error("CC Catalog Manager: Failed fetching handles: #{http.error}")
          end
        end
      end

      def update_handle_in_cc(service_label, handle, on_success_callback, on_failure_callback)
        @logger.debug("CC Catalog Manager: Update service handle: #{handle.inspect}")
        if not handle
          on_failure_callback.call if on_failure_callback
          return
        end

        uri = "#{get_handles_uri(service_label)}/#{handle["service_id"]}"

        create_http_request(:uri => uri, method => "post", :head => @cc_req_hdrs, :body => Yajl::Encoder.encode(handle)) do |http, error|
          if !error
            if http.response_header.status == 200
              @logger.info("CC Catalog Manager: Successful update handle #{handle["service_id"]}")
              on_success_callback.call if on_success_callback
            else
              @logger.error("CC Catalog Manager: Failed to update handle #{handle["service_id"]}: http status #{http.response_header.status}")
              on_failure_callback.call if on_failure_callback
            end
          else
            @logger.error("CC Catalog Manager: Failed to update handle #{handle["service_id"]}: #{http.error}")
            on_failure_callback.call if on_failure_callback
          end
        end
      end

    end
  end
end
