require "posix/spawn"

module VCAP::Services::Base::Utils

  def self.included(base)
    base.extend(ClassMethods)
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

  def start_instances(all_instances)
    @instance_parallel_start_count = 10 if @instance_parallel_start_count.nil?
    start = 0
    check_set = Set.new
    check_lock = Mutex.new
    while start < all_instances.size
      instances = all_instances.slice(start, [@instance_parallel_start_count, all_instances.size - start].min)
      start = start + @instance_parallel_start_count
      for instance in instances
        @capacity -= capacity_unit
        del_port(instance.port)

        if instance.running? then
          @logger.warn("Service #{instance.name} already listening on port #{instance.port}")
          next
        end

        unless instance.base_dir?
          @logger.warn("Service #{instance.name} in local DB, but not in file system")
          next
        end

        instance.migration_check()
        check_set << instance.name
      end
      threads = (1..instances.size).collect do |i|
        Thread.new(instances[i - 1]) do |t_instance|
          next unless check_lock.synchronize {check_set.include?(t_instance.name)}
          begin
            t_instance.run
          rescue => e
            check_lock.synchronize {check_set.delete(t_instance.name)}
            @logger.error("Error starting instance #{t_instance.name}: #{e}")
          end
          @service_start_timeout.times do
            if is_service_started(t_instance)
              check_lock.synchronize {check_set.delete(t_instance.name)}
              @logger.info("Successfully start provisioned instance #{t_instance.name}")
              break
            end
            sleep 1
          end
        end
      end
      threads.each {|t| t.join}
    end
    check_set.each do |name|
      @logger.error("Timeout to wait for starting provisioned instance #{name}")
    end
  end

  def stop_instances(all_instances)
    @instance_parallel_stop_count = 10 if @instance_parallel_stop_count.nil?
    start = 0
    while start < all_instances.size
      instances = all_instances.slice(start, [@instance_parallel_stop_count, all_instances.size - start].min)
      start = start + @instance_parallel_stop_count
      threads = (1..instances.size).collect do |i|
        Thread.new(instances[i - 1]) do |t_instance|
          begin
            t_instance.stop
            @logger.info("Successfully stop instance #{t_instance.name}")
          rescue => e
            @logger.error("Error stopping instance #{t_instance.name}: #{e}")
          end
        end
      end
      threads.each {|t| t.join}
    end
  end

  def wait_service_start(instance)
    (@service_start_timeout * 10).times do
      sleep 0.1
      return true if is_service_started(instance)
    end
    false
  end

  def is_service_started(instance)
    # Service Node subclasses should override this method to
    # provide service specific check for instance starting status
    true
  end

  module ClassMethods
    def sh(*args)
      options =
        if args[-1].respond_to?(:to_hash)
          args.pop.to_hash
        else
          {}
        end

      skip_raise = options.delete(:raise) == false
      options = { :timeout => 5.0, :max => 1024 * 1024 }.merge(options)

      status = []
      out_buf = ''
      err_buf = ''
      begin
        pid, iwr, ord, erd = POSIX::Spawn::popen4(*args)
        Timeout::timeout(options[:timeout]) do
          status = Process.waitpid2(pid)
        end
        out_buf += ord.read
        err_buf += erd.read
      rescue => e
        Process.kill("TERM", pid) if pid
        Process.detach(pid)
        raise RuntimeError, "sh #{args} timeout: \nstdout: \n#{out_buf}\nstderr: \n#{err_buf}"
      end

      if status[1].exitstatus != 0
        raise RuntimeError, "sh #{args} failed: \n exit with: #{status[1].exitstatus}\nstdout: \n#{out_buf}\nstderr: \n#{err_buf}" unless skip_raise
      end
      status[1].exitstatus
    end
  end
end
