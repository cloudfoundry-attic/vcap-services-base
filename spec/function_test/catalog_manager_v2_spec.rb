require 'helper/spec_helper'
require 'base/catalog_manager_v2'
require 'helper/catalog_manager_v2_spec_helper'

module VCAP::Services
  describe CatalogManagerV2 do
    include VCAP::Services::CatalogManagerV2Helper

    before do
      WebMock.disable_net_connect!
    end

    it 'advertises with unique_id' do
      CF::UAA::TokenIssuer.any_instance.stub(:implicit_grant_with_creds).and_return(double(:credentials, info: {}))

      config = load_config
      config[:logger].level = Logger::DEBUG
      config[:cloud_controller_uri] = "http://api.vcap.me"
      catalog_manager = CatalogManagerV2.new(config)
      unique_service_id = 'unique_service_id'
      unique_plan_id = 'unique_plan_id'
      catalog = {
        'service_key1' => {
          'id' => 'id-1',
          'version' => '1.0',
          'description' => 'description',
          'provider' => 'provider',
          'acls' => 'acls',
          'url' => 'url',
          'timeout' => 'timeout',
          'extra' => 'extra',
          'unique_id' => unique_service_id,
          'plans' => {
            'free' => {
              description: 'description',
              free: true,
              extra: nil,
              unique_id: unique_plan_id,
            }
          }
        }
      }
      stub_request(:get, "http://api.vcap.me/v2/services?inline-relations-depth=2").
        to_return(:status => 200, :body => Yajl::Encoder.encode('resources' => []))

      stub_request(:post, "http://api.vcap.me/v2/services").
        to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => 'service_guid'}))

      stub_request(:post, "http://api.vcap.me/v2/service_plans").
        to_return(:body => '')

      EM.run do
        catalog_manager.update_catalog(true, -> { catalog })
        EM.add_timer(1) { EM.stop }
      end

      a_request(:post, "http://api.vcap.me/v2/services").with do |req|
        JSON.parse(req.body).fetch('unique_id').should == unique_service_id
      end.should have_been_made

      a_request(:post, "http://api.vcap.me/v2/service_plans").with do |req|
        JSON.parse(req.body).fetch('unique_id').should == unique_plan_id
      end.should have_been_made
    end
  end
end
