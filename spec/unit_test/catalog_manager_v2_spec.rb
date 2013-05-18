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

  describe "#update_catalog" do
    let(:manager) { described_class.new(config) }
    let(:catalog_loader) { ->{} }
    let(:registered_services) { mock('registered service', load_registered_services: {}) }

    before do
      VCAP::Services::CloudControllerServices.stub(:new => registered_services)
    end

    it "loads the services from the gateway" do
      catalog_loader.should_receive(:call)
      manager.update_catalog(true, catalog_loader)
    end

    it "get the registered services from CCNG" do
      registered_services.should_receive(:load_registered_services).
        with("/v2/services?inline-relations-depth=2")
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
