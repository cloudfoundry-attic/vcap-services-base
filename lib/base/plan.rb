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

    def eql?(other)
      return self.unique_id == other.unique_id
    end

    def hash
      unique_id.hash
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
