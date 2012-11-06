require "open3"

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
            t_instance.run(t_instance.start_options)
          rescue => e
            check_lock.synchronize {check_set.delete(t_instance.name)}
            @logger.error("Error starting instance #{t_instance.name}: #{e}")
          end
          @service_start_timeout.times do
            if t_instance.finish_start?
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

  module ClassMethods
    def sh(*args)
      options = args[-1].respond_to?(:to_hash) ? args.pop.to_hash: {}
      options = { :timeout => 5.0, :max => 1024 * 1024, :sudo => true }.merge(options)
      arg = options[:sudo] == false ? args[0] : "sudo " << args[0]

      begin
        stdin, stdout, stderr, status = Open3.popen3(arg)
        pid = status[:pid]
        out_buf = ""
        err_buf = ""
        if options[:nonblock]
          # If the work is still not done after timeout, then kill the process and record an erorr log
          EM.add_timer(options[:timeout]) do
            if status.alive?
              Process.kill("TERM", pid)
              Process.detach(pid)
              logger.error "sh #{args} executed with pid #{pid} timed out" if logger
            else
              logger.error "sh #{args} executed with failure, the exit status is #{status.value.exitstatus}" if status.value.exitstatus != 0 && logger
            end
          end
          return 0
        else
          start = Time.now
          # Manually ping the process per second to check whether the process is alive or not
          while (Time.now - start) < options[:timeout] && status.alive?
            begin
              out_buf << stdout.read_nonblock(4096)
              err_buf << stderr.read_nonblock(4096)
            rescue IO::WaitReadable, EOFError
            end
            sleep 0.2
          end

          if status.alive?
            Process.kill("TERM", pid)
            Process.detach(pid)
            raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} timed out:\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}"
          end
          exit_status = status.value.exitstatus
          raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} exited with #{status.value.exitstatus}:\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}" unless exit_status == 0
          exit_status
        end
      rescue Errno::EPERM
        raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} cannot be killed (privilege issue?):\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}"
      rescue Errno::ESRCH
        raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} does not exist:\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}"
      rescue => e
        raise e
      end
    end
  end
end
