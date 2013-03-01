require "base/warden/service"

class VCAP::Services::Base::Warden::Service
  class << self
    attr_accessor :image_dir, :max_disk, :quota, :max_memory, :memory_overhead, :bandwidth_per_second
  end
end

DEF_OPTIONS = {
  :base_dir => "/tmp/warden_test",
  :service_log_dir => "/tmp/warden_test/log",
  :service_common_dir => "/tmp/warden_test/common",
  :service_bin_dir => {"1.0" => "/tmp/warden_test/bin/1_0", "2.0" => "/tmp/warden_test/bin/2_0"},
  :service_port => 11111,
  :service_start_timeout => 3,
  :local_db => "sqlite:/tmp/warden_test/base.db",
  :logger => Logger.new(STDOUT),
}

class Wardenservice < VCAP::Services::Base::Warden::Service
  include DataMapper::Resource
  property :name,       String,   :key => true
  property :port,       Integer,  :unique => true
  property :container,  String
  property :ip,         String
  property :version,    String,   :required => false

  private_class_method :new

  class << self

    def create(version="1.0")
      instance = new
      instance.name = UUIDTools::UUID.random_create.to_s
      instance.version = version
      instance.port = instance.class.service_port
      instance.prepare_filesystem(instance.class.max_disk)
      instance
    end
  end

  def start_options
    options = super
    options[:start_script] = {:script => "#{service_script} start #{base_dir} #{log_dir} #{common_dir} #{bin_dir}", :use_spawn => true}
    options
  end

  def finish_start?
    if container_running?(self["container"])
      begin
        run_command(self[:container], status_options[:status_script])
        return true
      rescue => e
      end
    end
    false
  end
end
