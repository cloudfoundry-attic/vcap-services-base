# Copyright (c) 2009-2011 VMware, Inc.
require 'rubygems'
require 'bundler/setup'
require 'optparse'
require 'yaml'

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..')
require 'vcap/common'
require 'vcap/logging'

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'abstract'

module VCAP
  module Services
    module Base
    end
  end
end

class VCAP::Services::Base::NodeBin

  abstract :default_config_file
  abstract :node_class
  abstract :additional_config

  module Boolean; end
  class ::TrueClass; include Boolean; end
  class ::FalseClass; include Boolean; end

  def start
    config_file = default_config_file

    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0.split(/\//)[-1]} [options]"
      opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
        config_file = opt
      end
      opts.on("-h", "--help", "Help") do
        puts opts
        exit
      end
    end.parse!

    begin
      config = YAML.load_file(config_file)
    rescue => e
      puts "Could not read configuration file:  #{e}"
      exit
    end

    options = {
      :index => parse_property(config, "index", Integer, :optional => true),
      :plan => parse_property(config, "plan", String, :optional => true, :default => "free"),
      :capacity => parse_property(config, "capacity", Integer, :optional => true, :default => 200),
      :ip_route => parse_property(config, "ip_route", String, :optional => true),
      :node_id => parse_property(config, "node_id", String),
      :z_interval => parse_property(config, "z_interval", Integer, :optional => true),
      :mbus => parse_property(config, "mbus", String),
      :local_db => parse_property(config, "local_db", String),
      :migration_nfs => parse_property(config, "migration_nfs", String, :optional => true),
      :max_nats_payload => parse_property(config, "max_nats_payload", Integer, :optional => true),
      :fqdn_hosts => parse_property(config, "fqdn_hosts", Boolean, :optional => true, :default => false),
      :op_time_limit => parse_property(config, "op_time_limit", Integer, :optional => true, :default => 6),
      :supported_versions => parse_property(config, "supported_versions", Array),
      :default_version => parse_property(config, "default_version", String),
      :max_clients => parse_property(config, "max_clients", Integer, :optional => true),
      # Wardenized service configuration
      :base_dir => parse_property(config, "base_dir", String, :optional => true),
      :service_log_dir => parse_property(config, "service_log_dir", String, :optional => true),
      :image_dir => parse_property(config, "image_dir", String, :optional => true),
      :port_range => parse_property(config, "port_range", Range, :optional => true),
      :filesystem_quota => parse_property(config, "filesystem_quota", Boolean, :optional => true, :default => false),
      :service_start_timeout => parse_property(config, "service_start_timeout", Integer, :optional => true, :default => 3),
      :max_memory => parse_property(config, "max_memory", Integer, :optional => true),
      :memory_overhead => parse_property(config, "memory_overhead", Integer, :optional => true),
      :max_disk => parse_property(config, "max_disk", Integer, :optional => true),
    }
      # Work around for different warden configuration structure of postgresql and mysql
    use_warden = parse_property(config, "use_warden", Boolean, :optional => true, :default => false)
    if use_warden
      warden_config = parse_property(config, "warden", Hash, :optional => true)
      options[:service_log_dir] = parse_property(warden_config, "service_log_dir", String)
      options[:port_range] = parse_property(warden_config, "port_range", Range)
      options[:image_dir] = parse_property(warden_config, "image_dir", String)
      options[:filesystem_quota] = parse_property(warden_config, "filesystem_quota", Boolean, :optional => true)
      options[:service_start_timeout] = parse_property(warden_config, "service_start_timeout", Integer, :optional => true, :default => 3)
    end

    VCAP::Logging.setup_from_config(config["logging"])
    # Use the node id for logger identity name.
    options[:logger] = VCAP::Logging.logger(options[:node_id])
    @logger = options[:logger]

    options = additional_config(options, config)

    EM.error_handler do |e|
      @logger.fatal("#{e} #{e.backtrace.join("|")}")
      exit
    end

    pid_file = parse_property(config, "pid", String)
    begin
      FileUtils.mkdir_p(File.dirname(pid_file))
    rescue => e
      @logger.fatal "Can't create pid directory, exiting: #{e}"
      exit
    end
    File.open(pid_file, 'w') { |f| f.puts "#{Process.pid}" }

    EM.run do
      node = node_class.new(options)
      trap("INT") {shutdown(node)}
      trap("TERM") {shutdown(node)}
    end
  end

  def shutdown(node)
    @logger.info("Begin to shutdown node")
    node.shutdown
    @logger.info("End to shutdown node")
    EM.stop
  end

  def parse_property(hash, key, type, options = {})
    obj = hash[key]
    if obj.nil?
      raise "Missing required option: #{key}" unless options[:optional]
      options[:default]
    elsif type == Range
      raise "Invalid Range object: #{obj}" unless obj.kind_of?(Hash)
      first, last = obj["first"], obj["last"]
      raise "Invalid Range object: #{obj}" unless first.kind_of?(Integer) and last.kind_of?(Integer)
      Range.new(first, last)
    else
      raise "Invalid #{type} object: #{obj}" unless obj.kind_of?(type)
      obj
    end
  end
end
