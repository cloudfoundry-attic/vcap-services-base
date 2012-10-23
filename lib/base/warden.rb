# Copyright (c) 2009-2011 VMware, Inc.
require "warden/client"
require "warden/protocol"

$LOAD_PATH.unshift File.dirname(__FILE__)
require "utils"
require "abstract"
require "service_error"

module VCAP::Services::Base::Warden

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def warden_connect
      warden_client = Warden::Client.new("/tmp/warden.sock")
      warden_client.connect
      warden_client
    end
  end

  # warden container operation helper
  def container_start(bind_mounts=[])
    warden = self.class.warden_connect
    req = Warden::Protocol::CreateRequest.new
    unless bind_mounts.empty?
      req.bind_mounts = bind_mounts
    end
    rsp = warden.call(req)
    handle = rsp.handle
    warden.disconnect
    handle
  end

  def container_stop(handle, force=true)
    warden = self.class.warden_connect
    req = Warden::Protocol::StopRequest.new
    req.handle = handle
    req.background = !force
    warden.call(req)
    warden.disconnect
    true
  end

  def container_destroy(handle)
    warden = self.class.warden_connect
    req = Warden::Protocol::DestroyRequest.new
    req.handle = handle
    warden.call(req)
    warden.disconnect
    true
  end

  def container_running?(handle)
    if handle == ''
      return false
    end
    if container_info(handle)
      true
    else
      false
    end
  end

  def container_run_command(handle, cmd, is_privileged=false)
    warden = self.class.warden_connect
    res = nil
    if cmd.is_a?(String)
      req = Warden::Protocol::RunRequest.new
      req.handle = handle
      req.script = cmd
      req.privileged = is_privileged
      res = warden.call(req)
    elsif cmd.is_a?(Array)
      res = {}
      cmd.each do |script|
        req = Warden::Protocol::RunRequest.new
        req.handle = handle
        req.script = script
        req.privileged = is_privileged
        res[script] = warden.call(req)
      end
    end
    warden.disconnect
    res
  end

  def container_spawn_command(handle, cmd, is_privileged=false)
    warden = self.class.warden_connect
    req = Warden::Protocol::SpawnRequest.new
    req.handle = handle
    req.script = cmd
    req.privileged = is_privileged
    res = warden.call(req)
    warden.disconnect
    res
  end

  def container_info(handle)
    warden = self.class.warden_connect
    req = Warden::Protocol::InfoRequest.new
    req.handle = handle
    warden.call(req)
  rescue => e
    nil
  ensure
    warden.disconnect if warden
  end

  def limit_memory(handle, limit)
    warden = self.class.warden_connect
    req = Warden::Protocol::LimitMemoryRequest.new
    req.handle = handle
    req.limit_in_bytes = limit * 1024 * 1024
    warden.call(req)
    warden.disconnect
    true
  end

  def limit_bandwidth(handle, rate)
    warden = self.class.warden_connect
    req = Warden::Protocol::LimitBandwidthRequest.new
    req.handle = handle
    req.rate = rate * 1024 * 1024
    req.burst = rate * 1 * 1024 * 1024 # Set burst the same size as rate
    warden.call(req)
    warden.disconnect
    true
  end

  def bind_mount_request(src, dst)
    bind = Warden::Protocol::CreateRequest::BindMount.new
    bind.src_path = src
    bind.dst_path = dst
    bind.mode = Warden::Protocol::CreateRequest::BindMount::Mode::RW
    bind
  end

  def map_port(handle, src_port, dest_port)
    warden = self.class.warden_connect
    req = Warden::Protocol::NetInRequest.new
    req.handle = handle
    req.host_port = src_port
    req.container_port = dest_port
    res = warden.call(req)
    warden.disconnect
    res
  end
end

class VCAP::Services::Base::WardenService

  include VCAP::Services::Base::Utils
  include VCAP::Services::Base::Warden

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
      FileUtils.mkdir_p(File.dirname(options[:local_db].split(':')[1]))
      DataMapper.setup(:default, options[:local_db])
      DataMapper::auto_upgrade!
      FileUtils.mkdir_p(base_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(image_dir) if @image_dir
    end

    attr_reader :base_dir, :log_dir, :image_dir, :max_disk, :logger, :quota, :max_memory, :memory_overhead, :service_start_timeout, :bandwidth_per_second
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
      self.class.sh "dd if=/dev/null of=#{image_file} bs=1M seek=#{max_size}"
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
    self.class.sh "A=`du -sm #{base_dir+"_bak"} | awk '{ print $1 }'`;A=$((A+32));if [ $A -lt #{self.class.max_disk} ]; then A=#{self.class.max_disk}; fi;dd if=/dev/null of=#{image_file} bs=1M seek=$A"
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
      stop if running?
    rescue
      # Catch the exception and record error log here to guarantee the following cleanup work is done.
      logger.error("Fail to stop container when deleting service #{self[:name]}")
    end
    # delete log and service directory
    pid = Process.fork do
      if self.class.quota
        FileUtils.rm_rf(image_file)
      end
      FileUtils.rm_rf(base_dir)
      FileUtils.rm_rf(log_dir)
      util_dirs.each do |util_dir|
        FileUtils.rm_rf(util_dir)
      end
    end
    Process.detach(pid) if pid
    # delete the record when it's saved
    destroy! if saved?
  end

  def run(&post_start_block)
    loop_setup if self.class.quota && (not loop_setup?)
    bind_mounts = additional_binds.map do |additional_bind|
      bind_mount_request(additional_bind[:src_path], additional_bind[:dst_path])
    end
    bind_mounts << bind_mount_request(base_dir, "/store/instance")
    bind_mounts << bind_mount_request(log_dir, "/store/log")
    handle = container_start(bind_mounts)
    # Set container memory hard limitation
    limit_memory(handle, memory_limit) if memory_limit
    # Set container bandwidth limitation
    limit_bandwidth(handle, bandwidth_limit) if bandwidth_limit
    # Run service pre start script which should be returned quickly,
    # so use the blocked RunRequest.
    # And this script is using root priviledge to run
    container_run_command(handle, pre_start_script, true) if pre_start_script
    # Run service starting script using vcap user
    container_spawn_command(handle, start_script)
    map_port(handle, self[:port], service_port) if need_map_port?
    # Get container virtual IP address
    rsp = container_info(handle)
    self[:ip] = rsp.container_ip
    self[:container] = handle
    # Check whether the service finish starting,
    # the check method can be different depends on whether the service is first start
    raise VCAP::Services::Base::Error::ServiceError::new(VCAP::Services::Base::Error::ServiceError::SERVICE_START_TIMEOUT) unless wait_service_start(!saved?)
    container_run_command(handle, post_start_script) if post_start_script
    # The post start block is some work that need do after first start in provision,
    # where restart this instance, there should be no such work
    post_start_block.call(self) if post_start_block
    save!
    true
  end

  def running?
    container_running?(self[:container])
  end

  def stop
    container_run_command(handle, stop_script) if stop_script
    container_stop(self[:container])
    container_destroy(self[:container])
    self[:container] = ''
    save
    loop_setdown if self.class.quota
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

  def additional_binds
    []
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

  ### Service Node subclasses must override these following method ###

  # Check where the service process finish starting --> true for finish and faluse for not finish
  abstract :finish_start?

  # Service start script, use vcap user to run
  abstract :start_script

  # Service process binding port in warden
  abstract :service_port

  ### Service Node subclasses can override these following method ###

  # For some services the check methods in instance provision and restart are different,
  # then they should override this method, otherwise the behavior is the same with finish_start?
  def finish_first_start?
    finish_start?
  end

  # Service uses this script which replace the function of old "services.conf"
  def pre_start_script
    "pre_service_start.sh"
  end

  # Node can put the script need run before service starting here,
  # and this script is running using vcap privilege
  def post_start_script
    nil
  end

  # If the normal stop way of the service is kill (send SIGTERM signal),
  # then it doesn't need override this method
  def stop_script
    nil
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
    if self.class.bandwidth_per_second
      self.class.bandwidth_per_second
    else
      nil
    end
  end

  # Some services with proxy inside warden container should override this method to return false
  def need_map_port?
    true
  end
end
