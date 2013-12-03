require 'helper/spec_helper'
require 'base/plan'

module VCAP::Services
  describe Plan do
    let(:plan_reference) { Plan.new(:unique_id => 'reference', :name => 'myplan') }
    let(:plan_same_name) { Plan.new(:unique_id => 'diff_uniq', :name => 'myplan') }
    let(:plan_same_unique_id) {Plan.new(:unique_id => 'reference', :name => 'diff_name') }
    let(:plan_diff_both) {Plan.new(:unique_id => 'unmatched', :name => 'unmatched') }

    describe '#same?' do
      it 'is the same when unique_id matches' do
        plan_reference.same?(plan_same_unique_id).should be_true
      end

      it 'is the same when name matches' do
        plan_reference.same?(plan_same_name).should be_true
      end

      it 'is not the same when neither unique_id nor name matches' do
        plan_reference.same?(plan_diff_both).should be_false
      end
    end

    describe '.collection_substraction' do
      it 'subtracts plans that have the same unique_id' do
        result = Plan.collection_subtraction([plan_reference, plan_diff_both], [plan_same_unique_id])
        result.should == [plan_diff_both]
      end

      it 'subtracts plans that have different unique_id but same name' do
        result = Plan.collection_subtraction([plan_reference, plan_diff_both], [plan_same_name])
        result.should == [plan_diff_both]
      end
    end

    describe '.collection_intersection' do
      it 'intersects plans that have the same unique_id' do
        result = Plan.collection_intersection([plan_reference, plan_diff_both], [plan_same_unique_id])
        result.should == [plan_reference]
      end

      it 'intersects plans that have different unique_id but same name' do
        result = Plan.collection_intersection([plan_reference, plan_diff_both], [plan_same_name])
        result.should == [plan_reference]
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
        Plan.plans_array_to_hash([plan_reference, plan_diff_both]).should =~ [
          {'unique_id' => 'reference', 'name' => 'myplan', 'description' => nil, 'free' => nil, 'extra' => nil, 'public' => true},
          {'unique_id' => 'unmatched', 'name' => 'unmatched', 'description' => nil, 'free' => nil, 'extra' => nil, 'public' => true}
        ]
      end
    end
  end
end
