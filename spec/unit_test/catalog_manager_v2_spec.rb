# Copyright (c) 2009-2013 VMware, Inc.
#
require 'helper/catalog_manager_v2_spec_helper'
require 'base/catalog_manager_v2'

describe VCAP::Services::CatalogManagerV2 do
  include VCAP::Services::CatalogManagerV2Helper

  before do
    @refresh_time = 0
    described_class.any_instance.stub(:refresh_client_auth_token) {@refresh_time += 1}
  end

  context 'mocking itself' do
    before(:each) do
      @unauth_request = mock("unauth_request")
      @unauth_request.stub_chain("response_header.status") { 401 }

      @normal_request = mock("normal_request")
      @normal_request.stub_chain("response_header.status") { 200 }
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

  describe "#advertise_services" do
    before do
      stub_request(:any, "http://example.com/v2/services")
    end

    let(:current_catalog) do
      {
        "mongodb_mongolab"=>{
          "id"=>"mongodb",
          "version"=>"n/a",
          "description"=>"Cloud hosted and managed MongoDB",
          "info_url"=>"https://dev3cloudfoundry.appdirect.com/apps/8",
          "plans"=>{
            "free"=>{
              :description=>"Free", :free=>true
            },
            "small"=>{
              :description=>"Small", :free=>false
            },
            "medium"=>{
              :description=>"Medium", :free=>false
            }, "large"=>{:description=>"Large", :free=>false
            }
          },
          "provider"=>"mongolab",
          "acls"=>{
            :wildcards=>["*@example.com"], :users=>[]
          },
          "url"=>"http://test-mpgw.vcap.me",
          "timeout"=>15,
          "tags"=>[],
          "extra"=>"{\"key\":\"value\"}"
        }
      }
    end

    let(:catalog_in_ccdb){ {} }
    let(:config) { load_config.merge( { cloud_controller_uri: 'http://example.com' }) }
    subject(:catalog_manager) { described_class.new(config) }

    it "posts the catalog information to Cloud Controller" do
      catalog_manager.instance_variable_set(:@current_catalog, current_catalog)
      catalog_manager.instance_variable_set(:@catalog_in_ccdb, catalog_in_ccdb)
      Fiber.new do
        EventMachine.run_block do
          catalog_manager.advertise_services(true)
        end
      end.resume

      expected_body = {
        "label"=>"mongodb",
        "version"=>"n/a",
        "active"=>true,
        "description"=>"Cloud hosted and managed MongoDB",
        "provider"=>"mongolab",
        "extra"  => "{\"key\":\"value\"}",
        "acls"=>{
          "wildcards"=>["*@example.com"],
          "users"=>[]
        },
        "url"=>"http://test-mpgw.vcap.me",
        "timeout"=>15,
      }

      actual_body = nil
      a_request(:post, 'example.com/v2/services').with do |actual_request|
        actual_body = Yajl::Parser.parse(actual_request.body)
      end.should have_been_made
      actual_body.should == expected_body
    end

    it 'refactors the instance variable setters above'
  end
end
