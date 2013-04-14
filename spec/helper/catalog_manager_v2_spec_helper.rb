# Copyright (c) 2009-2013 VMware, Inc.
require 'helper/spec_helper'

module VCAP::Services
  module CatalogManagerV2Helper
    def load_config
      config = {
        :cloud_controller_uri => 'api.vcap.me',
        :service_auth_tokens => {
          :test_core => 'token',
        },
        :token => 'token',
        :gateway_name => 'test_gw',
        :logger => make_logger,
        :uaa_endpoint => 'http://uaa.vcap.me',
        :uaa_client_id => 'vmc',
        :uaa_client_auth_credentials => {
          :username => 'test',
          :password=> 'test',
        },
      }
    end

    def make_logger(level=Logger::INFO)
      logger =  Logger.new STDOUT
      logger.level = level
      logger
    end
  end
end

