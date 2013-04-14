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
end
