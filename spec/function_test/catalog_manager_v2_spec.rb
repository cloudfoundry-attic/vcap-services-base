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

    it 'creates services and plans in CC that are not present (using unique_id)' do
      unique_service_id = 'unique_service_id'
      unique_plan_id = 'unique_plan_id'
      catalog = {
        'service_key1' => {
          'label' => 'id-1',
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

    context "when the service and plan in this catalog are already in CC" do
      let(:unique_service_id) { 'unique_service_id' }
      let(:unique_plan_id) { 'unique_plan_id' }
      let(:cc_service_guid) { 'service-guid' }
      let(:cc_service_plan_guid) { 'plan-guid' }
      let(:service_label) { 'id-1.0' }
      let(:service_provider) { 'provider' }
      let(:old_description) { 'old description' }
      let(:new_description) { 'a totally different description' }
      let(:old_plan_description) { 'old plan description' }
      let(:new_plan_description) { 'new plan description' }

      let(:service) do
        {
          'label' => service_label,
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
              unique_id: unique_plan_id,
            }
          }
        }
      end

      let(:updated_catalog) do
        {
          "#{service_label}_#{service_provider}" => service
        }
      end
      let(:service_plans_path) { "/v2/service_plans?service_guid=#{cc_service_guid}" }

      before do
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
                'unique_id' => unique_plan_id,
                'name' => 'free',
                'description' => old_plan_description,
                'free' => true
              }
            }
          ]
        ))
      end

      it 'updates existing plans and services without sending unique_id' do
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
          puts "service_plan update: #{req.body}"
          JSON.parse(req.body).should_not have_key('unique_id')
          true
        end.should have_been_made
      end
    end


    context "when the services in this Catalog already exist in CC, along with services from other brokers" do
      let(:unique_service_id) { 'unique_service_id' }
      let(:unique_plan_id) { 'unique_plan_id' }
      let(:cc_service_guid) { 'service-guid' }
      let(:cc_service_plan_guid) { 'plan-guid' }
      let(:service_label) { 'id-1.0' }
      let(:service_provider) { 'provider' }
      let(:old_description) { 'old description' }
      let(:new_description) { 'a totally different description' }
      let(:old_plan_description) { 'old plan description' }
      let(:new_plan_description) { 'new plan description' }

      let(:service) do
        {
          'label' => service_label,
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
              unique_id: unique_plan_id,
            }
          }
        }
      end

      let(:updated_catalog) do
        {
          "#{service_label}_#{service_provider}" => service
        }
      end
      let(:service_plans_path) { "/v2/service_plans?service_guid=#{cc_service_guid}" }
      let(:other_service_guid) { SecureRandom.uuid }
      let(:other_service_unique_id) { SecureRandom.uuid }
      let(:other_plan_guid) { SecureRandom.uuid }
      let(:other_plans_path) { "/you/shouldnt/send/a/request/here" }

      before do
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
            },
            {
              'metadata' => { 'guid' => other_service_guid },
              'entity' => {
                'label' => 'label',
                'provider' => 'provider',
                'description' => '',
                'service_plans_url' => other_plans_path,
                'free' => true,
                'extra' => nil,
                'unique_id' => other_service_unique_id,
                'bindable' => false
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
                'unique_id' => unique_plan_id,
                'name' => 'free',
                'description' => old_plan_description,
                'free' => true
              }
            }
          ]
        ))

        stub_request(:get, "http://api.vcap.me#{other_plans_path}").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          'resources' => [
            {
              'metadata' => {
                'guid' => other_plan_guid,
              },
              'entity' => {
                'unique_id' => SecureRandom.uuid,
                'name' => 'free',
                'description' => '',
                'free' => true
              }
            }
          ]
        ))

        stub_request(:put, "http://api.vcap.me/v2/services/#{cc_service_guid}").
          to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_guid}))

        stub_request(:put, "http://api.vcap.me/v2/service_plans/#{cc_service_plan_guid}").
          to_return(status: 200)
      end

      it 'only updates the services in this Catalog' do
        update_other_plan_request = stub_request(:put, "http://api.vcap.me/v2/service_plans/#{other_plan_guid}").to_return(:body => {metadata: {guid: other_plan_guid}}.to_json)
        update_other_service_request = stub_request(:put, "http://api.vcap.me/v2/services/#{other_service_guid}").to_return(:body => {metadata: {guid: other_service_guid}}.to_json)

        EM.run do
          catalog_manager.update_catalog(true, -> { updated_catalog })
          EM.add_timer(1) { EM.stop }
        end

        update_other_plan_request.should_not have_been_made
        update_other_service_request.should_not have_been_made
      end
    end

    it 'updates the extra field' do
      unique_service_id = 'unique_service_id'
      cc_service_guid = 'service-guid'
      service_label = 'id-1.0'
      service_provider = 'provider'
      old_extra = '{}'
      new_extra = '{"abc": 123}'

      service = {
        'label' => service_label,
        'provider' => service_provider,
        'version' => '1.0',
        'description' => 'description',
        'acls' => 'acls',
        'url' => 'url',
        'timeout' => 'timeout',
        'extra' => new_extra,
        'unique_id' => unique_service_id,
        'plans' => {}
      }

      updated_catalog = {"#{service_label}_#{service_provider}" => service}

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
              'description' => 'description',
              'service_plans_url' => service_plans_path,
              'free' => true,
              'extra' => old_extra,
              'unique_id' => unique_service_id
            }
          }
        ]
      ))

      stub_request(:get, "http://api.vcap.me#{service_plans_path}").
        to_return(:status => 200, :body => Yajl::Encoder.encode('resources' => []))

      stub_request(:put, "http://api.vcap.me/v2/services/#{cc_service_guid}").
        to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_guid}))

      EM.run do
        catalog_manager.update_catalog(true, -> { updated_catalog })
        EM.add_timer(1) { EM.stop }
      end

      a_request(:put, "http://api.vcap.me/v2/services/#{cc_service_guid}").with do |req|
        JSON.parse(req.body).fetch('extra').should == new_extra
        true
      end.should have_been_made
    end
  end
end
