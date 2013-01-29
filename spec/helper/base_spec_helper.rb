require 'base/base'

class BaseTests

  module Options

    def self.nats_uri
      uri = "nats://localhost:4222"
      uri
    end

    LOGGER = Logger.new(STDOUT)
    NATS_URI = nats_uri
    IP_ROUTE = "127.0.0.1"
    NODE_TIMEOUT = 5
    PLAN = "free"
    CAPACITY = 200
    DATABASE_LOCK_FILE = "/tmp/LOCK"
    DISABLED_FILE = "/tmp/DISABLED"

    def self.default(more=nil)
      options = {
        :logger => LOGGER,
        :plan => PLAN,
        :capacity => CAPACITY,
        :ip_route => IP_ROUTE,
        :mbus => NATS_URI,
        :node_timeout => NODE_TIMEOUT,
        :database_lock_file => DATABASE_LOCK_FILE,
        :disabled_file => DISABLED_FILE,
      }
      more.each { |k,v| options[k] = v } if more
      options
    end
  end

  def self.create_base
    BaseTester.new(Options.default)
  end

  class BaseTester < VCAP::Services::Base::Base
    attr_accessor :node_mbus_connected
    attr_accessor :varz_invoked
    attr_accessor :healthz_invoked
    def initialize(options)
      @node_mbus_connected = false
      @varz_invoked = false
      @healthz_invoked = false
      super(options)
    end
    def flavor
      "flavor"
    end
    def service_name
      "service_name"
    end
    def on_connect_node
      @node_mbus_connected = true
    end
    def varz_details
      @varz_invoked = true
      {}
    end
    def healthz_details
      @healthz_invoked = true
      {}
    end
  end
end
