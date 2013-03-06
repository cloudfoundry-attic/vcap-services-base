# Copyright (c) 2009-2012 VMware, Inc.
require "helper/spec_helper"

describe "Warden Service test" do
  before :all do
    DataMapper.initialize_lock_file('/tmp/test_lock_file')
    FileUtils.mkdir_p(DEF_OPTIONS[:base_dir])
    FileUtils.mkdir_p(DEF_OPTIONS[:service_log_dir])
    script_dir = File.join(DEF_OPTIONS[:service_common_dir], "bin")
    FileUtils.mkdir_p(script_dir)
    FileUtils.cp(File.expand_path("../assets/warden_service_ctl", File.dirname(__FILE__)), script_dir)
    FileUtils.chmod(0755, File.join(script_dir, "warden_service_ctl"))
    DEF_OPTIONS[:service_bin_dir].each { |_, dir| FileUtils.mkdir_p(dir) }
  end

  after :all do
    FileUtils.rm_rf(DEF_OPTIONS[:base_dir])
  end

  before :each do
    Wardenservice.init(DEF_OPTIONS)
    @instance = Wardenservice.create
  end

  after :each do
    @instance.delete
  end

  describe '.init' do
    subject(:service) { Wardenservice }

    context 'when a warden_socket_path is given' do
      let(:custom_warden_socket_path) { '/tmp/custom.sock' }
      before { service.init(DEF_OPTIONS.merge(warden_socket_path: custom_warden_socket_path)) }

      its(:warden_socket_path) { should == custom_warden_socket_path }
    end

    context 'when no warden_socket_path is given' do
      before { service.init(DEF_OPTIONS.merge(warden_socket_path: nil)) }

      its(:warden_socket_path) { should == '/tmp/warden.sock' }
    end
  end


  it "should store in_memory properties" do
    5.times { Wardenservice.create }
    verify = {}

    Wardenservice.all.each do |ins|
      id = UUIDTools::UUID.random_create.to_s
      ins.failed_times = id
      verify[ins.name] = id
    end

    Wardenservice.all.each do |ins|
      ins.failed_times.should == verify[ins.name]
    end
  end

  it "should be in monitored" do
    @instance.in_monitored?.should be_true
  end

  it "should have correct instance directories" do
    @instance.image_file.should == ""
    @instance.image_file?.should be_false
    @instance.base_dir.should == File.join(@instance.class.base_dir, @instance.name)
    @instance.base_dir?.should be_true
    @instance.log_dir.should == File.join(@instance.class.log_dir, @instance.name)
    @instance.log_dir?.should be_true
    @instance.util_dirs.should be_instance_of Array
    Dir.exists?(@instance.bin_dir).should be_true
    Dir.exists?(@instance.script_dir).should be_true
    Dir.exists?(@instance.common_dir).should be_true
    Dir.exists?(@instance.data_dir).should be_true
  end

  it "should be able to update bind mount directories" do
    bind_dirs = @instance.start_options[:bind_dirs]
    @instance.update_bind_dirs(bind_dirs, {:src => @instance.base_dir}, {:src => "foo", :dst => "bar", :read_only => false})
    find_bind = bind_dirs.select { |bind| bind[:src] == "foo" }
    find_bind.should be_instance_of Array
    find_bind[0][:dst].should == "bar"
    find_bind[0][:read_only].should be_false
  end

  it "should have correct start options" do
    options = @instance.start_options
    options[:service_port].should be_a_kind_of Fixnum
    options[:need_map_port].should be_true
    options[:is_first_start].should be_false
    options[:bind_dirs].should be_instance_of Array
    options[:service_start_timeout].should be_a_kind_of Fixnum
  end

  it "should have correct first start options" do
    options = @instance.start_options
    first_options = @instance.first_start_options
    first_options[:service_port].should == options[:service_port]
    first_options[:need_map_port].should == options[:need_map_port]
    first_options[:is_first_start].should be_true
    first_options[:bind_dirs].should == options[:bind_dirs]
    first_options[:service_start_timeout].should == options[:service_start_timeout]
  end

  it "should have correct stop options" do
    options = @instance.stop_options
    options[:stop_script][:script].should be_instance_of String
  end

  it "should have correct status options" do
    options = @instance.status_options
    options[:status_script][:script].should be_instance_of String
  end

  it "should have correct service script" do
    File.executable?(@instance.service_script)
  end

  it "should have correct memory limit" do
    @instance.memory_limit.should be_nil
    @instance.class.max_memory = 100
    @instance.memory_limit.should == 100
    @instance.class.memory_overhead = 100
    @instance.memory_limit.should == 200
  end

  it "should have correct bandwidth limit" do
    @instance.memory_limit.should be_nil
    @instance.class.bandwidth_per_second = 100
    @instance.bandwidth_limit.should == 100
  end

  it "should run with correct start options" do
    @instance.run
    @instance.running?.should be_true
  end

  it "should raise exception when run with wrong start options" do
    options = @instance.start_options
    options[:start_script] = {}
    expect { @instance.run(options) }.to raise_error
    @instance.running?.should be_false
  end

  it "should stop with correct stop options" do
    @instance.run
    @instance.stop
    @instance.running?.should be_false
  end

  it "should not raise exception when stop with wrong stop options" do
    @instance.run
    options = @instance.stop_options
    options[:stop_script] = {}
    @instance.stop(options)
    @instance.running?.should be_true
  end


  it "should restart after stop" do
    @instance.run
    @instance.stop
    @instance.run
    @instance.running?.should be_true
  end

  it "should run with disk quota enabled" do
    @instance.delete
    @instance.class.image_dir = "/tmp/warden_test"
    @instance.class.quota = true
    @instance.class.max_disk = 100
    @instance = Wardenservice.create
    @instance.image_file?.should be_true
    @instance.loop_setup?.should be_true
    @instance.run
    @instance.running?.should be_true
  end

  it "should be able to resize loop file" do
    @instance.delete
    @instance.class.image_dir = "/tmp/warden_test"
    @instance.class.quota = true
    @instance.class.max_disk = 100
    @instance = Wardenservice.create
    @instance.need_loop_resize?.should be_false
    @instance.class.max_disk = 200
    @instance.need_loop_resize?.should be_true
    @instance.loop_resize
    @instance.loop_setup?.should be_true
    @instance.run
    @instance.running?.should be_true
  end
end
