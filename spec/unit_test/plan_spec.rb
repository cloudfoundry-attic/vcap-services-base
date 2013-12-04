require 'helper/spec_helper'
require 'base/plan'

module VCAP::Services
  describe Plan do
    let(:plan_reference) { Plan.new(:unique_id => 'reference', :name => 'myplan') }
    let(:plan_same_name) { Plan.new(:unique_id => 'diff_uniq', :name => 'myplan') }
    let(:plan_same_unique_id) {Plan.new(:unique_id => 'reference', :name => 'diff_name') }
    let(:plan_diff_both) {Plan.new(:unique_id => 'unmatched', :name => 'unmatched') }

    describe "to_hash" do
      let(:plan) { Plan.new(:unique_id => "unique_id") }
      it 'returns its attributes as a hash' do
        plan.to_hash.should == {
          'unique_id' => 'unique_id',
          'name' => nil,
          'description' => nil,
          'free' => nil,
          'extra' => nil,
          'public' => true,
        }
      end

      it 'includes public=false if set' do
        private_plan = Plan.new(unique_id: "abc1234", public: false)
        private_plan.to_hash['public'].should == false
      end

      it 'omits guid' do
        plan.to_hash.should_not have_key(:guid)
      end

      it 'has extra if provided' do
        plan = Plan.new(:unique_id => 'id', extra: 'extra information')
        plan.to_hash.fetch('extra').should == 'extra information'
      end
    end

    describe "plans_array_to_hash" do
      it 'serializes an array of plan object' do
        Plan.plans_array_to_hash([plan_reference, plan_diff_both]).should =~ [
          {'unique_id' => 'reference', 'name' => 'myplan', 'description' => nil, 'free' => nil, 'extra' => nil, 'public' => true},
          {'unique_id' => 'unmatched', 'name' => 'unmatched', 'description' => nil, 'free' => nil, 'extra' => nil, 'public' => true}
        ]
      end
    end

    describe '#get_update_hash' do
      let(:plan) { Plan.new(:unique_id => "unique_id", :public => true) }
      let(:service_guid) { 'a_service_guid' }

      it 'returns its attributes as a hash' do
        plan.get_update_hash(service_guid).should == {
          'name'         => nil,
          'description'  => nil,
          'free'         => nil,
          'extra'        => nil,
          'service_guid' => 'a_service_guid'
        }
      end

      it 'omits unique_id' do
        plan.get_update_hash(service_guid).should_not have_key('unique_id')
      end

      it 'omits public' do
        plan.get_update_hash(service_guid).should_not have_key('public')
      end

      it 'sets service_guid' do
        plan.get_update_hash(service_guid)['service_guid'].should == 'a_service_guid'
      end
    end

    describe '#get_add_hash' do
      let(:plan) { Plan.new(:unique_id => "unique_id", :public => true) }
      let(:service_guid) { 'a_service_guid' }

      it 'returns its attributes as a hash' do
        plan.get_add_hash(service_guid).should == {
          'unique_id'    => 'unique_id',
          'name'         => nil,
          'description'  => nil,
          'free'         => nil,
          'extra'        => nil,
          'public'       => true,
          'service_guid' => 'a_service_guid'
        }
      end

      it 'sets service_guid' do
        plan.get_add_hash(service_guid)['service_guid'].should == 'a_service_guid'
      end
    end
  end
end
