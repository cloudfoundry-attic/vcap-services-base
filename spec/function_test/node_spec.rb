# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/spec_helper'
require 'helper/nats_server_helper'
require 'eventmachine'

describe NodeTests do
  include VCAP::Services::Internal

  it "should call varz" do
    node = nil
    provisioner = nil
    EM.run do
      # start provisioner then node
      Do.at(0) { provisioner = NodeTests.create_provisioner }
      Do.at(1) {
        node = NodeTests.create_node
        stop_event_machine_when { node.varz_invoked }
      }
    end
    node.varz_invoked.should be_true
  end

  it "should report healthz ok" do
    node = nil
    provisioner = nil
    EM.run do
      # start provisioner then node
      Do.at(0) { provisioner = NodeTests.create_provisioner }
      Do.at(1) {
        node = NodeTests.create_node
        stop_event_machine_when { node.healthz_ok == "ok\n" }
      }
    end
    node.healthz_ok.should == "ok\n"
  end

  it "should announce on identical plan" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node(:plan => "free") }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_discover_by_plan("free")
        stop_event_machine_when { provisioner.got_announcement_by_plan == true }
      }
    end
    provisioner.got_announcement_by_plan.should be_true
  end

  it "should not announce on different plan" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node(:plan => "free") }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) { provisioner.send_discover_by_plan("nonfree") }
      Do.at(3) { EM.stop }
    end
    provisioner.got_announcement_by_plan.should be_false
  end

  it "should not announce if not ready" do
    node = nil
    provisioner = nil
    EM.run do
      # start provisioner then node
      Do.at(0) { node = NodeTests.create_node; node.set_ready(false) }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) { EM.stop }
    end
    provisioner.got_announcement.should be_false
  end

  it "should handle error in node provision" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.sec(0) { node = NodeTests.create_error_node }
      Do.sec(1) { provisioner = NodeTests.create_error_provisioner}
      Do.sec(2) {
        provisioner.send_provision_request
        stop_event_machine_when { node.provision_invoked && provisioner.response =~ /Service unavailable/ }
      }
    end
    node.provision_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should decrease capacity after successful provision" do
    node = nil
    provisioner = nil
    original_capacity = 0
    EM.run do
      Do.sec(0) { node = NodeTests.create_node; original_capacity = node.capacity }
      Do.sec(1) { provisioner = NodeTests.create_provisioner}
      Do.sec(2) {
        provisioner.send_provision_request
        stop_event_machine_when { (original_capacity - node.capacity) > 0 }
      }
    end
    (original_capacity - node.capacity).should > 0
  end

  it "should not decrease capacity after erroneous provision" do
    node = nil
    provisioner = nil
    original_capacity = 0
    EM.run do
      Do.sec(0) { node = NodeTests.create_error_node; original_capacity = node.capacity }
      Do.sec(1) { provisioner = NodeTests.create_provisioner}
      Do.sec(2) {
        provisioner.send_provision_request
        stop_event_machine_when { (original_capacity - node.capacity) == 0}
      }
    end
    (original_capacity - node.capacity).should == 0
  end

  it "should support unprovision" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_unprovision_request
        stop_event_machine_when { node.unprovision_invoked }
      }
    end
    node.unprovision_invoked.should be_true
  end

  it "should handle error in unprovision" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_unprovision_request
        stop_event_machine_when {
          node.unprovision_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.unprovision_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should increase capacity after successful unprovision" do
    node = nil
    provisioner = nil
    original_capacity = 0
    EM.run do
      Do.sec(0) { node = NodeTests.create_node; original_capacity = node.capacity }
      Do.sec(1) { provisioner = NodeTests.create_provisioner }
      Do.sec(2) {
        provisioner.send_unprovision_request
        stop_event_machine_when { (original_capacity - node.capacity) < 0 }
      }
    end
    (original_capacity - node.capacity).should < 0
  end

  it "should not increase capacity after erroneous unprovision" do
    node = nil
    provisioner = nil
    original_capacity = 0
    EM.run do
      Do.sec(0) { node = NodeTests.create_error_node; original_capacity = node.capacity }
      Do.sec(1) { provisioner = NodeTests.create_provisioner }
      Do.sec(2) {
        provisioner.send_unprovision_request
        stop_event_machine_when { (original_capacity - node.capacity) == 0 }
      }
    end
    (original_capacity - node.capacity).should == 0
  end

  it "should support bind" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_bind_request
        stop_event_machine_when { node.bind_invoked }
      }
    end
    node.bind_invoked.should be_true
  end

  it "should handle error in bind" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_bind_request
        stop_event_machine_when {
          node.bind_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.bind_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support unbind" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_unbind_request
        stop_event_machine_when { node.unbind_invoked }
      }
    end
    node.unbind_invoked.should be_true
  end

  it "should handle error in unbind" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_unbind_request
        stop_event_machine_when {
          provisioner.response =~ /Service unavailable/ && node.unbind_invoked
        }
      }
    end
    node.unbind_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support restore" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_restore_request
        stop_event_machine_when { node.restore_invoked }
      }
      Do.at(20) { EM.stop }
    end
    node.restore_invoked.should be_true
  end

  it "should handle error in restore" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_restore_request
        stop_event_machine_when {
          node.restore_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.restore_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support disable instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_disable_request
        stop_event_machine_when { node.disable_invoked }
      }
    end
    node.disable_invoked.should be_true
  end

  it "should handle error in disable instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_disable_request
        stop_event_machine_when {
          node.disable_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.disable_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support enable instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_enable_request
        stop_event_machine_when { node.enable_invoked }
      }
    end
    node.enable_invoked.should be_true
  end

  it "should handle error in enable instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_enable_request
        stop_event_machine_when {
          node.enable_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.enable_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support import instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_import_request
        stop_event_machine_when { node.import_invoked }
      }
    end
    node.import_invoked.should be_true
  end

  it "should handle error in import instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_import_request
        stop_event_machine_when {
          node.import_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.import_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support update instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_update_request
        stop_event_machine_when { node.update_invoked }
      }
    end
    node.update_invoked.should be_true
  end

  it "should handle error in update instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_error_node }
      Do.at(1) { provisioner = NodeTests.create_error_provisioner }
      Do.at(2) {
        provisioner.send_update_request
        stop_event_machine_when {
          node.update_invoked && provisioner.response =~ /Service unavailable/
        }
      }
    end
    node.update_invoked.should be_true
    provisioner.response.should =~ /Service unavailable/
  end

  it "should support cleanupnfs instance" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_cleanupnfs_request
        stop_event_machine_when { provisioner.got_cleanupnfs_response }
      }
    end
    provisioner.got_cleanupnfs_response.should be_true
  end

  it "should decrease capacity after successful migration" do
    node = nil
    provisioner = nil
    original_capacity = 0
    EM.run do
      Do.sec(0) { node = NodeTests.create_node; original_capacity = node.capacity }
      Do.sec(1) { provisioner = NodeTests.create_provisioner}
      Do.sec(2) {
        provisioner.send_update_request
        stop_event_machine_when { (original_capacity - node.capacity) == 1 }
      }
    end
    (original_capacity - node.capacity).should == 1
  end

  it "should not decrease capacity after erroneous migration" do
    node = nil
    provisioner = nil
    original_capacity = 0
    EM.run do
      Do.sec(0) { node = NodeTests.create_error_node; original_capacity = node.capacity }
      Do.sec(1) { provisioner = NodeTests.create_provisioner}
      Do.sec(2) {
        provisioner.send_update_request
        stop_event_machine_when { (original_capacity - node.capacity) == 0 }
      }
    end
    (original_capacity - node.capacity).should == 0
  end

  it "should support check_orphan when no handles" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node}
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_check_orphan_request
        stop_event_machine_when {
          provisioner.ins_hash[TEST_NODE_ID].empty? &&
          provisioner.bind_hash[TEST_NODE_ID].empty?
        }
      }
    end
    provisioner.ins_hash[TEST_NODE_ID].count.should == 0
    provisioner.bind_hash[TEST_NODE_ID].count.should == 0
  end

  it "should support check_orphan when node has massive instances" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node(:ins_count => 1024 * 128, :bind_count => 1024)}
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_check_orphan_request
        stop_event_machine_when {
          provisioner.ins_hash[TEST_NODE_ID].count == 1024 * 128 &&
          provisioner.bind_hash[TEST_NODE_ID].count == 1024
        }
      }
    end
    provisioner.ins_hash[TEST_NODE_ID].count.should == 1024 * 128
    provisioner.bind_hash[TEST_NODE_ID].count.should == 1024
  end

  it "should support check_orphan when node has massive bindings" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node(:ins_count => 1024, :bind_count => 1024 * 64)}
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_check_orphan_request
        stop_event_machine_when {
          provisioner.ins_hash[TEST_NODE_ID].count == 1024 &&
          provisioner.bind_hash[TEST_NODE_ID].count == 1024 * 64
        }
      }
    end
    provisioner.ins_hash[TEST_NODE_ID].count.should == 1024
    provisioner.bind_hash[TEST_NODE_ID].count.should == 1024 * 64
  end

  it "should support check_orphan when node has massive handles" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node(:ins_count => 1024 * 128, :bind_count => 1024 * 16)}
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_check_orphan_request
        stop_event_machine_when {
          provisioner.ins_hash[TEST_NODE_ID].count == 1024 * 128 &&
          provisioner.bind_hash[TEST_NODE_ID].count == 1024 * 16
        }
      }
    end
    provisioner.ins_hash[TEST_NODE_ID].count.should == 1024 * 128
    provisioner.bind_hash[TEST_NODE_ID].count.should == 1024 * 16
  end

  it "should support purge_orphan" do
    node = nil
    provisioner = nil
    EM.run do
      # start node then provisioner
      Do.at(0) { node = NodeTests.create_node }
      Do.at(1) { provisioner = NodeTests.create_provisioner }
      Do.at(2) {
        provisioner.send_purge_orphan_request
        stop_event_machine_when {
          node.unprovision_count == 2 && node.unbind_count == 2
        }
      }
    end
    node.unprovision_count.should == 2
    node.unbind_count.should == 2
  end
end
