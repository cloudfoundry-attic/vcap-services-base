module VCAP
  module Services
    module Base
      module Warden
      end
    end
  end
end

module VCAP::Services::Base::Warden::NodeUtils

  attr_accessor :m_interval, :m_actions

  def warden_node_init(options={})
    @m_interval = options[:m_interval] || 10
    @m_actions = options[:m_actions] || []
    setup_monitor_timer
  end

  def setup_monitor_timer
    EM.add_timer(m_interval){ EM.defer{ monitor_all_instances } } if m_interval > 0
  end

  def service_instances
    []
  end

  def init_ports(port_range)
    @free_ports = Set.new
    port_range.each {|port| @free_ports << port}
    @free_ports_lock = Mutex.new
  end

  def new_port(port=nil)
    @free_ports_lock.synchronize do
      raise "No ports available." if @free_ports.empty?
      if port.nil? || !@free_ports.include?(port)
        port = @free_ports.first
        @free_ports.delete(port)
      else
        @free_ports.delete(port)
      end
    end
    port
  end

  def free_port(port)
    @free_ports_lock.synchronize do
      raise "port #{port} already freed!" if @free_ports.include?(port)
      @free_ports.add(port)
    end
  end

  def del_port(port)
    @free_ports_lock.synchronize do
      @free_ports.delete(port)
    end
  end

  def port_occupied?(port)
    Timeout::timeout(1) do
      begin
        TCPSocket.open('localhost', port).close
        return true
      rescue => e
        return false
      end
    end
  end

  def pool_run(params, worker_count=10)
    lock = Mutex.new
    ths = []
    ind = 0
    worker_count.times do |i|
      ths << Thread.new(i) do |tid|
        loop do
          param = nil
          lock.synchronize do
            Thread.exit if ind >= params.size
            param = params[ind]
            ind += 1
          end
          begin
            yield(param, tid)
          rescue => e
            @logger.warn("pool_run error: #{e} from #{caller(1).first(3).join(";")}")
          end
        end
      end
    end
    ths.each(&:join)
  end

  def monitor_all_instances
    params = service_instances.map {|instance| instance }
    lock = Mutex.new
    failed_instances = []
    pool_run(params) do |ins, _|
      if !closing && ins.in_monitored?
        if ins.running?
          ins.failed_times = 0
        else
          ins.failed_times ||= 0
          ins.failed_times += 1
          if ins.in_monitored?
            lock.synchronize { failed_instances << ins }
          else
            @logger.error("Instance #{ins.name} is failed too many times. Unmonitored.")
            ins.stop
          end
        end
      end
    end
    @logger.debug("Found failed_instances: #{failed_instances.map{|i| i.name}}") if failed_instances.size > 0
    m_actions.each do |act|
      unless closing
        method = "#{act}_failed_instances"
        if respond_to?(method.to_sym)
          begin
            send(method.to_sym, failed_instances)
          rescue => e
            @logger.warn("#{method}: #{e}")
          end
        else
          @logger.warn("Failover action #{act} is not defined")
        end
      end
    end
  rescue => e
    @logger.warn("monitor_all_instances: #{e}")
  ensure
    setup_monitor_timer unless closing
  end

  def restart_failed_instances(failed_instances)
    stop_instances(failed_instances)
    start_instances(failed_instances)
  end

  def start_all_instances
    start_instances(service_instances)
  end

  def start_instances(all_instances)
    pool_run(all_instances, @instance_parallel_start_count || 10) do |instance|
      next if closing
      del_port(instance.port)

      if instance.running?
        @logger.warn("Service #{instance.name} already listening on port #{instance.port}")
        next
      end

      unless instance.base_dir?
        @logger.warn("Service #{instance.name} in local DB, but not in file system")
        next
      end

      begin
        instance.migration_check()
      rescue => e
        @logger.error("Error on migration_check: #{e}")
        next
      end

      begin
        instance.run(instance.start_options)
        @logger.info("Successfully start provisioned instance #{instance.name}")
      rescue => e
        @logger.error("Error starting instance #{instance.name}: #{e}")
        # Try to stop the instance since the container could be created
        begin
          instance.stop
        rescue => e
          # Ignore the rollback error and just record a warning log
          @logger.warn("Error stopping instance #{instance.name} when rollback from a starting failure")
        end
      end
    end
  end

  def stop_all_instances
    stop_instances(service_instances)
  end

  def stop_instances(all_instances)
    pool_run(all_instances, @instance_parallel_stop_count || 10) do |instance|
      begin
        instance.stop
        @logger.info("Successfully stop instance #{instance.name}")
      rescue => e
        @logger.error("Error stopping instance #{instance.name}: #{e}")
      end
    end
  end

  def varz_details
    varz = super
    unmonitored = []
    service_instances.each{|ins| unmonitored << ins.name unless ins.in_monitored? }
    varz[:unmonitored] = unmonitored
    varz
  end
end
