require 'helper/spec_helper'
require 'base/cloud_controller_services'

describe VCAP::Services::CloudControllerServices do
  let(:client) { double }
  let(:headers) { 'headers' }

  let(:cc_services) {
    described_class.new(client, headers, double("stub logger").as_null_object)
  }

  describe "load_registered_services" do
    let(:service) do
      {
        "metadata" => {"guid" => "asdf"},
        "entity" => {
          "label" => 'mysql',
          "unique_id" => 'u-id',
          "provider" => 'aws',
          "description" => 'description for mysql',
          "version" => 'version 1',
          "url" => 'http://url.com',
          "bindable" => false,
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
          'free' => true,
          :unique_id => "unique_id"
        }
      }
    end

    let(:plan_http) do
      plan_http = double("page_1")
      plan_http.stub_chain(:response_header, :status).and_return(200)
      plan_http.stub(
        "response" => {
          "total_results" => 1, "total_pages" => 1, "prev_url" => nil, "next_url" => nil,
          "resources" => [plan]
        }.to_json
      )
      plan_http
    end

    let(:service_http) do
      service_http = double("page_1")
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

    it "returns a collection of services" do
      result = cc_services.load_registered_services('v2/services')
      result.should be_a Array
      service = result.first
      service.guid.should_not be_nil
      service.label.should == 'mysql'
      service.description.should == 'description for mysql'
      service.provider.should == 'aws'
      service.version.should == 'version 1'
      service.url.should == 'http://url.com'
      service.info_url.should == 'http://info_url.com'
      service.bindable.should == false
    end

    it "contains plans within each service" do
      result = cc_services.load_registered_services('v2/services')
      plans = result.first.plans
      plan = plans.first
      plan.guid.should =='qwer'
      plan.name.should =='10mb'
      plan.description.should =='it is free'
      plan.free.should == true
    end
  end

  describe "#each" do
    it "should read multiple pages from cloud_controller" do
      page_1 = double("page_1")
      page_1.stub_chain(:response_header, :status).and_return(200)
      page_1.stub("response") {
        {
          "total_results" => 2, "total_pages" => 2, "prev_url" => nil, "next_url" => "/page/2",
          "resources" => ["a", "b"]
        }.to_json
      }

      page_2 = double("page_2")
      page_2.stub_chain(:response_header, :status).and_return(200)
      page_2.stub("response") {
        {
          "total_results" => 2, "total_pages" => 2, "prev_url" => "/page/1", "next_url" => nil,
          "resources" => ["c", "d"]
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
      cc_services.each("/page", "Test Entries") do |r|
        response << r
      end
      response.size.should == 4
      response.should eq(["a", "b", "c", "d"])
    end
  end
end
