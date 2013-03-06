$LOAD_PATH.unshift File.dirname(__FILE__)
require 'instance_utils'
require 'timeout'

class VCAP::Services::Base::Warden::Service

  include VCAP::Services::Base::Utils
  include VCAP::Services::Base::Warden::InstanceUtils

  class << self

    def init(options)
      @@options = options
      @base_dir = options[:base_dir]
      @log_dir = options[:service_log_dir]
      @common_dir = options[:service_common_dir]
      @bin_dir = options[:service_bin_dir]
      @image_dir = options[:image_dir]
      @logger = options[:logger]
      @max_disk = options[:max_disk]
      @max_memory = options[:max_memory]
      @memory_overhead = options[:memory_overhead]
      @quota = options[:filesystem_quota] || false
      @service_start_timeout = options[:service_start_timeout] || 3
      @service_status_timeout = options[:service_status_timeout] || 3
      @bandwidth_per_second = options[:bandwidth_per_second]
      @service_port = options[:service_port]
      @rm_instance_dir_timeout = options[:rm_instance_dir_timeout] || 10
      @m_failed_times = options[:m_failed_times] || 3
      @warden_socket_path = options[:warden_socket_path] || "/tmp/warden.sock"
      FileUtils.mkdir_p(File.dirname(options[:local_db].split(':')[1]))
      DataMapper.setup(:default, options[:local_db])
      DataMapper::auto_upgrade!
      FileUtils.mkdir_p(base_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(image_dir) if @image_dir
      @in_memory_status = {}
    end

    def define_im_properties(*args)
      args.each do |prop|
        define_method("#{prop}=".to_sym) do |value|
          self.class.in_memory_status[self[:name]] ||= {}
          self.class.in_memory_status[self[:name]][prop] = value
        end

        define_method(prop) do
          self.class.in_memory_status[self[:name]] && self.class.in_memory_status[self[:name]][prop]
        end
      end
    end

    attr_reader :base_dir, :log_dir, :bin_dir, :common_dir, :image_dir, :max_disk, :logger, :quota,
                :max_memory, :memory_overhead, :service_start_timeout, :service_status_timeout,
                :bandwidth_per_second, :service_port, :rm_instance_dir_timeout, :m_failed_times,
                :in_memory_status, :warden_socket_path

  end

  define_im_properties :failed_times

  def in_monitored?
    !failed_times || failed_times <= self.class.m_failed_times
  end

  def logger
    self.class.logger
  end

  def prepare_filesystem(max_size, opts={})
    if base_dir?
      self.class.sh "umount #{base_dir}", :raise => false if self.class.quota
      logger.warn("Service #{self[:name]} base_dir:#{base_dir} already exists, deleting it")
      FileUtils.rm_rf(base_dir)
    end
    if log_dir?
      logger.warn("Service #{self[:name]} log_dir:#{log_dir} already exists, deleting it")
      FileUtils.rm_rf(log_dir)
    end
    if image_file?
      logger.warn("Service #{self[:name]} image_file:#{image_file} already exists, deleting it")
      FileUtils.rm_f(image_file)
    end
    FileUtils.mkdir_p(base_dir)
    FileUtils.mkdir_p(data_dir)
    FileUtils.mkdir_p(log_dir)

    ext_opts = nil
    ext_opts = "-E \"lazy_itable_init=1\"" if opts[:lazy_itable_init]
    if self.class.quota
      self.class.sh "dd if=/dev/null of=#{image_file} bs=1M seek=#{max_size.to_i}"
      self.class.sh "mkfs.ext4 -q -F -O \"^has_journal,uninit_bg\" #{"#{ext_opts}" if ext_opts} #{image_file}"
      loop_setup
    end
  end

  def loop_setdown
    self.class.sh "umount #{base_dir}"
  end

  def loop_setup
    self.class.sh "mount -n -o loop #{image_file} #{base_dir}"
    # Set the dir owner back to the process user
    self.class.sh "chown -R #{Process.uid}:#{Process.gid} #{base_dir}"
  end

  def loop_setup?
    mounted = false
    File.open("/proc/mounts", mode="r") do |f|
      f.each do |w|
        if Regexp.new(base_dir) =~ w
          mounted = true
          break
        end
      end
    end
    mounted
  end

  def need_loop_resize?
    image_file? && File.size(image_file) != self.class.max_disk * 1024 * 1024
  end

  def loop_resize
    loop_up = loop_setup?
    loop_setdown if loop_up
    self.class.sh "cp #{image_file} #{image_file}.bak"
    begin
      old_size = File.size(image_file)
      self.class.sh "resize2fs -f #{image_file} #{self.class.max_disk.to_i}M"
      logger.info("Service #{self[:name]} change loop file size from #{old_size / 1024 / 1024}M to #{self.class.max_disk}M")
    rescue => e
      # Revert image file to the backup if resize raise error
      self.class.sh "cp #{image_file}.bak #{image_file}"
      logger.error("Service #{self[:name]} revert image file for error #{e}")
    ensure
      self.class.sh "rm -f #{image_file}.bak"
    end
    loop_setup if loop_up
  end

  def to_loopfile
    self.class.sh "mv #{base_dir} #{base_dir+"_bak"}"
    self.class.sh "mkdir -p #{base_dir}"
    self.class.sh "A=`du -sm #{base_dir+"_bak"} | awk '{ print $1 }'`;A=$((A+32));if [ $A -lt #{self.class.max_disk.to_i} ]; then A=#{self.class.max_disk.to_i}; fi;dd if=/dev/null of=#{image_file} bs=1M seek=$A"
    self.class.sh "mkfs.ext4 -q -F -O \"^has_journal,uninit_bg\" #{image_file}"
    self.class.sh "mount -n -o loop #{image_file} #{base_dir}"
    self.class.sh "cp -af #{base_dir+"_bak"}/* #{base_dir}", :timeout => 60.0
  end

  def migration_check
    # incase for bosh --recreate, which will delete log dir
    FileUtils.mkdir_p(base_dir) unless base_dir?
    FileUtils.mkdir_p(log_dir) unless log_dir?

    if image_file?
      loop_resize if need_loop_resize?
      unless loop_setup?
        # for case where VM rebooted
        logger.info("Service #{self[:name]} mounting data file")
        loop_setup
      end
    else
      if self.class.quota
        logger.warn("Service #{self[:name]} need migration to quota")
        to_loopfile
      end
    end
  end

  def task(desc)
    begin
      yield
    rescue => e
      logger.error("Fail to #{desc}. Error: #{e}")
    end
  end

  # instance operation helper
  def delete
    container_name = self[:container]
    name = self[:name]
    task "destroy record in local db" do
      destroy! if saved?
    end

    task "delete in-memory status" do
      self.class.in_memory_status.delete(name)
    end

    task "stop container when deleting service #{name}" do
      stop(container_name)
    end

    task "delete instance directories" do
      if self.class.quota
        self.class.sh("rm -f #{image_file}", {:block => false})
      end
      # delete service data directory could be slow, so increase the timeout
      self.class.sh("rm -rf #{base_dir} #{log_dir} #{util_dirs.join(' ')}", {:block => false, :timeout => self.class.rm_instance_dir_timeout})
    end
  end

  def run_command(handle, cmd_hash)
    if cmd_hash[:use_spawn]
      container_spawn_command(handle, cmd_hash[:script], cmd_hash[:use_root])
    else
      container_run_command(handle, cmd_hash[:script], cmd_hash[:use_root])
    end
  end

  # The logic in instance run function is:
  # 0. To avoid to create orphan, clean up container if handle exists
  # 1. Generate bind mount request and create warden container with bind mount options
  # 2. Limit memory and bandwidth of the container (optional)
  # 3. Run pre service start script (optional)
  # 4. Run service start script
  # 5. Create iptables rules for service process (optional)
  # 6. Get container IP address and wait for the service finishing starting
  # 7. Run post service start script (optional)
  # 8. Run post service start block (optional)
  # 9. Save the instance info to local db
  def run(options=nil, &post_start_block)
    stop if self[:container] && self[:container].length > 0
    # If no options specified, then check whether the instance is stored in local db
    # to decide to use which start options
    options = (new? ? first_start_options : start_options) unless options
    loop_setup if self.class.quota && (not loop_setup?)
    bind_mounts = []
    bind_mounts = options[:bind_dirs].map { |bind_dir| bind_mount_request(bind_dir) }
    handle = container_start(bind_mounts)
    self[:container] = handle
    rw_dirs = options[:bind_dirs].map { |bind_dir| bind_dir[:dst] || bind_dir[:src] unless bind_dir[:read_only] }.compact
    run_command(handle, {:script => "chown -R vcap:vcap #{rw_dirs.join(' ')}", :use_root => true}) unless rw_dirs.empty?
    limit_memory(handle, memory_limit) if memory_limit
    limit_bandwidth(handle, bandwidth_limit) if bandwidth_limit
    run_command(handle, options[:pre_start_script]) if options[:pre_start_script]
    run_command(handle, options[:start_script]) if options[:start_script]
    map_port(handle, self[:port], options[:service_port]) if options[:need_map_port]
    rsp = container_info(handle)
    self[:ip] = rsp.container_ip
    # Check whether the service finish starting,
    # the check method can be different depends on whether the service is first start
    raise VCAP::Services::Base::Error::ServiceError::new(VCAP::Services::Base::Error::ServiceError::SERVICE_START_TIMEOUT) unless wait_service_start(options[:service_start_timeout], options[:is_first_start])
    run_command(handle, options[:post_start_script]) if options[:post_start_script]
    # The post start block is some work that need do after first start in provision,
    # where restart this instance, there should be no such work
    post_start_block.call(self) if post_start_block
    save!
    true
  end

  def running?
    finish_start?
  end

  # Usually, stop can retrieve container_name from local_db
  # An exception is unprovision, which destroys record in local_db first.
  def stop(container_name=nil)
    name = container_name || self[:container]
    if container_running?(name)
      begin
        run_command(name, stop_options[:stop_script]) if stop_options[:stop_script]
      rescue => e
        logger.error("Failed to call instance stop script #{stop_options[:stop_script]} with error #{e}")
      end
      container_stop(name)
      container_destroy(name)
      unless container_name
        self[:container] = ''
        save
      end
      loop_setdown if self.class.quota
    end
  end

  # directory helper
  def image_file
    return File.join(self.class.image_dir, "#{self[:name]}.img") if self.class.image_dir
    ''
  end

  def base_dir
    return File.join(self.class.base_dir, self[:name]) if self.class.base_dir
    ''
  end

  def log_dir
    return File.join(self.class.log_dir, self[:name]) if self.class.log_dir
    ''
  end

  def image_file?
    File.exists?(image_file)
  end

  def base_dir?
    Dir.exists?(base_dir)
  end

  def log_dir?
    Dir.exists?(log_dir)
  end

  def util_dirs
    []
  end

  def data_dir
    File.join(base_dir, "data")
  end

  def script_dir
    File.join(self.class.common_dir, "bin")
  end

  def bin_dir
    self.class.bin_dir[version]
  end

  def common_dir
    self.class.common_dir
  end

  def update_bind_dirs(bind_dirs, old_bind, new_bind)
    find_bind = bind_dirs.select { |bind| bind[:src] == old_bind[:src] && bind[:dst] == old_bind[:dst] && bind[:read_only] == old_bind[:read_only] }
    unless find_bind.empty?
      find_bind[0][:src] = new_bind[:src]
      find_bind[0][:dst] = new_bind[:dst]
      find_bind[0][:read_only] = new_bind[:read_only]
    end
  end

  # service start/stop helper
  def wait_service_start(service_start_timeout, is_first_start=false)
    (service_start_timeout * 10).times do
      sleep 0.1
      if is_first_start
        return true if finish_first_start?
      else
        return true if finish_start?
      end
    end
    false
  end

  ### Service Node subclasses can override these following method ###

  # Instance start options, basically the node need define ":start_script",
  # and use other default options.
  def start_options
    bind_dirs = []
    bind_dirs << {:src => bin_dir, :read_only => true}
    bind_dirs << {:src => common_dir, :read_only => true}
    # Since the script "warden_service_ctl" writes log in a hard-code directory "/var/vcap/sys/log/monit,
    # then we need has this directory with write permission in warden container,
    # now the work around is bind-mount instance log dir to "/var/vcap/sys/log/monit"
    bind_dirs << {:src => log_dir, :dst => "/var/vcap/sys/log/monit"}
    bind_dirs << {:src => base_dir}
    bind_dirs << {:src => log_dir}
    bind_dirs.concat util_dirs.map { |dir| {:src => dir} }
    {
      :service_port => self.class.service_port,
      :need_map_port => true,
      :is_first_start => false,
      :bind_dirs => bind_dirs,
      :service_start_timeout => self.class.service_start_timeout,
    }
  end

  # It's the same with start_options except "is_first_start" key by default,
  # but can be different for some services between instance provision (first start)
  # and restart (normal start), then the node subclass need override this function
  def first_start_options
    options = start_options
    options[:is_first_start] = true
    options
  end

  # Check where the service process finish starting,
  # the node subclass should override this function.
  def finish_start?
    true
  end

  # For some services the check methods in instance provision and restart are different,
  # then they should override this method, otherwise the behavior is the same with first_start
  def finish_first_start?
    finish_start?
  end

  # Base user should provide a script to stop instance.
  # if stop_options is empty, the process will get a SIGTERM first then SIGKILL later.
  def stop_options
    {
      :stop_script => {:script => "#{service_script} stop #{base_dir} #{log_dir} #{common_dir}"},
    }
  end

  # Provide a command to monitor the health of instance.
  # if status_options is empty, running? method will only show the health of container
  def status_options
    {
      :status_script => {:script => "#{service_script} status #{base_dir} #{log_dir} #{common_dir}"}
    }
  end

  # Generally the node can use this default service script path
  def service_script
    File.join(script_dir, "warden_service_ctl")
  end

  # Generally the node can use this default calculation method for memory limitation
  def memory_limit
    if self.class.max_memory
      (self.class.max_memory + (self.class.memory_overhead || 0)).to_i
    else
      nil
    end
  end

  # Generally the node can use this default calculation method for bandwidth limitation
  def bandwidth_limit
    self.class.bandwidth_per_second
  end
end
