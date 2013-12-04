module VCAP::Services
  class Plan
    attr_reader :name, :guid, :description, :free, :unique_id, :extra
    attr_writer :guid

    def initialize(options)
      @unique_id = options.fetch(:unique_id)
      @guid = options[:guid]
      @name = options[:name]
      @description = options[:description]
      @free = options[:free]
      @extra = options[:extra]
      @public = options.fetch(:public, true)
    end

    def to_hash
      {
        'unique_id' => @unique_id,
        'name' => @name,
        'description' => @description,
        'free' => @free,
        'extra' => @extra,
        'public' => @public,
      }
    end

    def get_update_hash(service_guid)
      plan_as_hash = self.to_hash
      plan_as_hash['service_guid'] = service_guid
      plan_as_hash.delete('unique_id')
      plan_as_hash.delete('public')
      return plan_as_hash
    end

    def get_add_hash(service_guid)
      plan_as_hash = self.to_hash
      plan_as_hash['service_guid'] = service_guid
      return plan_as_hash
    end

    def self.plan_hash_as_plan_array(plans)
      plan_array = []
      return plan_array unless plans
      if plans.first.is_a?(Plan)
        return plans
      else
        plans.each do |_, v|
          plan_array << Plan.new(v)
        end
      end
      plan_array
    end

    def self.plans_array_to_hash(plans_array)
      return [] unless plans_array
      plans_array_hash = []
      plans_array.each do |plan|
        plans_array_hash << plan.to_hash
      end
      plans_array_hash
    end
  end
end
