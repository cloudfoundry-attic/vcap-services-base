# Copyright (c) 2009-2012 VMware, Inc.
require 'helper/nats_server_helper'
require "helper/spec_helper"

describe "Service node utilities test" do
  before :all do
    @instances_num = 10
    @test = NodeUtilsTest.new(@instances_num)
  end

  it "should initialize warden node monitor setting" do
    EM.run do
      Do.at(0) { @test.warden_node_init }
      Do.at(1) do
        @test.m_interval.should be_a_kind_of Fixnum
        @test.m_actions.should == []
        EM.stop
      end
    end
  end

  it "should initialize port set" do
    @test.init_ports([10000, 10001])
    @test.free_ports.should be_instance_of Set
    @test.free_ports.size.should == 2
  end

  it "should return a new port from port set" do
    @test.init_ports([10000])
    @test.new_port.should == 10000
    @test.free_ports.empty?.should be_true
  end

  it "should raise exception when return a new port from empty port set" do
    @test.init_ports([10000])
    @test.new_port
    expect { @test.new_port }.to raise_error
  end

  it "should be able to specify a port that want to get from the port set" do
    @test.init_ports([10000, 10001, 10002])
    @test.new_port(10001).should == 10001
  end

  it "should recycle the unused port into port set" do
    @test.init_ports([10000])
    @test.new_port
    @test.free_ports.empty?.should be_true
    @test.free_port(10000)
    @test.free_ports.size.should == 1
  end

  it "should raise exception when recycle a free port" do
    @test.init_ports([10000])
    expect { @test.free_port(10000) }.to raise_error
  end

  it "should be able to get service instances list" do
    @test.service_instances.should be_instance_of Array
    @test.service_instances.size.should == @instances_num
  end

  it "should monitor all instances to find failed instances" do
    @test.service_instances.each { |instance| instance.run }
    failed_instance = @test.service_instances[0]
    failed_instance.stop
    EM.run do
      Do.at(0) { @test.warden_node_init }
      Do.at(1) { @test.monitor_all_instances; EM.stop }
    end
    failed_instance.failed_times.should == 1
    @test.service_instances.each { |instance| instance.stop }
  end

  it "should restart failed instances" do
    @test.service_instances.each { |instance| instance.run }
    failed_instance = @test.service_instances[1]
    failed_instance.port = 10000
    failed_instance.stop
    @test.init_ports([10000])
    EM.run do
      Do.at(0) { @test.warden_node_init(:m_actions => ["restart"]) }
      Do.at(1) { @test.monitor_all_instances; EM.stop }
    end
    failed_instance.failed_times.should == 1
    failed_instance.running?.should be_true
    @test.service_instances.each { |instance| instance.stop }
  end

  it "should be able to start multiple instances" do
    instances = []
    ports = []
    @instances_num.times do |i|
      instance = MockInstance.new
      instance.port = 10000 + i
      ports << instance.port
      instances << instance
    end
    @test.init_ports(ports)
    @test.start_instances(instances)
    @test.free_ports.empty?.should be_true
    instances.each { |instance| instance.running?.should be_true }
  end

  it "should be able to stop multiple instances" do
    instances = []
    ports = []
    @instances_num.times do |i|
      instance = MockInstance.new
      instance.port = 10000 + i
      ports << instance.port
      instances << instance
    end
    @test.init_ports(ports)
    @test.start_instances(instances)
    @test.stop_instances(instances)
    instances.each { |instance| instance.running?.should be_false }
  end

  it "should record monitor status in varz details" do
    @test.varz_details[:unmonitored].should == []
    @test.service_instances[0].is_monitored = false
    @test.varz_details[:unmonitored].size == 1
  end
end
