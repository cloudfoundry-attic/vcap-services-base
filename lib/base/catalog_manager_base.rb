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

        f = Fiber.current
        http = EM::HttpRequest.new(args[:uri]).send(args[:method], req)
        if http.error && http.error != ""
          unless args[:need_raise]
            @logger.error("CC Catalog Manager: Failed to connect to CC, the error is #{http.error}")
            return
          else
            raise("CC Catalog Manager: Failed to connect to CC, the error is #{http.error}")
          end
        end
        http.callback { f.resume(http, nil) }
        http.errback  { |e| f.resume(http, e) }
        _, error = Fiber.yield
        yield http, error if block_given?
        http
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

      # delete_offering(id, version, provider)
      abstract :delete_offering

      ##### Handles processing #####

      # update_handle_in_cc(service_label, handle, on_success_callback, on_failure_callback)
      abstract :update_handle_in_cc

      # fetch_handles_from_cc(service_label, after_fetch_callback)
      abstract :fetch_handles_from_cc

    end
  end
end
