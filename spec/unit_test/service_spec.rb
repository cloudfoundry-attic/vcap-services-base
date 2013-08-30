require 'helper/spec_helper'
require 'base/service'

module VCAP::Services
  describe Service do
    let(:options) do
      {
        'description' => 'whatever',
        'provider' => 'core',
        'version' => '1.0',
        'url' => 'http://gateway.example.com',
        'plans' => [],
        'extra' => {}
      }
    end
    let(:service_a) { described_class.new(options.merge('unique_id' => 'a')) }
    let(:service_b) { described_class.new(options.merge('unique_id' => 'a')) }
    let(:service_c) { described_class.new(options.merge('unique_id' => 'c')) }

    describe ".new" do
      it "defaults bindable to true" do
        Service.new(options.merge('unique_id' => "abc123")).bindable.should == true
      end
    end

    describe "guid=" do
      it 'sets it' do
        service_a.guid = "55-bb"
        service_a.guid.should == "55-bb"
      end
    end

    describe 'equality' do
      it 'uses the unique ids to compare' do
        service_a.eql?(service_b).should be_true
        service_c.eql?(service_b).should be_false
      end
    end

    describe 'comparing service arrays' do
      it 'knows how to join' do
        result = [service_a, service_c] - [service_b]
        result.should == [service_c]
      end

      it 'knows how to intersect' do
        result = [service_a, service_c] & [service_b]
        result.should == [service_a]
      end
    end

    describe "#create_change_set" do
      subject(:service) { Service.new(options.merge('plans' => [], 'unique_id' => "unique_id")) }
      let(:plan_to_add_1) { Plan.new(:unique_id => "unique_id_p1") }
      let(:plan_to_add_2) { Plan.new(:unique_id => "unique_id_p2") }
      let(:plan_to_change_1) { Plan.new(:unique_id => "unique_id_c1", :guid => "55-33") }
      let(:plan_to_change_2) { Plan.new(:unique_id => "unique_id_c2", :guid => "55-44") }
      let(:plans_in_ccdb) { [plan_to_change_1, plan_to_change_2] }
      let(:service_in_ccdb) { mock('service in ccdb',
                                   plans: plans_in_ccdb,
                                   guid: 'special') }


      it 'creates a correct empty change set' do
        change_set = service.create_change_set(service_in_ccdb)

        change_set.plans_to_add.should == []
        change_set.plans_to_update.should == []
        change_set.service.should == subject
        change_set.service_guid.should == 'special'
      end

      it 'handles nil service in ccdb' do
        service = Service.new(options.merge('plans' => [plan_to_add_1, plan_to_add_2, plan_to_change_1, plan_to_change_2],
                                            'unique_id' => "unique_id"))
        change_set = service.create_change_set(nil)

        change_set.plans_to_add.should =~ [plan_to_add_1, plan_to_add_2, plan_to_change_1, plan_to_change_2]
        change_set.plans_to_update.should == []
        change_set.service.should == service
        change_set.service_guid.should == nil
      end

      it 'adds its plans that are not in the catalog the the plans_to_add list' do
        service = Service.new(options.merge('plans' => [plan_to_add_1, plan_to_add_2],
                                            'unique_id' => "unique_id"))
        change_set = service.create_change_set(service_in_ccdb)

        change_set.plans_to_add.should == [plan_to_add_1, plan_to_add_2]
      end

      it 'adds its plans that are in the catalog the the plans_to_update list with guids' do
        service = Service.new(options.merge('plans' => [plan_to_change_1, plan_to_change_2],
                                            'unique_id' => "unique_id"))
        change_set = service.create_change_set(service_in_ccdb)

        change_set.plans_to_update.should == [plan_to_change_1, plan_to_change_2]
        change_set.plans_to_update.collect(&:guid).should =~ ['55-33', '55-44']
      end
    end

    describe "to_hash" do
      let(:service) do
        Service.new(
          options.merge(
            'plans' => [],
            'unique_id' => "unique_id",
            "bindable" => true,
            "tags" => ["relational"],
            'documentation_url' => 'docs.yoursql.example.com'
          )
        )
      end
      it 'returns its attributes as a hash' do
        service.to_hash.fetch("description").should == "whatever"
        service.to_hash.fetch('documentation_url').should == 'docs.yoursql.example.com'
        service.to_hash.fetch("provider").should == "core"
        service.to_hash.fetch("version").should == "1.0"
        service.to_hash.fetch("url").should == 'http://gateway.example.com'
        service.to_hash.fetch("plans").should == []
        service.to_hash.fetch("unique_id").should == "unique_id"
        service.to_hash.fetch("label").should == nil
        service.to_hash.fetch("active").should == true
        service.to_hash.fetch("acls").should == nil
        service.to_hash.fetch("timeout").should == nil
        service.to_hash.fetch("extra").should == {}
        service.to_hash.fetch("bindable").should == true
        service.to_hash.fetch("tags").should == ["relational"]
      end

      it 'omits guid' do
        service.to_hash.should_not have_key('guid')
      end
    end
  end
end
