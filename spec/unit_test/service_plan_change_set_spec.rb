require 'helper/spec_helper'
require 'base/service_plan_change_set'

module VCAP::Services
  describe ServicePlanChangeSet do
    let(:service) { stub }
    subject { described_class.new(service, "my_guid") }

    it 'has a list of plans to add' do
      subject.plans_to_add.should == []
    end

    it 'has a list of plans to update' do
      subject.plans_to_update.should == []
    end

    it 'has a service' do
      subject.service.should == service
    end
  end
end
