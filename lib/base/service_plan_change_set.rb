module VCAP::Services
  class ServicePlanChangeSet
    attr_reader :service, :plans_to_add, :plans_to_update, :service_guid
    def initialize(service, service_guid, options = {})
      @service = service
      @service_guid = service_guid
      @plans_to_add = options[:plans_to_add] || []
      @plans_to_update = options[:plans_to_update] || []
    end
  end
end