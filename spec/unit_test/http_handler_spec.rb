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

  let(:token_issuer) { double('token_issuer') }

  before do
    CF::UAA::TokenIssuer.stub(:new).and_return(token_issuer)
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
    # This test is gross. However, it is slightly less gross than the test it replaced.

    info1 = {
      'token_type' => 'first_token_type',
      'access_token' => 'first_access_token'
    }
    token_issuer.should_receive(:implicit_grant_with_creds).and_return(double('tokenstuff', info: info1))

    args1 = {
      :uri=>"http://example.com/v2/services/foo",
      :method=>"get",
      :head=>{"Content-Type"=>"application/json", "Authorization"=>"first_token_type first_access_token"}
    }
    http_handler.should_receive(:make_http_request).with(args1).and_return(unauthorized_request)

    info2 = {
      'token_type' => 'second_token_type',
      'access_token' => 'second_access_token'
    }
    token_issuer.should_receive(:implicit_grant_with_creds).and_return(double('tokenstuff', info: info2))

    args2 = {
      :uri=>"http://example.com/v2/services/foo",
      :method=>"get",
      :head=>{"Content-Type"=>"application/json", "Authorization"=>"second_token_type second_access_token"}
    }
    http_handler.should_receive(:make_http_request).with(args2).and_return(authorized_request)

    http_handler.cc_http_request(:uri => "/v2/services/foo", :method => 'get') do |http|
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

      info = {
        'token_type' => 'asdf',
        'access_token' => 'asdf'
      }
      token_issuer.should_receive(:implicit_grant_with_creds).and_return(double('tokenstuff', info: info))

      EM.run_block do
        Fiber.new do
          http_handler.cc_http_request({uri: path, head: "Lincoln", body: "sweet", method: :post}) { |http|}
        end.resume
      end

      a_request(:post, "http://example.com/v2/services").should have_been_made
    end
  end
end
