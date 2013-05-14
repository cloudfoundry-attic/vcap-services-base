module VCAP::Services
  class CloudControllerServices
    def initialize(http_client, headers, logger)
      @http_client = http_client
      @headers     = headers
      @logger      = logger
    end
    attr_reader :logger

    def load_registered_services(service_list_uri, auth_token_registry)
      logger.debug("Getting services listing from cloud_controller")
      registered_services = {}

      self.each(service_list_uri, "Registered Offerings") do |s|
        key = "#{s["entity"]["label"]}_#{s["entity"]["provider"]}"

        if auth_token_registry.has_key?(key.to_sym)
          entity = s["entity"]

          plans = {}
          logger.debug("Getting service plans for: #{entity["label"]}/#{entity["provider"]}")
          self.each(entity["service_plans_url"], "Service Plans") do |p|
            plans[p["entity"]["name"]] = {
              "guid"        => p["metadata"]["guid"],
              "name"        => p["entity"]["name"],
              "description" => p["entity"]["description"],
              "free"        => p["entity"]["free"],
            }
          end

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

          logger.debug("Found #{key} = #{registered_services[key].inspect}")
        end
      end

      registered_services
    end

    def each(seed_url, description, &block)
      url = seed_url
      logger.info("Fetching #{description} from: #{seed_url}")

      while !url.nil? do
        logger.debug("#{self.class.name}: Fetching #{description} from: #{url}")
        @http_client.call(:uri => url,
                          :method => "get",
                          :head => @headers,
                          :need_raise => true) do |http|
          result = nil
          if (200..299) === http.response_header.status
            result = JSON.parse(http.response)
          else
            raise "CCNG Catalog Manager: - Multiple page fetch via: #{url} failed: (#{http.response_header.status}) - #{http.response}"
          end
          result.fetch("resources").each { |r| block.yield r }
          url = result["next_url"]
        end
      end
    end
  end
end
