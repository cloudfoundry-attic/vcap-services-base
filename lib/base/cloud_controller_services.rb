require 'base/service'
require 'base/plan'

module VCAP::Services
  class CloudControllerServices
    def initialize(http_client, headers, logger)
      @http_client = http_client
      @headers = headers
      @logger = logger
    end

    attr_reader :logger

    def load_registered_services(service_list_uri)
      logger.debug("Getting services listing from cloud_controller")
      registered_services = []

      self.each(service_list_uri, "Registered Offerings") do |s|
        entity = s["entity"]
        plans = []

        logger.debug("Getting service plans for: #{entity["label"]}/#{entity["provider"]}")
        self.each(entity.fetch("service_plans_url"), "Service Plans") do |p|
          plan_entity = p.fetch('entity')
          plan_metadata = p.fetch('metadata')
          plans << Plan.new(
            :unique_id => plan_entity.fetch("unique_id"),
            :guid => plan_metadata.fetch("guid"),
            :name => plan_entity.fetch("name"),
            :description => plan_entity.fetch("description"),
            :free => plan_entity.fetch("free"),
          )
        end

        registered_services << Service.new(
          'guid' => s["metadata"]["guid"],
          'label' => entity["label"],
          'unique_id' => entity["unique_id"],
          'description' => entity["description"],
          'provider' => entity["provider"],
          'version' => entity['version'],
          'url' => entity["url"],
          'info_url' => entity["info_url"],
          'extra' => entity['extra'],
          'plans' => plans,
          'bindable' => entity['bindable']
        )
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
