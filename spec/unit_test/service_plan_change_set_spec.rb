require 'helper/spec_helper'
require 'base/service_plan_change_set'

module VCAP::Services
  describe ServicePlanChangeSet do
    let(:service) { double() }
    subject { described_class.new(service, "my_guid") }

    it 'has a list of plans to add' do
      expect(subject.plans_to_add).to eq([])
    end

    it 'has a list of plans to update' do
      expect(subject.plans_to_update).to eq([])
    end

    it 'has a service' do
      expect(subject.service).to eq(service)
    end
  end
end
