# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/spec_helper'
require 'helper/nats_server_helper'
require 'eventmachine'

describe ProvisionerTests do

  %W(v1 v2).each do |version|

    it "should autodiscover 1 node when started first (#{version})" do
      provisioner = nil
      node = nil
      # start provisioner, then node
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { node = ProvisionerTests.create_node(1) }
        Do.at(2) { EM.stop }
      end
      provisioner.node_count.should == 1
    end

    it "should autodiscover 3 nodes when started first (#{version})" do
      provisioner = nil
      node1 = nil
      node2 = nil
      node3 = nil
      # start provisioner, then nodes
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { node1 = ProvisionerTests.create_node(1) }
        Do.at(2) { node2 = ProvisionerTests.create_node(2) }
        Do.at(3) { node3 = ProvisionerTests.create_node(3) }
        Do.at(4) { EM.stop }
      end
      provisioner.node_count.should == 3
    end

    it "should support provision (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { EM.stop }
      end
      gateway.got_provision_response.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should handle error in provision (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { EM.stop }
      end
      node.got_provision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
      gateway.provision_response.should be_false
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should pick the best node when provisioning (#{version})" do
      provisioner = nil
      gateway = nil
      node1 = nil
      node2 = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node1 = ProvisionerTests.create_node(1, 1) }
        Do.at(3) { node2 = ProvisionerTests.create_node(2, 2) }
        Do.at(4) { gateway.send_provision_request }
        Do.at(5) { EM.stop }
      end
      node1.got_provision_request.should be_false
      node2.got_provision_request.should be_true
    end

    it "should avoid over provision when provisioning (#{version})" do
      provisioner = nil
      gateway = nil
      node1 = nil
      node2 = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node1 = ProvisionerTests.create_node(1, 1) }
        Do.at(3) { node2 = ProvisionerTests.create_node(2, 1) }
        Do.at(4) { gateway.send_provision_request; gateway.send_provision_request }
        Do.at(10) { gateway.send_provision_request }
        Do.at(15) { EM.stop }
      end
      node1.got_provision_request.should be_true
      node2.got_provision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 2
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should raise error on provisioning error plan (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request("error_plan") }
        Do.at(4) { EM.stop }
      end
      node.got_provision_request.should be_false
      gateway.provision_response.should be_false
      gateway.error_msg['status'].should == 400
      gateway.error_msg['msg']['code'].should == 30003
    end


    it "should support unprovision (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_unprovision_request }
        Do.at(5) { EM.stop }
      end
      node.got_unprovision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should delete instance handles in cache after unprovision (#{version})" do
      provisioner = gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
          provisioner.get_all_handles.size.should == 0
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_bind_request }
        Do.at(5) { gateway.send_unprovision_request }
        Do.at(6) { EM.stop }
      end
      node.got_provision_request.should be_true
      node.got_bind_request.should be_true
      node.got_unprovision_request.should be_true
      provisioner.get_all_handles.size.should == 0
    end

    it "should handle error in unprovision (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { ProvisionerTests.setup_fake_instance(gateway, provisioner, node) }
        Do.at(4) { gateway.send_unprovision_request }
        Do.at(5) { EM.stop }
      end
      node.got_unprovision_request.should be_true
      gateway.unprovision_response.should be_false
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
      gateway.error_msg.should_not == nil
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should support bind (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_bind_request }
        Do.at(5) { EM.stop }
      end
      gateway.got_provision_response.should be_true
      gateway.got_bind_response.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 1
    end

    it "should handle error in bind (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { ProvisionerTests.setup_fake_instance(gateway, provisioner, node) }
        Do.at(4) { gateway.send_bind_request }
        Do.at(5) { EM.stop }
      end
      node.got_bind_request.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 0
      gateway.bind_response.should be_false
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should handle error in unbind (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) do
          ProvisionerTests.setup_fake_instance(gateway, provisioner, node)
          ProvisionerTests.setup_fake_binding(gateway, provisioner, node)
        end
        Do.at(5) { gateway.send_unbind_request }
        Do.at(6) { EM.stop }
      end
      node.got_unbind_request.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 0
      gateway.unbind_response.should be_false
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should support restore (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_restore_request }
        Do.at(5) { EM.stop }
      end
      gateway.got_restore_response.should be_true
    end

    it "should handle error in restore (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { ProvisionerTests.setup_fake_instance(gateway, provisioner, node) }
        Do.at(4) { gateway.send_restore_request }
        Do.at(5) { EM.stop }
      end
      node.got_restore_request.should be_true
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should support recover (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1, 2) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_recover_request }
        Do.at(10) { EM.stop }
      end
      gateway.got_recover_response.should be_true
    end

    it "should support migration (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1, 2) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_migrate_request("node-1") }
        Do.at(10) { EM.stop }
      end
      gateway.got_migrate_response.should be_true
    end

    it "should handle error in migration (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { ProvisionerTests.setup_fake_instance(gateway, provisioner, node) }
        Do.at(4) { gateway.send_migrate_request("node-1") }
        Do.at(5) { EM.stop }
      end
      node.got_migrate_request.should be_true
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should support get instance id list (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { gateway.send_instances_request("node-1") }
        Do.at(5) { EM.stop }
      end
      gateway.got_instances_response.should be_true
    end

    it "should handle error in getting instance id list (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { ProvisionerTests.setup_fake_instance(gateway, provisioner, node) }
        Do.at(4) { gateway.send_migrate_request("node-1") }
        Do.at(5) { EM.stop }
      end
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should allow over provisioning when it is configured so (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {
            :cc_api_version => version,
            :plan_management => {:plans => {:free => {:allow_over_provisioning => true }}},
          }
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1, -1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { EM.stop }
      end
      node.got_provision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should not allow over provisioning when it is not configured so (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {
            :cc_api_version => version,
            :plan_management => {:plans => {:free => {:allow_over_provisioning => false }}},
          }
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1, -1) }
        Do.at(3) { gateway.send_provision_request }
        Do.at(4) { EM.stop }
      end
      node.got_provision_request.should be_false
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should support check orphan (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(2) }
        Do.at(3) { node = ProvisionerTests.create_node(3) }
        Do.at(4) { gateway.send_check_orphan_request }
        Do.at(8) { gateway.send_double_check_orphan_request }
        Do.at(10) { EM.stop }
      end
      provisioner.staging_orphan_instances["node-2"].count.should == 2
      provisioner.staging_orphan_instances["node-3"].count.should == 2
      provisioner.final_orphan_instances["node-2"].count.should == 1
      provisioner.final_orphan_instances["node-3"].count.should == 2
      provisioner.staging_orphan_bindings["node-2"].count.should == 1
      provisioner.staging_orphan_bindings["node-3"].count.should == 2
      provisioner.final_orphan_bindings["node-2"].count.should == 1
      provisioner.final_orphan_bindings["node-3"].count.should == 2
    end

    it "should handle error in check orphan (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) { gateway.send_check_orphan_request }
        Do.at(4) { EM.stop }
      end
      node.got_check_orphan_request.should be_true
      provisioner.staging_orphan_instances["node-1"].should be_nil
      provisioner.final_orphan_instances["node-1"].should be_nil
    end

    it "should support purging massive orphans (#{version})" do
      provisioner = nil
      gateway = nil
      node = nil
      node2 = nil
      EM.run do
        Do.at(0) do
          options = {:cc_api_version => version}
          provisioner = ProvisionerTests.create_provisioner(options)
        end
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner, 1024 * 128, 1024 * 16) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(4) { gateway.send_purge_orphan_request }
        Do.at(60) { EM.stop }
      end
      node.got_purge_orphan_request.should be_true
      gateway.got_purge_orphan_response.should be_true
      node.purge_ins_list.count.should == 1024 * 128
      node.purge_bind_list.count.should == 1024 * 16
    end

  end
end
