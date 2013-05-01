# Copyright (c) 2009-2013 VMware, Inc.
#
require 'helper/catalog_manager_v2_spec_helper'
require 'base/catalog_manager_v2'

describe VCAP::Services::CatalogManagerV2 do
  include VCAP::Services::CatalogManagerV2Helper

  before(:each) do
    @unauth_request = mock("unauth_request")
    @unauth_request.stub_chain("response_header.status") { 401 }

    @normal_request = mock("normal_request")
    @normal_request.stub_chain("response_header.status") { 200 }
    @refresh_time = 0
    described_class.any_instance.stub(:refresh_client_auth_token) {@refresh_time += 1}
  end

  it "should refresh client auth token and retry cc request" do
    config = load_config
    @cm = described_class.new(config)
    @cm.should_receive(:create_http_request).and_return(@unauth_request)
    @cm.should_receive(:create_http_request).and_return(@normal_request)
    @run_once = false
    @cm.cc_http_request(:uri => config[:cloud_controller_uri],
                        :method => 'get') do |http|
      @run_once = true
      http.response_header.status.should == 200
    end
    @run_once.should == true
    # once for startup, once for refresh due to 401 error
    @refresh_time.should == 2
  end

  it "refresh times should not exceed max attempts" do
    config = load_config
    @cm = described_class.new(config)
    @cm.should_receive(:create_http_request).and_return(@unauth_request)
    @cm.should_receive(:create_http_request).and_return(@unauth_request)
    @run_once = false
    max_attempts = 2
    @cm.cc_http_request(:uri => config[:cloud_controller_uri],
                      :method => 'get', :max_attempts => max_attempts) do |http|
      @run_once = true
      http.response_header.status.should == 401
    end
    @run_once.should == true
  end

  it "should read multiple pages from cloud_controller" do
    config = load_config
    @cm = described_class.new(config)

    @page_1 = mock("page_1")
    @page_1.stub_chain("response_header.status").and_return(200)
    @page_1.stub("response") {
      {
        "total_results" => 2, "total_pages" => 2, "prev_url" => nil, "next_url" => "/page/2",
        "resources" => [ "a", "b" ]
      }.to_json
    }

    @page_2 = mock("page_2")
    @page_2.stub_chain("response_header.status").and_return(200)
    @page_2.stub("response") {
      {
        "total_results" => 2, "total_pages" => 2, "prev_url" => "/page/1", "next_url" => nil,
        "resources" => [ "c", "d" ]
      }.to_json
    }

    @cm.should_receive(:create_http_request).and_return(@page_1)
    @cm.should_receive(:create_http_request).and_return(@page_2)

    response = []
    @cm.perform_multiple_page_get("/page", "Test Entries") do |r|
      response << r
    end
    response.size.should == 4
    response.should eq(["a", "b", "c", "d"])
  end

  describe "#process_plans" do
    let(:catalog_manager) { described_class.new(load_config) }
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

  describe "#create_http_request" do
    let(:manager) { described_class.new(load_config) }

    it "makes the appropriate request" do
      uri = 'http://example.com'
      stub_request(:get, uri).to_return(body: "something, something, something... dark side")

      EM.run_block do
        Fiber.new do
          manager.create_http_request(method: 'get', uri: uri)
        end.resume
      end

      a_request(:get, uri).should have_been_made
    end
  end
end
