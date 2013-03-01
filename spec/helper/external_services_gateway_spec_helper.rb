require 'uuid'

require 'base/external_services_gateway/gateway'
require 'base/external_services_gateway/test/test_gateway'

module VCAP
  module Services
    module ExternalServices
      class Gateway < VCAP::Services::BaseAsynchronousServiceGateway

        # Helpers for unit testing
        get "/" do
          return {"marketplace" => @ext_service_gw_client.name, "offerings" => @ext_service_gw_client.get_catalog}.to_json
        end

        post "/marketplace/set/:key/:value" do
          @logger.info("TEST HELPER ENDPOINT - set: key=#{params[:key]}, value=#{params[:value]}")
          Fiber.new {
            begin
              @ext_service_gw_client.set_config(params[:key], params[:value])
              refresh_catalog_and_update_cc(true)
              async_reply("")
            rescue => e
              reply_error(e.inspect)
            end
          }.resume
          async_mode
        end
      end
    end
  end
end


class ExternalServicesGatewayHelper
  CC_PORT = 34567

  GW_PORT = 15000
  GW_COMPONENT_PORT = 10000
  LOCALHOST = "127.0.0.1"

  def initialize
    @override_config = {}
  end

  def set(key, value)
    @override_config[key] = value
  end

  def make_logger
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG
    logger
  end

  def get_config
    config = {}
    config[:cloud_controller_uri] = "#{LOCALHOST}:#{CC_PORT}"
    config[:mbus] = "nats://nats:nats@#{VCAP.local_ip}:4222"
    config[:host] = LOCALHOST
    config[:port] = GW_PORT
    config[:url] = "http://#{LOCALHOST}:#{GW_PORT}"
    config[:component_port] = GW_COMPONENT_PORT
    config[:user] = "u"
    config[:password] = "p"
    config[:node_timeout] = 1
    config[:cc_api_version] = "v1"
    config[:ip_route] = "localhost"
    config[:index] = 0
    config[:logging] = { :level => "debug" }
    config[:logger] = make_logger
    config[:pid] = "/var/vcap/sys/run/ext_svc_gw.pid"

    config[:acls] = { :wildcards => ["*@example.com"], :users => [] }

    config[:external_uri] = "http://test-esgw.vcap.me"
    config[:refresh_interval] = 120
    config[:token] = "testservicetoken"
    config[:service_auth_tokens] = {
      :testservice_TestProvider => "testservicetoken",
      :fooservice_FooProvider   => "fooservicetoken"
    }

    config[:external_service_gateway_lib_path] = File.join(File.dirname(__FILE__), "..", "..", "lib", "base", "external_services_gateway", "test")
    config[:classname] = "VCAP::Services::ExternalServicesGateway::Test"
    config[:node_timeout] = 2

    @override_config.each { |k, v| config[k.to_sym] = v }

    config
  end

  def create_ext_svc_gw
    gw = Gateway.new(get_config)
    gw.start
    gw
  end

  def create_cc
    cc = MockCloudController.new
    cc.start
    cc
  end

  def create_ccng
    cc = MockCloudControllerNG.new
    cc.start
    cc
  end

  def create_client()
    config = get_config
    Client.new(config)
  end

  #########
  # Mock CC
  #########

  class MockCloudController
    def initialize
      @server = Thin::Server.new("#{LOCALHOST}", CC_PORT, Handler.new)
    end

    def start
      Thread.new { @server.start }
      while !@server.running?
        sleep 0.1
      end
    end

    def stop
      @server.stop if @server
    end

    class Handler < Sinatra::Base

      set :show_exceptions, false

      def initialize()
        @offerings = {}
      end

      post "/services/v1/offerings" do
        svc = JSON.parse(request.body.read)
        @offerings[svc["label"]] = svc
        puts "\n*#*#*#*#* Registered #{svc["active"] == true ? "*ACTIVE*" : "*INACTIVE*"} offering: #{svc["label"]}\n\n"
        "{}"
      end

      get "/proxied_services/v1/offerings" do
        puts "*#*#*#*#* CC::GET(/proxied_services/v1/offerings): #{request.body.read}"
        Yajl::Encoder.encode({
          :proxied_services => @offerings.values
        })
      end
    end
  end

  ###########
  # Mock CCNG
  ###########

  class MockCloudControllerNG
    def initialize
      @server = Thin::Server.new("#{LOCALHOST}", CC_PORT, Handler.new)
    end

    def start
      Thread.new { @server.start }
      while !@server.running?
        sleep 0.1
      end
      puts "CCNG: READY to accept requests..."
    end

    def stop
      @server.stop if @server
    end

    class Handler < Sinatra::Base

      set :show_exceptions, false
      set :reload_templates, false

      def initialize()
        @offerings = {}
        @offering_plans = {}
      end

      post "/v2/services" do
        svc_uuid = UUIDTools::UUID.random_create.to_s
        offering = {
          "metadata" => { "guid" => svc_uuid, "url" => "/v2/services/#{svc_uuid}", "created_at" => Time.now.to_s, "updated_at" => nil },
          "entity" => JSON.parse(request.body.read)
        }
        offering["entity"]["service_plans_url"] = "/v2/services/#{svc_uuid}/service_plans"
        @offerings[svc_uuid] = offering

        puts "\n*#*#*#*#* CCNG::Registered #{offering["entity"]["active"] == true ? "*ACTIVE*" : "*INACTIVE*"} offering: #{offering.inspect}\n\n"
        Yajl::Encoder.encode(offering)
      end

      post "/v2/service_plans" do
        svc_plan_uuid = UUIDTools::UUID.random_create.to_s
        svc_plan = {
          "metadata" => { "guid" => svc_plan_uuid, "url" => "/v2/service_plans/#{svc_plan_uuid}", "created_at" => Time.now.to_s, "updated_at" => nil },
          "entity" => JSON.parse(request.body.read)
        }
        svc_plan["entity"]["service_instance_guids"] = []
        svc_plan["entity"]["service_instances_url"] = "/v2/service_plans/#{svc_plan_uuid}/service_instance"
        svc_plan["entity"]["service_url"] = "/v2/services/#{svc_plan["entity"]["service_guid"]}"

        puts "\n*#*#*#*#* CCNG::Registered Plan: #{svc_plan.inspect}\n\n"

        svc_uuid = svc_plan["entity"]["service_guid"]

        @offerings[svc_uuid]["entity"]["service_plans"] ||= []
        @offerings[svc_uuid]["entity"]["service_plans"] << svc_plan

        @offering_plans[svc_plan_uuid] = svc_plan

        Yajl::Encoder.encode(svc_plan)
      end

      get "/v2/services" do
        puts "*#*#*#*#* CCNG::GET(/v2/services):"
        Yajl::Encoder.encode({
          "total_results" => @offerings.size,
          "total_pages"   => 1,
          "prev_url"      => nil,
          "next_url"      => nil,
          "resources"     => @offerings.values
        })
      end

      get "/v2/services/:service_guid/service_plans" do
        puts "*#*#*#*#* CCNG::GET service plans for service: #{params[:service_guid]}:"
        entries = @offerings[params[:service_guid]]["entity"]["service_plans"]

        Yajl::Encoder.encode({
          "total_results" => entries.size,
          "total_pages"   => 1,
          "prev_url"      => nil,
          "next_url"      => nil,
          "resources"     => entries
        })
      end
    end
  end

  ###################################
  # External Services gateway wrapper
  ###################################
  class Gateway

    def initialize(cfg)
      @config = cfg
      @mpgw = VCAP::Services::ExternalServices::Gateway.new(@config)
      @server = Thin::Server.new(@config[:host], @config[:port], @mpgw)
    end

    def start
      Thread.new { @server.start }
    end

    def stop
      @server.stop
    end
  end

  ############################################
  # Client wrapper for making gateway requests
  ############################################
  class Client

    attr_accessor :last_http_code, :last_response

    def initialize(opts)
      @gw_host = opts[:host]
      @gw_port = opts[:port]
      @component_port = opts[:component_port]
      @credentials = [ opts[:user], opts[:password] ]

      @token   = opts[:token]
      @cc_head = {
        'Content-Type' => 'application/json',
        'X-VCAP-Service-Token' => @token,
      }
      @base_url = "http://#{@gw_host}:#{@gw_port}"
      @component_base_url = "http://#{@gw_host}:#{@component_port}"
    end

    def set_token(tok)
      old_token = @token
      @token = tok
      @cc_head['X-VCAP-Service-Token'] = @token
      old_token
    end

    def gen_req(body = nil)
      req = {}
      req[:head] = @cc_head
      req[:body] = body if body
      req
    end

    def set_last_result(http)
      puts "Received response: #{http.response_header.status}  - #{http.response.inspect}"
      @last_http_code = http.response_header.status
      @last_response = http.response
    end

    def get_varz
      http = EM::HttpRequest.new("#{@component_base_url}/varz").get :head => {'authorization' => @credentials}
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def get_healthz
      http = EM::HttpRequest.new("#{@component_base_url}/healthz").get :head => {'authorization' => @credentials}
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def send_get_request(url, body = nil)
      puts "Sending request to: #{@base_url}#{url}"
      http = EM::HttpRequest.new("#{@base_url}#{url}").get(gen_req(body))
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def set_config(key, value)
      url = "#{@base_url}/marketplace/set/#{key}/#{value}"
      puts "Sending request to: #{url}"
      http = EM::HttpRequest.new("#{url}").post(gen_req)
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def send_provision_request(label, name, email, plan, version)
      msg = VCAP::Services::Api::GatewayProvisionRequest.new(
        :label => label,
        :name =>  name,
        :email => email,
        :plan =>  plan,
        :version => version
      ).encode
      http = EM::HttpRequest.new("http://#{@gw_host}:#{@gw_port}/gateway/v1/configurations").post(gen_req(msg))
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def send_unprovision_request(service_id)
      raise "Null service id" if service_id.nil?
      http = EM::HttpRequest.new("http://#{@gw_host}:#{@gw_port}/gateway/v1/configurations/#{service_id}").delete(gen_req)
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def send_bind_request(service_id, label, email, opts)
      raise "Null service id" if service_id.nil?
      msg = VCAP::Services::Api::GatewayBindRequest.new(
        :service_id => service_id,
        :label => label,
        :email => email,
        :binding_options => opts
      ).encode

      http = EM::HttpRequest.new("http://#{@gw_host}:#{@gw_port}/gateway/v1/configurations/#{service_id}/handles").post(gen_req(msg))
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end

    def send_unbind_request(service_id, bind_id)
      raise "Null service id" if service_id.nil?
      raise "Null bind id" if bind_id.nil?
      msg = Yajl::Encoder.encode({
        :service_id => service_id,
        :handle_id => bind_id,
        :binding_options => {}
      })
      http = EM::HttpRequest.new("http://#{@gw_host}:#{@gw_port}/gateway/v1/configurations/#{service_id}/handles/#{bind_id}").delete(gen_req(msg))
      http.callback { set_last_result(http) }
      http.errback { set_last_result(http) }
    end
  end
end
