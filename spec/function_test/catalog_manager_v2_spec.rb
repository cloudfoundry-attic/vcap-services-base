require 'helper/spec_helper'
require 'base/catalog_manager_v2'
require 'helper/catalog_manager_v2_spec_helper'

module VCAP::Services
  describe CatalogManagerV2 do
    include VCAP::Services::CatalogManagerV2Helper

    before do
      WebMock.disable_net_connect!
      CF::UAA::TokenIssuer.any_instance.stub(:implicit_grant_with_creds).and_return(double(:credentials, info: {}))
    end

    let(:catalog_manager) do
      config = load_config
      config[:logger].level = Logger::DEBUG
      config[:service_auth_tokens][:'id-1.0_provider'] = 'secretkey'
      config[:cloud_controller_uri] = "http://api.vcap.me"
      CatalogManagerV2.new(config)
    end

    it 'advertises with unique_id' do
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

    it "updates existing plans and services without sending unique_id" do
      unique_service_id = 'unique_service_id'
      cc_service_guid = 'service-guid'
      cc_service_plan_guid = 'plan-guid'
      service_label = 'id-1.0'
      service_provider = 'provider'
      old_description = 'old description'
      new_description = 'a totally different description'
      old_plan_description = 'old plan description'
      new_plan_description = 'new plan description'

      service = {
        'id' => service_label,
        'provider' => service_provider,
        'version' => '1.0',
        'description' => new_description,
        'acls' => 'acls',
        'url' => 'url',
        'timeout' => 'timeout',
        'extra' => 'extra',
        'unique_id' => unique_service_id,
        'plans' => {
          'free' => {
            description: new_plan_description,
            free: true,
            extra: nil,
            unique_id: 'unique_plan_id',
          }
        }
      }

      updated_catalog = {
        "#{service_label}_#{service_provider}" => service
      }

      service_plans_path = "/v2/service_plans?service_guid=#{cc_service_guid}"

      stub_request(:get, "http://api.vcap.me/v2/services?inline-relations-depth=2").
        to_return(:status => 200, :body => Yajl::Encoder.encode(
          'resources' => [
            {
              'metadata' => {
                'guid' => cc_service_guid,
              },
              'entity' => {
                'label' => service_label,
                'provider' => service_provider,
                'description' => old_description,
                'service_plans_url' => service_plans_path,
                'free' => true,
                'extra' => nil,
                'unique_id' => unique_service_id
              }
            }
          ]
      ))

      stub_request(:get, "http://api.vcap.me#{service_plans_path}").
        to_return(:status => 200, :body => Yajl::Encoder.encode(
          'resources' => [
            {
              'metadata' => {
                'guid' => cc_service_plan_guid,
              },
              'entity' => {
                'name' => 'free',
                'description' => old_plan_description,
                'free' => true
              }
            }
          ]
      ))

      stub_request(:put, "http://api.vcap.me/v2/services/#{cc_service_guid}").
        to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_guid}))

      stub_request(:put, "http://api.vcap.me/v2/service_plans/#{cc_service_plan_guid}").
        to_return(status: 200)

      EM.run do
        catalog_manager.update_catalog(true, -> { updated_catalog })
        EM.add_timer(1) { EM.stop }
      end

      a_request(:put, "http://api.vcap.me/v2/services/#{cc_service_guid}").with do |req|
        JSON.parse(req.body).should_not have_key('unique_id')
        true
      end.should have_been_made

      a_request(:put, "http://api.vcap.me/v2/service_plans/#{cc_service_plan_guid}").with do |req|
        JSON.parse(req.body).should_not have_key('unique_id')
        true
      end.should have_been_made
    end
  end
end
