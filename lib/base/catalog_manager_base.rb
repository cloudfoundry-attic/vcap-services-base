require 'abstract'

module VCAP
  module Services
    class CatalogManagerBase

      def initialize(opts)
        @proxy_opts = opts[:proxy]
      end

      def create_http_request(args)
        req = {
          :head => args[:head],
          :body => args[:body],
        }
        if (@proxy_opts)
          req[:proxy] = @proxy_opts
          # this is a workaround for em-http-requesr 0.3.0 so that headers are not lost
          # more info: https://github.com/igrigorik/em-http-request/issues/130
          req[:proxy][:head] = req[:head]
        end

        req
      end

      abstract :snapshot_and_reset_stats

      # update_catalog(activate, load_catalog_callback, after_update_callback=nil)
      abstract :update_catalog

      # generate_cc_advertise_offering_request(svc, active = true)
      abstract :generate_cc_advertise_offering_request

      # advertise_service_to_cc(svc, active)
      abstract :advertise_service_to_cc

      # load_registered_services_from_cc
      abstract :load_registered_services_from_cc

      ##### Handles processing #####

      # update_handle_in_cc(service_label, handle, on_success_callback, on_failure_callback)
      abstract :update_handle_in_cc

      # fetch_handles_from_cc(service_label, after_fetch_callback)
      abstract :fetch_handles_from_cc

    end
  end
end
