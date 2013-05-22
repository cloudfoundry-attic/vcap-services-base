require 'service'

module VCAP::Services
  class GatewayServiceCatalog
    attr_reader :services

    def initialize(catalog_attrs)
      raise ArgumentError.new('a service list is required') unless catalog_attrs and catalog_attrs.is_a?(Array)
      @services = catalog_attrs.map { |attrs| build_service(attrs) }
    end

    private

    def build_service(attrs)
      id, version = VCAP::Services::Api::Util.parse_label(attrs[:label])
      version = attrs[:version_aliases][:current] if attrs[:version_aliases][:current]
      provider = attrs[:provider] || 'core'

      plans = attrs.fetch(:plans)
      unless plans.is_a?(Array)
        plans.each do |name, plan|
          plan[:name] = name
        end
      end

      unique_id = attrs[:unique_id]
      raise ArgumentError.new(":unique_id is required") unless unique_id

      attrs = {
        "unique_id" => unique_id,
        "version" => version,
        "label" => id,
        "url" => attrs[:url],
        "plans" => plans,
        "cf_plan_id" => attrs[:cf_plan_id],
        "tags" => attrs[:tags],
        "active" => true,
        "description" => attrs[:description],
        "plan_options" => attrs[:plan_options],
        "acls" => attrs[:acls],
        "timeout" => attrs[:timeout],
        "provider" => provider,
        "default_plan" => attrs[:default_plan],
        "supported_versions" => attrs[:supported_versions],
        "version_aliases" => attrs[:version_aliases],
        "extra" => extra(attrs)
      }

      Service.new(attrs)
    end

    def extra(attrs)
      return unless attrs.key?(:logo_url) or attrs.key?(:blurb) or attrs.key?(:provider_name)

      Yajl::Encoder.encode(
        "listing" => {
          "imageUrl" => attrs[:logo_url],
          "blurb" => attrs[:blurb]
        },
        "provider" => {
          "name" => attrs[:provider_name]
        }
      )
    end
  end
end
