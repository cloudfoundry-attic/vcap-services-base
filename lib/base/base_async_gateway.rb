# Copyright (c) 2009-2011 VMware, Inc.
# XXX(mjp)
require 'rubygems'

require 'eventmachine'
require 'em-http-request'
require 'json'
require 'sinatra/base'
require 'uri'
require 'thread'
require 'json_message'
require 'services/api'
require 'services/api/const'

$:.unshift(File.dirname(__FILE__))
require 'service_error'

module VCAP
  module Services
  end
end

# A simple service gateway that proxies requests onto an asynchronous service provisioners.
# NB: Do not use this with synchronous provisioners, it will produce unexpected results.
#
# TODO(mjp): This needs to handle unknown routes
class VCAP::Services::BaseAsynchronousServiceGateway < Sinatra::Base

  include VCAP::Services::Base::Error

  # Allow our exception handlers to take over
  set :raise_errors, Proc.new {false}
  set :show_exceptions, false

  def initialize(opts)
    super

    @logger = opts[:logger]

    setup(opts)
  end

  # Validate the incoming request
  before do
    validate_incoming_request

    content_type :json
  end

  # Handle errors that result from malformed requests
  error [JsonMessage::ValidationError, JsonMessage::ParseError] do
    error_msg = ServiceError.new(ServiceError::MALFORMATTED_REQ).to_hash
    abort_request(error_msg)
  end

  # setup the environment
  def setup(opts)
  end

  # Custom request validation
  def validate_incoming_request
  end

  #################### Helpers ####################

  helpers do

    # Aborts the request with the supplied errs
    #
    # +errs+  Hash of section => err
    def abort_request(error_msg)
      err_body = error_msg['msg'].to_json()
      halt(error_msg['status'], {'Content-Type' => Rack::Mime.mime_type('.json')}, err_body)
    end

    def auth_token
      @auth_token ||= request_header(VCAP::Services::Api::GATEWAY_TOKEN_HEADER)
      @auth_token
    end

    def request_body
      request.body.rewind
      request.body.read
    end

    def request_header(header)
      # This is pretty ghetto but Rack munges headers, so we need to munge them as well
      rack_hdr = "HTTP_" + header.upcase.gsub(/-/, '_')
      env[rack_hdr]
    end

    def async_mode(timeout=@node_timeout)
      request.env['__async_timer'] = EM.add_timer(timeout) do
        @logger.warn("Request timeout in #{timeout} seconds.")
        error_msg = ServiceError.new(ServiceError::SERVICE_UNAVAILABLE).to_hash
        err_body = error_msg['msg'].to_json()
        request.env['async.callback'].call(
          [
            error_msg['status'],
            {'Content-Type' => Rack::Mime.mime_type('.json')},
            err_body
          ]
        )
      end unless request.env['done'] ||= false
      throw :async
    end

    def async_reply(resp='{}')
      async_reply_raw(200, {'Content-Type' => Rack::Mime.mime_type('.json')}, resp)
    end

    def async_reply_raw(status, headers, body)
      @logger.debug("Reply status:#{status}, headers:#{headers}, body:#{body}")
      @provisioner.update_responses_metrics(status) if @provisioner
      request.env['done'] = true
      EM.cancel_timer(request.env['__async_timer']) if request.env['__async_timer']
      request.env['async.callback'].call([status, headers, body])
    end

    def async_reply_error(error_msg)
      err_body = error_msg['msg'].to_json()
      async_reply_raw(error_msg['status'], {'Content-Type' => Rack::Mime.mime_type('.json')}, err_body)
    end
  end

  private

  def add_proxy_opts(req)
    req[:proxy] = @proxy_opts
    # this is a workaround for em-http-requesr 0.3.0 so that headers are not lost
    # more info: https://github.com/igrigorik/em-http-request/issues/130
    req[:proxy][:head] = req[:head]
  end

  def create_http_request(args)
    req = {
      :head => args[:head],
      :body => args[:body],
    }

    if (@proxy_opts)
      add_proxy_opts(req)
    end

    req
  end

  def make_logger(level=Logger::INFO)
    logger = Logger.new(STDOUT)
    logger.level = level
    logger
  end

  def http_uri(uri)
    uri = "http://#{uri}" unless (uri.index('http://') == 0 || uri.index('https://') == 0)
    uri
  end
end
