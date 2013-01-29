# Copyright (c) 2009-2013 VMware, Inc.
#
require 'helper/catalog_manager_v2_spec_helper'
require 'base/catalog_manager_v2'

describe VCAP::Services::CatalogManagerV2 do
  include VCAP::Services::CatalogManagerV2Helper


  it "should refresh client auth token" do
    def auth_header
      @cm.cc_req_hdrs['Authorization']
    end

    class VCAP::Services::CatalogManagerV2
      attr_reader :cc_req_hdrs
    end

    mock_token_issuer = mock('mock_token_issuer')
    token1 = {
      "token_type" => "bearer",
      "access_token" => "1",
      "expires_in"=> 4,
    }

    token2 = {
      "token_type" => "bearer",
      "access_token" => "2",
      "expires_in"=> 10,
    }
    t1 = mock("initial_token")
    t1.stub(:info).and_return(token1)
    t2 = mock("refreshed_token")
    t2.stub(:info).and_return(token2)

    mock_token_issuer.should_receive(:implicit_grant_with_creds).and_return(t1)
    mock_token_issuer.should_receive(:implicit_grant_with_creds).and_return(t2)

    CF::UAA::TokenIssuer.stub(:new).and_return(mock_token_issuer)

    config = load_config
    EM.run do
      @cm = described_class.new(config)
      auth_header.should == "bearer 1"
      EM.add_timer(5) {auth_header.should == "bearer 2"; EM.stop}
    end
  end
end
