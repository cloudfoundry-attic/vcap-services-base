require 'helper/spec_helper'
require 'base/http_handler'

describe HTTPHandler do

  let(:logger) { Logger.new('/tmp/vcap_services_base.log') }

  let(:unauthorized_request) { stub("unauthorized", response_header: stub(status: 401)) }
  let(:authorized_request) { stub("unauthorized", response_header: stub(status: 200)) }
  subject(:http_handler) { described_class.new(logger: logger,
                                               uaa_endpoint: 'http://uaa.example.com',
                                               uaa_client_auth_credentials: {username: "ben ginger"},
                                               uaa_client_id: 'client_id',
                                               cloud_controller_uri: 'http://example.com') }
  before do
    CF::UAA::TokenIssuer.stub(:new).and_return(mock('token_issuer').as_null_object)
  end

  it "refresh times should not exceed max attempts" do
    http_handler.stub(:make_http_request).and_return(unauthorized_request, unauthorized_request)
    http_handler.should_receive(:refresh_client_auth_token).twice

    http_handler.cc_http_request(:uri => '/v2/services',
                            :method => 'get',
                            :max_attempts => 2) do |http|
      http.response_header.status.should == 401
    end
  end

  it "should refresh client auth token and retry cc request" do
    http_handler.stub(:make_http_request).and_return(unauthorized_request)
    http_handler.stub(:make_http_request).and_return(authorized_request)
    http_handler.should_receive(:refresh_client_auth_token).once

    http_handler.cc_http_request(:uri => "v2/services/foo", :method => 'get') do |http|
      http.response_header.status.should == 200
    end

  end

  describe 'generate_cc_advertise_offering_request' do
    it 'generates the correct request' do
      pending 'Need test'
    end
  end

  describe "#cc_http_request" do
    it "makes the appropriate request" do
      path = '/v2/services'
      stub_request(:post, "http://example.com/v2/services").to_return(body: "something, something, something... dark side")

      EM.run_block do
        Fiber.new do
          http_handler.cc_http_request({uri: path, head: "Lincoln", body: "sweet", method: :post}) { |http|}
        end.resume
      end

      a_request(:post, "http://example.com/v2/services").should have_been_made
    end
  end
end