# Copyright (c) 2009-2012 VMware, Inc.
require "helper/spec_helper"

describe "Service instance utilities test" do
  describe '.warden_connect' do
    it 'uses the warden_socket_path to connect to Warden' do
      path = '/tmp/warden.sock'
      InstanceUtilsTest.should_receive(:warden_socket_path).and_return(path)

      Warden::Client.should_receive(:new).with(path).and_call_original
      InstanceUtilsTest.warden_connect
    end
  end

  context 'with an active container' do
    before :all do
      @test = InstanceUtilsTest.new
    end

    before :each do
      @handle = @test.container_start
    end

    after :each do
      @test.container_destroy(@handle)
    end

    it "should create warden container without bind mount argument successfully" do
      @handle.should be_instance_of String
    end

    it "should create warden container with bind mount argument successfully" do
      bind_mount = @test.bind_mount_request(:src => "/mnt")
      handle = @test.container_start([bind_mount])
      handle.should be_instance_of String
      @test.container_destroy(handle)
    end

    it "should raise exception when create warden with wrong bind mount argument" do
      bind_mount = @test.bind_mount_request(:src => "/non_existed_dir")
      expect { @test.container_start([bind_mount]) }.to raise_error(Warden::Client::ServerError)
    end

    it "should destroy warden container successfully" do
      handle = @test.container_start
      @test.container_destroy(handle).should be_true
    end

    it "should raise exception when destroy warden container" do
      expect { @test.container_destroy("unknown_handle") }.to raise_error(Warden::Client::ServerError)
    end

    it "should return correct status of a running container" do
      @test.container_running?(@handle).should be_true
    end

    it "should return correct status of a unknown container" do
      @test.container_running?("unknown_handle").should be_false
    end

    it "should be able to run command" do
      res = @test.container_run_command(@handle, "echo 'hello'")
      res.exit_status.should == 0
      res.stdout.should == "hello\n"
      res.stderr.should == ""
    end

    it "should be able to run privileged command with enable privileged options" do
      res = @test.container_run_command(@handle, "ifconfig", true)
      res.exit_status.should == 0
      res.stdout.should be_instance_of String
      res.stderr.should == ""
    end

    it "should failed to run privileged command without enable privileged options" do
      expect { res = @test.container_run_command(@handle, "ifconfig") }.to raise_error(VCAP::Services::Base::Error::ServiceError)
    end

    it "should be able to spawn command" do
      res = @test.container_spawn_command(@handle, "sleep 100")
      res.ok?.should be_true
    end

    it "should be able to get container information" do
      info = @test.container_info(@handle)
      info.state == "active"
      info.container_ip.should be_instance_of String
    end

    it "should return nil when get unknown container information" do
      @test.container_info("unknown_handle").should be_nil
    end

    it "should be able to limit container memory usage" do
      @test.limit_memory(@handle, 1024).should be_true
    end

    it "should raise exception when limit unknown container memory usage" do
      expect { @test.limit_memory("unknown_handle", 1024) }.to raise_error(Warden::Client::ServerError)
    end

    it "should be able to limit bandwidth usage" do
      @test.limit_bandwidth(@handle, 1024).should be_true
    end

    it "should raise exception when limit unknown container bandwidth usage" do
      expect { @test.limit_bandwidth("unknown_handle", 1024) }.to raise_error(Warden::Client::ServerError)
    end

    it "should be able to map port for a running container" do
      res = @test.map_port(@handle, 11111, 22222)
      res.host_port.should == 11111
      res.container_port.should == 22222
    end

    it "should raise exception when map port for unknown container" do
      expect { @test.map_port("unknown_handle", 11111, 22222) }.to raise_error(Warden::Client::ServerError)
    end
  end
end

