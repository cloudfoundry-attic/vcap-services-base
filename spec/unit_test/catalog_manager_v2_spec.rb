require 'helper/spec_helper'
require 'base/catalog_manager_v2'

describe VCAP::Services::CatalogManagerV2 do
  let(:logger) { Logger.new('/tmp/vcap_services_base.log') }
  let(:http_handler) { mock('http_handler', cc_http_request: nil, cc_req_hdrs: {}) }

  let(:config) do
    {
      :cloud_controller_uri => 'api.vcap.me',
      :service_auth_tokens => {
        :test_core => 'token',
      },
      :token => 'token',
      :gateway_name => 'test_gw',
      :logger => logger,
      :uaa_endpoint => 'http://uaa.vcap.me',
      :uaa_client_id => 'vmc',
      :uaa_client_auth_credentials => {
        :username => 'test',
        :password=> 'test',
      },
    }
  end
  let(:catalog_manager) { described_class.new(config) }

  before(:each) do
    HTTPHandler.stub(new: http_handler)
  end

  it 'creates a http handler with correct params' do
    HTTPHandler.should_receive(:new).with(config)
    catalog_manager
  end

  describe "#process_plans" do
    let(:plan_name) { "plan1" }
    let(:plan_guid) { "abc" }
    let(:plan_details) {
      {"guid" => plan_guid, "description" => "blah", "free" => true, "extra" => "stuff"}
    }

    describe "plans_to_add (first return value)" do
      context "when there is a new plan" do
        it "advertises the new plan" do
          new_plans = { plan_name => plan_details }
          plans_to_add, _ = catalog_manager.process_plans(new_plans, {})

          plans_to_add.should have(1).entry
          plans_to_add.first.should == plan_details
        end
      end

      context "when there are no new plans" do
        it "does not advertise any new plans" do
          plans = { plan_name => plan_details }

          plans_to_add, _ = catalog_manager.process_plans(plans, plans)

          plans_to_add.should be_empty
        end
      end
    end

    describe "plans_to_update (second return value)" do
      context "when no plans change" do
        it "should propose no changes to CC" do
          plans = {plan_name => plan_details}

          _, plans_to_update = catalog_manager.process_plans(plans, plans)
          plans_to_update.should be_empty
        end
      end

      context "when a plan's extra field has changed since it was last advertised" do
        it "should update the plan" do
          old_plans = { plan_name => plan_details.merge("extra" => "something") }
          new_plans = { plan_name => plan_details.merge("extra" => "something else") }

          _, plans_to_update = catalog_manager.process_plans( new_plans, old_plans )
          plans_to_update.should have_key(plan_guid)
          plans_to_update[plan_guid]['extra'].should == new_plans[plan_name]['extra']
        end
      end
    end
  end

  describe "#update_catalog" do
    let(:manager) { described_class.new(config) }
    let(:catalog_loader) { ->{} }
    let(:registered_services) { mock('registered service', load_registered_services: {}) }

    before do
      VCAP::Services::CloudControllerCollectionGetter.stub(:new => registered_services)
    end

    it "loads the services from the gateway" do
      catalog_loader.should_receive(:call)
      manager.update_catalog(true, catalog_loader)
    end

    it "get the registered services from CCNG" do
      registered_services.should_receive(:load_registered_services).
        with("/v2/services?inline-relations-depth=2", anything)
      manager.update_catalog(true, catalog_loader)
    end

    it 'logs error if getting catalog fails' do
      catalog_loader.stub(:call).and_raise('Failed')
      logger.should_receive(:error).twice
      manager.update_catalog(true, catalog_loader)
    end

    it "updates the stats" do
      manager.update_catalog(true, catalog_loader)
      manager.instance_variable_get(:@gateway_stats)[:refresh_catalog_requests].should == 1
    end
  end
end
