module VCAP::Services
  class GatewayServiceCatalog
    attr_reader :service
    
    def initialize(services)
      raise ArgumentError.new('a service list is required') unless services and services.is_a?(Array)
      @service = services.fetch(0)
    end

    def to_hash
      id, version = VCAP::Services::Api::Util.parse_label(service[:label])
      version = service[:version_aliases][:current] if service[:version_aliases][:current]
      provider = service[:provider] || 'core'

      catalog_key = "#{id}_#{provider}"

      unique_id = service[:unique_id] ? {"unique_id" => service[:unique_id]} : {}
      catalog = {}

      plans = service.fetch(:plans)
      unless plans.is_a?(Array)
        plans.each do |name, plan|
          plan[:name] = name
        end
      end

      catalog[catalog_key] = {
        "id" => id,
        "version" => version,
        "label" => service[:label],
        "url" => service[:url],
        "plans" => plans,
        "cf_plan_id" => service[:cf_plan_id],
        "tags" => service[:tags],
        "active" => true,
        "description" => service[:description],
        "plan_options" => service[:plan_options],
        "acls" => service[:acls],
        "timeout" => service[:timeout],
        "provider" => provider,
        "default_plan" => service[:default_plan],
        "supported_versions" => service[:supported_versions],
        "version_aliases" => service[:version_aliases],
      }.merge(extra).merge(unique_id)

      return catalog
    end

    private

    def extra
      if (service.keys & [:logo_url, :blurb, :provider_name]).empty?
        {}
      else
        {"extra" => Yajl::Encoder.encode(
          "listing" => {
            "imageUrl" => service[:logo_url],
            "blurb" => service[:blurb]
          },
          "provider" => {
            "name" => service[:provider_name]
          }
        )
        }
      end
    end
  end
end
