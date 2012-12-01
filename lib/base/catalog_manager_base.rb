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

      def snapshot_and_reset_stats
        {}
      end

      def update_catalog(activate, load_catalog_callback, after_update_callback=nil)
        raise "Not implemented"
      end

      def generate_cc_advertise_offering_request(svc, active = true)
        raise "Not implemented"
      end

      def advertise_service_to_cc(svc, active)
        raise "Not implemented"
      end

      def load_registered_services_from_cc
        raise "Not implemented"
      end 

      ##### Handles processing #####

      def update_handle_in_cc(service_label, handle, on_success_callback, on_failure_callback)
        raise "Not implemented"
      end

      def fetch_handles_from_cc(service_label, after_fetch_callback)
        raise "Not implemented"
      end

    end
  end
end
