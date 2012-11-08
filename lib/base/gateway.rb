# Copyright (c) 2009-2011 VMware, Inc.
require 'rubygems'
require 'bundler/setup'

require 'optparse'
require 'net/http'
require 'thin'
require 'yaml'

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..')
require 'vcap/common'
require 'vcap/logging'

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'asynchronous_service_gateway'
require 'job/config'
require 'abstract'

module VCAP
  module Services
    module Base
    end
  end
end


class VCAP::Services::Base::Gateway

  abstract :default_config_file
  abstract :provisioner_class

  def parse_config
    config_file = default_config_file

    OptionParser.new do |opts|
      opts.banner = "Usage: $0 [options]"
      opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
        config_file = opt
      end
      opts.on("-h", "--help", "Help") do
        puts opts
        exit
      end
    end.parse!

    begin
      @config = parse_gateway_config(config_file)
    rescue => e
      puts "Couldn't read config file: #{e}"
      exit
    end
  end

  def setup_vcap_logging
    VCAP::Logging.setup_from_config(@config[:logging])
    # Use the current running binary name for logger identity name, since service gateway only has one instance now.
    logger = VCAP::Logging.logger(File.basename($0))
    @config[:logger] = logger
  end

  def setup_async_job_config
    resque = @config[:resque]
    if resque
      resque = VCAP.symbolize_keys(resque)
      VCAP::Services::Base::AsyncJob::Config.redis_config = resque
      VCAP::Services::Base::AsyncJob::Config.logger = @config[:logger]
    end
  end

  def setup_pid
    if @config[:pid]
      pf = VCAP::PidFile.new(@config[:pid])
      pf.unlink_at_exit
    end
  end

  def start
    parse_config

    setup_vcap_logging

    setup_pid

    setup_async_job_config

    @config[:host] = VCAP.local_ip(@config[:ip_route])
    @config[:port] ||= VCAP.grab_ephemeral_port
    @config[:service][:label] = "#{@config[:service][:name]}-#{@config[:service][:version]}"
    @config[:service][:url]   = "http://#{@config[:host]}:#{@config[:port]}"
    node_timeout = @config[:node_timeout] || 5
    cloud_controller_uri = @config[:cloud_controller_uri] || "api.vcap.me"

    # Go!
    EM.run do
      sp = provisioner_class.new(
             :logger   => @config[:logger],
             :index    => @config[:index],
             :ip_route => @config[:ip_route],
             :mbus => @config[:mbus],
             :node_timeout => node_timeout,
             :z_interval => @config[:z_interval],
             :max_nats_payload => @config[:max_nats_payload],
             :additional_options => additional_options,
             :status => @config[:status],
             :plan_management => @config[:plan_management],
             :service => @config[:service],
             :download_url_template => @config[:download_url_template],
           )
      sg = async_gateway_class.new(
             :proxy   => @config[:proxy],
             :service => @config[:service],
             :token   => @config[:token],
             :logger  => @config[:logger],
             :provisioner => sp,
             :node_timeout => node_timeout,
             :cloud_controller_uri => cloud_controller_uri,
             :check_orphan_interval => @config[:check_orphan_interval],
             :double_check_orphan_interval => @config[:double_check_orphan_interval],
             :api_extensions => @config[:api_extensions],
           )

      server = Thin::Server.new(@config[:host], @config[:port], sg)
      server.timeout = @config[:service][:timeout] +1 if @config[:service][:timeout]
      server.start!
    end
  end

  def async_gateway_class
    VCAP::Services::AsynchronousServiceGateway
  end

  def parse_gateway_config(config_file)
    config = YAML.load_file(config_file)
    config = VCAP.symbolize_keys(config)

    token = config[:token]
    raise "Token missing" unless token
    raise "Token must be a String or Int, #{token.class} given" unless (token.is_a?(Integer) || token.is_a?(String))
    config[:token] = token.to_s

    config
  end

  def additional_options
    {}
  end
end
