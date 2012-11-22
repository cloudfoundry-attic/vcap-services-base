$LOAD_PATH.unshift File.dirname(__FILE__)
require 'instance_utils'

class VCAP::Services::Base::Warden::Service

  include VCAP::Services::Base::Utils
  include VCAP::Services::Base::Warden::InstanceUtils

  class << self

    def init(options)
      @@options = options
      @base_dir = options[:base_dir]
      @log_dir = options[:service_log_dir]
      @image_dir = options[:image_dir]
      @logger = options[:logger]
      @max_disk = options[:max_disk]
      @max_memory = options[:max_memory]
      @memory_overhead = options[:memory_overhead]
      @quota = options[:filesystem_quota] || false
      @service_start_timeout = options[:service_start_timeout] || 3
      @bandwidth_per_second = options[:bandwidth_per_second]
      @service_port = options[:service_port]
      @rm_instance_dir_timeout = options[:rm_instance_dir_timeout] || 10
      FileUtils.mkdir_p(File.dirname(options[:local_db].split(':')[1]))
      DataMapper.setup(:default, options[:local_db])
      DataMapper::auto_upgrade!
      FileUtils.mkdir_p(base_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(image_dir) if @image_dir
    end

    attr_reader :base_dir, :log_dir, :image_dir, :max_disk, :logger, :quota, :max_memory, :memory_overhead, :service_start_timeout, :bandwidth_per_second, :service_port, :rm_instance_dir_timeout
  end

  def logger
    self.class.logger
  end

  def prepare_filesystem(max_size)
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
    FileUtils.mkdir_p(log_dir)
    if self.class.quota
      self.class.sh "dd if=/dev/null of=#{image_file} bs=1M seek=#{max_size.to_i}"
      self.class.sh "mkfs.ext4 -q -F -O \"^has_journal,uninit_bg\" #{image_file}"
      loop_setup
    end
  end

  def loop_setdown
    self.class.sh "umount #{base_dir}"
  end

  def loop_setup
    self.class.sh "mount -n -o loop #{image_file} #{base_dir}"
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

  # instance operation helper
  def delete
    # stop container
    begin
      stop
    rescue
      # catch the exception and record error log here to guarantee the following cleanup work is done.
      logger.error("Fail to stop container when deleting service #{self[:name]}")
    end
    # delete log and service directory
    begin
      if self.class.quota
        self.class.sh("rm -f #{image_file}", {:block => false})
      end
      # delete serivce data directory could be slow, so increase the timeout
      self.class.sh("rm -rf #{base_dir} #{log_dir} #{util_dirs.join(' ')}", {:block => false, :timeout => self.class.rm_instance_dir_timeout})
    rescue => e
      # catch the exception and record error log here to guarantee the following cleanup work is done.
      logger.error("Fail to delete instance directories, the error is #{e}")
    end
    # delete the record when it's saved
    destroy! if saved?
  end

  def run_command(handle, cmd_hash)
    if cmd_hash[:use_spawn]
      container_spawn_command(handle, cmd_hash[:script], cmd_hash[:use_root])
    else
      container_run_command(handle, cmd_hash[:script], cmd_hash[:use_root])
    end
  end

  # The logic in instance run function is:
  # 1. Generate bind mount request and create warden container with bind mount options
  # 2. Limit memory and bandwidth of the container (optional)
  # 3. Run pre service start script (optional)
  # 4. Run service start script
  # 5. Create iptables rules for service process (optional)
  # 6. Get container IP addresss and wait for the service finishing starting
  # 7. Run post service start script (optional)
  # 8. Run post service start block (optional)
  # 9. Save the instance info to local db
  def run(options=nil, &post_start_block)
    # If no options specified, then check whether the instance is stored in local db
    # to decide to use which start options
    options = (new? ? first_start_options : start_options) unless options
    loop_setup if self.class.quota && (not loop_setup?)
    bind_mounts = []
    if options[:additional_binds]
      bind_mounts = options[:additional_binds].map do |additional_bind|
        bind_mount_request(additional_bind[:src_path], additional_bind[:dst_path])
      end
    end
    bind_mounts << bind_mount_request(base_dir, "/store/instance")
    bind_mounts << bind_mount_request(log_dir, "/store/log")
    handle = container_start(bind_mounts)
    limit_memory(handle, memory_limit) if memory_limit
    limit_bandwidth(handle, bandwidth_limit) if bandwidth_limit
    run_command(handle, options[:pre_start_script]) if options[:pre_start_script]
    run_command(handle, options[:start_script]) if options[:start_script]
    map_port(handle, self[:port], options[:service_port]) if options[:need_map_port]
    rsp = container_info(handle)
    self[:ip] = rsp.container_ip
    self[:container] = handle
    # Check whether the service finish starting,
    # the check method can be different depends on whether the service is first start
    raise VCAP::Services::Base::Error::ServiceError::new(VCAP::Services::Base::Error::ServiceError::SERVICE_START_TIMEOUT) unless wait_service_start(options[:is_first_start])
    run_command(handle, options[:post_start_script]) if options[:post_start_script]
    # The post start block is some work that need do after first start in provision,
    # where restart this instance, there should be no such work
    post_start_block.call(self) if post_start_block
    save!
    true
  end

  def running?
    container_running?(self[:container]) && instance_status?
  end

  def instance_status?
    if status_options
      begin
        run_command(self[:container], status_options[:status_script])
        return true
      rescue => e
        logger.warn("Instance is down. Name: #{self[:name]}; Handle: #{self[:container]}")
      end
    end
    false
  end

  def stop
    if container_running?(self[:container])
      run_command(self[:container], stop_options[:stop_script]) if stop_options[:stop_script]
      container_stop(self[:container])
      container_destroy(self[:container])
      self[:container] = ''
      save
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

  # service start/stop helper
  def wait_service_start(is_first_start=false)
    (self.class.service_start_timeout * 10).times do
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

  # Instance start options, basiclly the node need define ":start_script",
  # and use other default options.
  def start_options
    {
      :pre_start_script => {:script => "pre_service_start.sh", :use_root => true},
      :start_script => {:script => "warden_service_ctl start", :use_spawn => true},
      :service_port => self.class.service_port,
      :need_map_port => true,
      :is_first_start => false,
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
  def first_start?
    true
  end

  # For some services the check methods in instance provision and restart are different,
  # then they should override this method, otherwise the behavior is the same with first_start
  def finish_first_start?
    finish_start?
  end

  # If the normal stop way of the service is kill (send SIGTERM signal),
  # then it doesn't need override this method
  def stop_options
    {
      :stop_script => {:script => "warden_service_ctl stop"}
    }
  end

  def status_options
    {
      :status_script => {:script => "warden_service_ctl status"}
    }
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
