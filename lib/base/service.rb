require "base/plan"
require "base/service_plan_change_set"

module VCAP::Services
  class Service
    attr_reader :description, :provider, :version, :url, :info_url, :documentation_url, :plans, :tags,
                :unique_id, :label, :active, :tags, :plan_options, :acls, :timeout,
                :default_plan, :supported_versions, :version_aliases, :extra, :bindable
    attr_accessor :guid

    def initialize(attrs)
      @unique_id = attrs.fetch('unique_id')
      @label = attrs['label']
      @active = attrs['active']
      @active = true if @active.nil?
      @tags = attrs['tags']
      @plan_options = attrs['plan_options']
      @acls = attrs['acls']
      @timeout = attrs['timeout']
      @default_plan = attrs['default_plan']
      @supported_versions = attrs['supported_versions']
      @version_aliases = attrs['version_aliases']
      @extra = attrs.fetch('extra')
      @info_url = attrs['info_url']
      @documentation_url = attrs['documentation_url']
      @bindable = attrs.fetch('bindable', true)
      @guid = attrs['guid']
      @description = attrs['description']
      @provider = attrs.fetch('provider')
      @version = attrs.fetch('version')
      @url = attrs.fetch('url')
      @plans = Plan.plan_hash_as_plan_array(attrs.fetch('plans'))
      @tags = attrs['tags']
    end

    def create_change_set(service_in_ccdb)

      if service_in_ccdb
        service_guid    = service_in_ccdb.guid
        plans_to_update = []
        plans_to_add    = []

        self.plans.each do |catalog_plan|
          ccdb_plan = service_in_ccdb.plans.find { |ccp| catalog_plan.unique_id == ccp.unique_id }
          ccdb_plan = service_in_ccdb.plans.find { |ccp| catalog_plan.name == ccp.name } unless ccdb_plan

          if ccdb_plan
            catalog_plan.guid = ccdb_plan.guid
            plans_to_update << catalog_plan
          else
            plans_to_add << catalog_plan
          end
        end
      else
        service_guid    = nil
        plans_to_add    = self.plans
        plans_to_update = []
      end

      ServicePlanChangeSet.new(self, service_guid,
        plans_to_add: plans_to_add,
        plans_to_update: plans_to_update,
      )
    end

    def to_hash
      {
        "description" => description,
        "provider" => provider,
        "version" => version,
        "url" => url,
        "documentation_url" => documentation_url,
        "plans" => Plan.plans_array_to_hash(plans),
        "unique_id" => unique_id,
        "label" => label,
        "active" => active,
        "acls" => acls,
        "timeout" => timeout,
        "extra" => extra,
        "bindable" => bindable,
        "tags" => tags
      }
    end

    def same_tuple?(other)
      [self.label, self.provider, self.version].each { |x| return false if x.nil? }

      (self.label == other.label &&
        self.provider == other.provider &&
        self.version == other.version)
    end
  end
end
