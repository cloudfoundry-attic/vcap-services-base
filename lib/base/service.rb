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

    def eql?(other)
      unique_ids_match(self, other) || label_provider_version_match(self, other)
    end

    def hash
      unique_id.hash
    end

    def create_change_set(service_in_ccdb)
      myplans = self.plans
      if service_in_ccdb
        guid = service_in_ccdb.guid
        ccdbplans = service_in_ccdb.plans
        plans_to_add = Plan.collection_subtraction(myplans, ccdbplans)
        plans_to_update = Plan.collection_intersection(plans, service_in_ccdb.plans)
        plans_to_update.each do |plan_to_update|
          plan_to_update.guid = service_in_ccdb.plans.find { |plan| plan.same? plan_to_update }.guid
        end
      else
        guid = nil
        plans_to_add = myplans
        plans_to_update = []
      end

      ServicePlanChangeSet.new(self, guid,
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

    private

    def unique_ids_match(first, second)
      first.unique_id == second.unique_id
    end

    def label_provider_version_match(first, second)
      [first.label, first.provider, first.version].each { |x| return false if x.nil? }

      (first.label == second.label && first.provider == second.provider && first.version == second.version)
    end
  end
end
