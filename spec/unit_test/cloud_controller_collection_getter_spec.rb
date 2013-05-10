require 'helper/spec_helper'
require 'base/cloud_controller_collection_getter'

describe VCAP::Services::CloudControllerCollectionGetter do
  let(:client) { stub }
  let(:headers) { 'headers' }

  subject(:getter) {
    described_class.new(client, headers, double("stub logger").as_null_object)
  }

  describe "#load_registered_services" do
    let(:service) do
      {
        "metadata" => {"guid" => "asdf"},
        "entity" => {
          "label" => 'mysql',
          "provider" => 'aws',
          "description" => 'description for mysql',
          "version" => 'version 1',
          "url" => 'http://url.com',
          'info_url' => 'http://info_url.com',
          'service_plans_url' => 'v2/services/asdf/service_plans'
        },
      }
    end

    let(:plan) do
      {
        "metadata" => {"guid" => "qwer"},
        "entity" => {
          "name" => '10mb',
          "description" => 'it is free',
          'free' => true
        }
      }
    end

    let(:plan_http) do
      plan_http = mock("page_1")
      plan_http.stub_chain(:response_header, :status).and_return(200)
      plan_http.stub(
        "response" => {
          "total_results" => 1, "total_pages" => 1, "prev_url" => nil, "next_url" => nil,
          "resources" => [plan]
        }.to_json
      )
     plan_http
    end

    let(:auth_token_registry) do
      stub('auth-tokens', :has_key? => true)
    end

    let(:service_http) do
      service_http = mock("page_1")
      service_http.stub_chain(:response_header, :status).and_return(200)
      service_http.stub(
        "response" => {
          "total_results" => 1, "total_pages" => 1, "prev_url" => nil, "next_url" => nil,
          "resources" => [service]
        }.to_json
      )
      service_http
    end

    before do
      client.stub(:call).with(hash_including(:uri => 'v2/services')).and_yield(service_http)
      client.stub(:call).with(hash_including(:uri => 'v2/services/asdf/service_plans')).and_yield(plan_http)
    end

    it "only loads the service in the token registry" do
      auth_token_registry.stub(:has_key? => false)
      result = getter.load_registered_services('v2/services', auth_token_registry)
      result.should be_empty
    end

    it "checks the service in the token registry" do
      auth_token_registry.should_receive(:has_key?).with(:mysql_aws)
      result = getter.load_registered_services('v2/services', auth_token_registry)
    end

    it "returns a hash of services" do
      result = getter.load_registered_services('v2/services', auth_token_registry)
      result.should be_a Hash
      result.keys.should == ["mysql_aws"]
      result["mysql_aws"].keys.should match_array(["guid", "service"])
      result["mysql_aws"]["service"].should include({
        'id' => 'mysql',
        'description' => 'description for mysql',
        'provider'  => 'aws',
        'version' => 'version 1',
        'url' => 'http://url.com',
        'info_url' => 'http://info_url.com'
      })
    end

    it "contains plans within each service" do
      result = getter.load_registered_services('v2/services', auth_token_registry)
      plans = result["mysql_aws"]["service"]["plans"]
      plans.keys.should eq(["10mb"])
      plans["10mb"].should eq({
        'guid' => 'qwer',
        'name' => '10mb',
        'description' => 'it is free',
        'free' => true,
      })
    end
  end

  describe "#each" do
    it "should read multiple pages from cloud_controller" do
      page_1 = mock("page_1")
      page_1.stub_chain(:response_header, :status).and_return(200)
      page_1.stub("response") {
        {
          "total_results" => 2, "total_pages" => 2, "prev_url" => nil, "next_url" => "/page/2",
          "resources" => [ "a", "b" ]
        }.to_json
      }

      page_2 = mock("page_2")
      page_2.stub_chain(:response_header, :status).and_return(200)
      page_2.stub("response") {
        {
          "total_results" => 2, "total_pages" => 2, "prev_url" => "/page/1", "next_url" => nil,
          "resources" => [ "c", "d" ]
        }.to_json
      }

      client.should_receive(:call).with(
        :uri => "/page",
        :method => "get",
        :head => headers,
        :need_raise => true,
      ).and_yield(page_1)

      client.should_receive(:call).with(
        :uri => "/page/2",
        :method => "get",
        :head => headers,
        :need_raise => true,
      ).and_yield(page_2)

      response = []
      getter.each("/page", "Test Entries") do |r|
        response << r
      end
      response.size.should == 4
      response.should eq(["a", "b", "c", "d"])
    end
  end
end
