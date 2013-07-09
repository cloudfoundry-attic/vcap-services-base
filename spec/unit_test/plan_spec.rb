require 'helper/spec_helper'
require 'base/plan'

module VCAP::Services
  describe Plan do
    let(:plan_a) { described_class.new(:unique_id => 'a') }
    let(:plan_b) { described_class.new(:unique_id => 'a') }
    let(:plan_c) { described_class.new(:unique_id => 'c') }

    describe 'equality' do
      it 'uses the unique ids to compare' do
        plan_a.eql?(plan_b).should be_true
        plan_c.eql?(plan_b).should be_false
      end
    end

    describe 'comparing plan arrays' do
      it 'knows how to join' do
        result = [plan_a, plan_c] - [plan_b]
        result.should == [plan_c]
      end

      it 'knows how to intersect' do
        result = [plan_a, plan_c] & [plan_b]
        result.should == [plan_a]
      end
    end

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
        Plan.plans_array_to_hash([plan_a, plan_c]).should =~ [
          {'unique_id' => "a", 'name' => nil, 'description' => nil, 'free' => nil, 'extra' => nil, 'public' => true},
          {'unique_id' => "c", 'name' => nil, 'description' => nil, 'free' => nil, 'extra' => nil, 'public' => true}
        ]
      end
    end
  end
end