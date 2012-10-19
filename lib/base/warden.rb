# Copyright (c) 2009-2011 VMware, Inc.
require "warden/client"
require "warden/protocol"
require "utils"

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
  def container_start(cmd, bind_mounts=[])
    warden = self.class.warden_connect
    req = Warden::Protocol::CreateRequest.new
    unless bind_mounts.empty?
      req.bind_mounts = bind_mounts;
    end
    rsp = warden.call(req)
    handle = rsp.handle
    limit_memory(warden, handle, self.class.memory_limit) if self.class.memory_limit
    rsp = info(warden, handle)
    ip = rsp.container_ip
    req = Warden::Protocol::SpawnRequest.new
    req.handle = handle
    req.script = cmd
    rsp = warden.call(req)
    warden.disconnect
    sleep 1
    [handle, ip]
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

    begin
      warden = self.class.warden_connect
      info(warden, handle)
      return true
    rescue => e
      return false
    ensure
      warden.disconnect if warden
    end
  end

  def info(warden, handle)
    req = Warden::Protocol::InfoRequest.new
    req.handle = handle
    warden.call(req)
  end

  def limit_memory(warden, handle, memory_limit)
    req = Warden::Protocol::LimitMemoryRequest.new
    req.handle = handle
    req.limit_in_bytes = memory_limit * 1024 * 1024
    warden.call(req)
  end

  def bind_mount_request(src, dst)
    bind = Warden::Protocol::CreateRequest::BindMount.new
    bind.src_path = src
    bind.dst_path = dst
    bind.mode = Warden::Protocol::CreateRequest::BindMount::Mode::RW
    bind
  end
end

class VCAP::Services::Base::WardenService

  @@iptables_lock = Mutex.new

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
      @quota = options[:filesystem_quota] || false
      FileUtils.mkdir_p(File.dirname(options[:local_db].split(':')[1]))
      DataMapper.setup(:default, options[:local_db])
      DataMapper::auto_upgrade!
      FileUtils.mkdir_p(base_dir)
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(image_dir) if @image_dir
    end

    attr_reader :base_dir, :log_dir, :image_dir, :max_disk, :logger, :quota, :memory_limit
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

  def run
    loop_setup if self.class.quota && (not loop_setup?)
    bind_mounts = additional_binds.map do |additional_bind|
      bind_mount_request(additional_bind[:src_path], additional_bind[:dst_path])
    end
    bind_mounts << bind_mount_request(base_dir, "/store/instance")
    bind_mounts << bind_mount_request(log_dir, "/store/log")
    self[:container], self[:ip] = container_start(service_script, bind_mounts)
    save!
    map_port(self[:port], self[:ip], service_port)
    true
  end

  def running?
    container_running?(self[:container])
  end

  def stop
    unmap_port(self[:port], self[:ip], service_port)
    container_stop(self[:container])
    container_destroy(self[:container])
    self[:container] = ''
    save
    loop_setdown if self.class.quota
  end

  # port map helper
  def iptable(add, src_port, dest_ip, dest_port)
    rule = [ "--protocol tcp",
             "--dport #{src_port}",
             "--jump DNAT",
             "--to-destination #{dest_ip}:#{dest_port}" ]

    iptables_option = add ? "-A":"-D"
    cmd1 = "iptables -t nat #{iptables_option} PREROUTING #{rule.join(" ")}"
    cmd2 = "iptables -t nat #{iptables_option} OUTPUT #{rule.join(" ")}"

    # iptables exit code:
    # The exit code is 0 for correct functioning.
    # Errors which appear to be caused by invalid or abused command line parameters cause an exit code of 2,
    # and other errors cause an exit code of 1.
    #
    # We add a thread lock here, since iptables may return resource unavailable temporary in multi-threads
    # iptables command issued.
    @@iptables_lock.synchronize do
      ret = self.class.sh(cmd1, :raise => false)
      logger.warn("cmd \"#{cmd1}\" invalid") if ret == 2
      ret = self.class.sh(cmd2, :raise => false)
      logger.warn("cmd \"#{cmd2}\" invalid") if ret == 2
    end
  end

  def map_port(src_port, dest_ip, dest_port)
    iptable(true, src_port, dest_ip, dest_port)
  end

  def unmap_port(src_port, dest_ip, dest_port)
    iptable(false, src_port, dest_ip, dest_port)
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
end
