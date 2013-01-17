require "base/warden/node_utils"

class MockInstance
  attr_accessor :is_running, :is_monitored, :failed_times, :port
  def initialize
    @is_running = false
    @is_monitored = true
    @failed_times = 0
    @port = nil
  end

  def run(options={})
    @is_running = true
  end

  def stop
    @is_running = false
  end

  def running?
    @is_running ? true : false
  end

  def in_monitored?
    @is_monitored
  end

  def name
    "mock_intance"
  end

  def base_dir?
    true
  end

  def migration_check
    true
  end

  def start_options
    {}
  end
end

class MockBase
  def varz_details
    {}
  end
end

class NodeUtilsTest < MockBase
  include VCAP::Services::Base::Warden::NodeUtils
  attr_accessor :free_ports, :is_closing, :logger
  def initialize(instances_num=0)
    @instances = []
    @is_closing = false
    @logger = Logger.new(STDOUT)
    instances_num.times { @instances << MockInstance.new }
  end

  def service_instances
    @instances
  end

  def closing
    @is_closing
  end
end
