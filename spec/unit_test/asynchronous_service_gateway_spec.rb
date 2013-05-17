# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/spec_helper'
require 'eventmachine'

describe AsyncGatewayTests do
  describe '#get_current_catalog' do
    let(:catalog_manager) {stub("Catalog mgr")}
    let!(:gw) do
      VCAP::Services::AsynchronousServiceGateway.any_instance.stub(:setup)
      gaw = VCAP::Services::AsynchronousServiceGateway.new({}).instance_variable_get(:@app)
      gaw.instance_variable_set(:@catalog_manager, catalog_manager)
      gaw
    end

    it "allows a dash in the label name" do
      catalog_manager.should_receive(:create_key).with("test-data-here", "version", "provider")
      gw.instance_variable_set(:@service, {:version_aliases => {}, :provider => "provider", :label => "test-data-here-version"})
      gw.get_current_catalog
    end

    it "publishes a configured unique_id when present" do
      catalog_manager.stub!(:create_key).and_return("key")
      gw.instance_variable_set(:@service, {:version_aliases => {}, :provider => "provider", :label => "test-data-here-version", :unique_id => "uniqueness"})
      data = gw.get_current_catalog["key"]
      data["unique_id"].should == "uniqueness"
    end

    it "only publishes the unique_id if there is one" do
      catalog_manager.stub!(:create_key).and_return("key")
      gw.instance_variable_set(:@service, {:version_aliases => {}, :provider => "provider", :label => "test-data-here-version"})
      data = gw.get_current_catalog["key"]
      data.should_not have_key "unique_id"
    end

    it 'constructs extra data from parts via the config file' do
      catalog_manager.stub!(:create_key).and_return("key")
      gw.instance_variable_set(:@service, {:version_aliases => {}, :provider => "provider", :label => "test-data-here-version",
                                           :logo_url => "http://example.com/pic.png", :blurb => "One sweet service", :provider_name => "USGOV"})
      decoded_extra = Yajl::Parser.parse(gw.get_current_catalog["key"]["extra"])
      decoded_extra.should == {"listing"=>{"imageUrl"=>"http://example.com/pic.png","blurb"=>"One sweet service"},"provider"=>{"name"=>"USGOV"}}
    end

    it 'wont send extra if not needed' do
      catalog_manager.stub!(:create_key).and_return("key")
      gw.instance_variable_set(:@service, {:version_aliases => {}, :provider => "provider", :label => "test-data-here-version"})
      gw.get_current_catalog["key"].should_not have_key("extra")
    end
  end

  it "should be able to return error when cc uri is invalid" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway_with_invalid_cc; gateway.start }
      Do.at(2) { cc.stop ; gateway.stop ; EM.stop }
    end
  end

  it "should invoke check_orphan in check_orphan_interval time" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_check_orphan_gateway(true, 5, 3); gateway.start }
      Do.at(20) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.check_orphan_invoked.should be_true
    gateway.double_check_orphan_invoked.should be_true
  end

  it "should be able to purge_orphan" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_purge_orphan_request}
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.purge_orphan_http_code.should == 200
  end

  it "should be able to return error when purge_orphan failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_purge_orphan_request}
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.purge_orphan_http_code.should == 500
  end

  it "should be able to check_orphan" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_check_orphan_gateway(true, 10, 3); gateway.start }
      Do.at(2) { gateway.send_check_orphan_request}
      Do.at(10) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.check_orphan_invoked.should be_true
    gateway.double_check_orphan_invoked.should be_true
    gateway.check_orphan_http_code.should == 200
  end

  it "should be able to return error when check_orphan failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_check_orphan_request}
      Do.at(10) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.check_orphan_invoked.should be_true
    gateway.double_check_orphan_invoked.should be_false
    gateway.check_orphan_http_code.should == 500
  end

  it "should be able to provision" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 200
  end

  it "should be able to unprovision" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(3) { gateway.send_unprovision_request }
      Do.at(4) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 200
    gateway.unprovision_http_code.should == 200
  end

  it "should be able to bind" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(3) { gateway.send_bind_request }
      Do.at(4) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 200
    gateway.bind_http_code.should == 200
  end

  it "should be able to unbind" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(3) { gateway.send_bind_request }
      Do.at(4) { gateway.send_unbind_request }
      Do.at(5) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 200
    gateway.bind_http_code.should == 200
    gateway.unbind_http_code.should == 200
  end

  it "should be able to restore" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_restore_request('s_id') }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.restore_http_code.should == 200
  end

  it "should be able to recover" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_recover_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.recover_http_code.should == 200
  end

  it "should be able to migrate instance" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_migrate_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.migrate_http_code.should == 200
  end

  it "should be able to get instance id list" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_instances_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.instances_http_code.should == 200
  end

  it "should not serve request when handle is not fetched" do
    gateway = nil
    EM.run do
      # We don't start cc here, so gateway will fail to fetch handles
      Do.at(0) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(3) { gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 503
  end

  it "should work if provisioner finishes within timeout" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_timeout_gateway(true, 3) ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(13) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 200
  end

  it "should be able to report timeout if provisioner cannot finish within timeout" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_timeout_gateway(false, 3) ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(13) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 503
  end

  it "should work if provisioner finishes within a delay bigger than the default Thin timeout" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_timeout_gateway(true, 35) ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(72) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 200
  end

  it "should be able to return error when provision failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_provision_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.provision_http_code.should == 500
  end

  it "should be able to return error when unprovision failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_unprovision_request('s_id') }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.unprovision_http_code.should == 500
  end

  it "should be able to return error when bind failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_bind_request('s_id') }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.bind_http_code.should == 500
  end

  it "should be able to return error when unbind failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_unbind_request('s_id', 'b_id') }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.unbind_http_code.should == 500
  end

  it "should be able to return error when restore failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_restore_request('s_id') }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.restore_http_code.should == 500
  end

  it "should be able to return error when recover failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_recover_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.recover_http_code.should == 500
  end

  it "should be able to return error when migrate instance failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_migrate_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.migrate_http_code.should == 500
  end

  it "should be able to return error when get instance id list failed" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway ; gateway.start }
      Do.at(2) { gateway.send_instances_request }
      Do.at(3) { cc.stop ; gateway.stop ; EM.stop }
    end
    gateway.instances_http_code.should == 500
  end

  it "should be able to list the existing v2 snapshots" do
    cc = nil
    gateway = nil
    EM.run do
      Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
      Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
      Do.at(2) { gateway.send_get_v2_snapshots_request }
      Do.at(3) { cc.stop; gateway.stop ; EM.stop }
    end
    gateway.snapshots_http_code.should == 200
  end

  context 'creating a snapshot v2' do
    it "should be able to create a new v2 snapshot" do
      cc = nil
      gateway = nil
      EM.run do
        Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
        Do.at(1) { gateway = AsyncGatewayTests.create_nice_gateway ; gateway.start }
        Do.at(2) { gateway.send_create_v2_snapshot_request('new_name') }
        Do.at(3) { cc.stop; gateway.stop ; EM.stop }
      end
      gateway.last_snapshot.name.should == 'new_name'
      gateway.snapshots_http_code.should == 200
    end

    it "should return error" do
      cc = nil
      gateway = nil
      EM.run do
        Do.at(0) { cc = AsyncGatewayTests.create_cloudcontroller ; cc.start }
        Do.at(1) { gateway = AsyncGatewayTests.create_nasty_gateway; gateway.start }
        Do.at(2) { gateway.send_create_v2_snapshot_request('new_name') }
        Do.at(3) { cc.stop; gateway.stop ; EM.stop }
      end
      gateway.snapshots_http_code.should == 500
    end
  end
end
