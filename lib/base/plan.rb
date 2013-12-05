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

    def self.collection_subtraction(lh_collection, rh_collection)
      result = []

      lh_collection.each do |lh_plan|
        if lh_plan.not_in?(result) && lh_plan.not_in?(rh_collection)
          result << lh_plan
        end
      end

      return result
    end

    def self.collection_intersection(lh_collection, rh_collection)
      result = []

      lh_collection.each do |lh_plan|
        if lh_plan.not_in?(result) && lh_plan.in?(rh_collection)
          result << lh_plan
        end
      end

      return result
    end

    def in?(plan_collection)
      plan_collection.select {|other_plan| self.same?(other_plan) }.length > 0
    end


    def not_in?(plan_collection)
      !in?(plan_collection)
    end

    def same?(other)
      return (self.unique_id == other.unique_id) || (self.name == other.name)
    end

    def eql?(other)
      return (self.unique_id == other.unique_id) || (self.name == other.name)
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
