# Copyright (c) 2009-2011 VMware, Inc.
require 'base_async_gateway'

$:.unshift(File.dirname(__FILE__))

# A simple service gateway that proxies requests onto an asynchronous service provisioners.
# NB: Do not use this with synchronous provisioners, it will produce unexpected results.
#
# TODO(mjp): This needs to handle unknown routes
class VCAP::Services::AsynchronousServiceGateway < VCAP::Services::BaseAsynchronousServiceGateway

  REQ_OPTS = %w(service token provisioner cloud_controller_uri).map {|o| o.to_sym}
  attr_reader :event_machine

  def initialize(opts)
    super(opts)
  end

  # setup the environment
  def setup(opts)
    missing_opts = REQ_OPTS.select {|o| !opts.has_key? o}
    raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?
    @service      = opts[:service]
    @token        = opts[:token]
    @logger       = opts[:logger] || make_logger()
    @cld_ctrl_uri = http_uri(opts[:cloud_controller_uri])
    @provisioner  = opts[:provisioner]
    @hb_interval  = opts[:heartbeat_interval] || 60
    @node_timeout = opts[:node_timeout]
    @handle_fetch_interval = opts[:handle_fetch_interval] || 1
    @check_orphan_interval = opts[:check_orphan_interval] || -1
    @double_check_orphan_interval = opts[:double_check_orphan_interval] || 300
    @handle_fetched = opts[:handle_fetched] || false
    @fetching_handles = false
    @version_aliases = @service[:version_aliases] || {}

    opts[:gateway_name] ||= "Service Gateway"

    @cc_api_version = opts[:cc_api_version] || "v1"
    if @cc_api_version == "v1"
      require 'catalog_manager_v1'
      @catalog_manager = VCAP::Services::CatalogManagerV1.new(opts)
    elsif @cc_api_version == "v2"
      require 'catalog_manager_v2'
      @catalog_manager = VCAP::Services::CatalogManagerV2.new(opts)
    else
      raise "Unknown cc_api_version: #{@cc_api_version}"
    end

    @event_machine = opts[:event_machine] || EM

    # Setup heartbeats and exit handlers
    event_machine.add_periodic_timer(@hb_interval) { send_heartbeat }
    event_machine.next_tick { send_heartbeat }
    Kernel.at_exit do
      if event_machine.reactor_running?
        # :/ We can't stop others from killing the event-loop here. Let's hope that they play nice
        send_deactivation_notice(false)
      else
        event_machine.run { send_deactivation_notice }
      end
    end

    # Add any necessary handles we don't know about
    update_callback = Proc.new do |resp|
      @provisioner.update_handles(resp.handles)
      @handle_fetched = true
      event_machine.cancel_timer(@fetch_handle_timer)

      # TODO remove it when we finish the migration
      current_version = @version_aliases && @version_aliases[:current]
      if current_version
        @provisioner.update_version_info(current_version)
      else
        @logger.info("No current version alias is supplied, skip update version in CCDB.")
      end
    end

    @fetch_handle_timer = event_machine.add_periodic_timer(@handle_fetch_interval) { fetch_handles(&update_callback) }
    event_machine.next_tick { fetch_handles(&update_callback) }

    if @check_orphan_interval > 0
      handler_check_orphan = Proc.new do |resp|
        check_orphan(resp.handles,
                     lambda { @logger.info("Check orphan is requested") },
                     lambda { |errmsg| @logger.error("Error on requesting to check orphan #{errmsg}") })
      end
      event_machine.add_periodic_timer(@check_orphan_interval) { fetch_handles(&handler_check_orphan) }
    end

    # Register update handle callback
    @provisioner.register_update_handle_callback{|handle, &blk| update_service_handle(handle, &blk)}
  end

  def get_current_catalog
    id, _, version = @service[:label].rpartition('-')
    version = @service[:version_aliases][:current] if @service[:version_aliases][:current]
    provider = @service[:provider] || 'core'

    catalog_key = @catalog_manager.create_key(id, version, provider)

    unique_id = @service[:unique_id] ? {"unique_id" => @service[:unique_id]} : {}
    catalog = {}
    catalog[catalog_key] = {
      "id" => id,
      "version" => version,
      "label" => @service[:label],
      "url" => @service[:url],
      "plans" => @service[:plans],
      "cf_plan_id" => @service[:cf_plan_id],
      "tags" => @service[:tags],
      "active" => true,
      "description" => @service[:description],
      "plan_options" => @service[:plan_options],
      "acls" => @service[:acls],
      "timeout" => @service[:timeout],
      "provider" => provider,
      "default_plan" => @service[:default_plan],
      "supported_versions" => @service[:supported_versions],
      "version_aliases" => @service[:version_aliases],
    }.merge(extra).merge(unique_id)

    return catalog
  end

  def extra
    if (@service.keys & [:logo_url, :blurb, :provider_name]).empty?
      {}
    else
      { "extra" => Yajl::Encoder.encode({
          "listing" => {
            "imageUrl" => @service[:logo_url],
            "blurb" => @service[:blurb]
          },
          "provider" => {
            "name" => @service[:provider_name]
          }
        })
      }
    end
  end

  def check_orphan(handles, callback, errback)
    @provisioner.check_orphan(handles) do |msg|
      if msg['success']
        callback.call
        event_machine.add_timer(@double_check_orphan_interval) { fetch_handles{ |rs| @provisioner.double_check_orphan(rs.handles) } }
      else
        errback.call(msg['response'])
      end
    end
  end

  # Validate the incoming request
  def validate_incoming_request
    unless request.media_type == Rack::Mime.mime_type('.json')
      error_msg = ServiceError.new(ServiceError::INVALID_CONTENT).to_hash
      @logger.error("Validation failure: #{error_msg.inspect}, request media type: #{request.media_type} is not json")
      abort_request(error_msg)
    end
    unless auth_token && (auth_token == @token)
      error_msg = ServiceError.new(ServiceError::NOT_AUTHORIZED).to_hash
      @logger.error("Validation failure: #{error_msg.inspect}, expected token: #{@token}, specified token: #{auth_token}")
      abort_request(error_msg)
    end
    unless @handle_fetched
      error_msg = ServiceError.new(ServiceError::SERVICE_UNAVAILABLE).to_hash
      @logger.error("Validation failure: #{error_msg.inspect}, handles not fetched")
      abort_request(error_msg)
    end
  end

  #################### Handlers ####################

  # Provisions an instance of the service
  #
  post '/gateway/v1/configurations' do
    req = VCAP::Services::Api::GatewayProvisionRequest.decode(request_body)
    @logger.debug("Provision request for label=#{req.label}, plan=#{req.plan}, version=#{req.version}")

    name, version = VCAP::Services::Api::Util.parse_label(req.label)
    version = req.version

    unless (name == @service[:name])
      error_msg = ServiceError.new(ServiceError::UNKNOWN_LABEL).to_hash
      abort_request(error_msg)
    end

    @provisioner.provision_service(req) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::GatewayHandleResponse.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Unprovisions a previously provisioned instance of the service
  #
  delete '/gateway/v1/configurations/:service_id' do
    @logger.debug("Unprovision request for service_id=#{params['service_id']}")

    @provisioner.unprovision_service(params['service_id']) do |msg|
      if msg['success']
        async_reply
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Binds a previously provisioned instance of the service to an application
  #
  post '/gateway/v1/configurations/:service_id/handles' do
    @logger.info("Binding request for service=#{params['service_id']}")

    req = VCAP::Services::Api::GatewayBindRequest.decode(request_body)
    @logger.debug("Binding options: #{req.binding_options.inspect}")

    @provisioner.bind_instance(req.service_id, req.binding_options) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::GatewayHandleResponse.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Unbinds a previously bound instance of the service
  #
  delete '/gateway/v1/configurations/:service_id/handles/:handle_id' do
    @logger.info("Unbind request for service_id={params['service_id']} handle_id=#{params['handle_id']}")

    req = VCAP::Services::Api::GatewayUnbindRequest.decode(request_body)

    @provisioner.unbind_instance(req.service_id, req.handle_id, req.binding_options) do |msg|
      if msg['success']
        async_reply
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  post "/gateway/v2/configurations/:service_id/snapshots" do
    service_id = params["service_id"]
    name = Yajl::Parser.parse(request_body).fetch('name')

    @provisioner.create_snapshot_v2(service_id, name) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::SnapshotV2.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # create a snapshot
  post "/gateway/v1/configurations/:service_id/snapshots" do
    service_id = params["service_id"]
    @provisioner.create_snapshot(service_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
      async_reply
    end
    async_mode
  end

  # Get snapshot details
  get "/gateway/v1/configurations/:service_id/snapshots/:snapshot_id" do
    service_id = params["service_id"]
    snapshot_id = params["snapshot_id"]
    @logger.info("Get snapshot_id=#{snapshot_id} request for service_id=#{service_id}")
    @provisioner.get_snapshot(service_id, snapshot_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Snapshot.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Update snapshot name
  post "/gateway/v1/configurations/:service_id/snapshots/:snapshot_id/name" do
    req = VCAP::Services::Api::UpdateSnapshotNameRequest.decode(request_body)
    service_id = params["service_id"]
    snapshot_id = params["snapshot_id"]
    @logger.info("Update name of snapshot=#{snapshot_id} for service_id=#{service_id} to '#{req.name}'")
    @provisioner.update_snapshot_name(service_id, snapshot_id, req.name) do |msg|
      if msg['success']
        async_reply
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Enumerate snapshot
  get "/gateway/v1/configurations/:service_id/snapshots" do
    service_id = params["service_id"]
    @logger.info("Enumerate snapshots request for service_id=#{service_id}")
    @provisioner.enumerate_snapshots(service_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::SnapshotList.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  get "/gateway/v2/configurations/:service_id/snapshots" do
    service_id = params["service_id"]
    @logger.info("Enumerate snapshots request for service_id=#{service_id}")
    @provisioner.enumerate_snapshots_v2(params["service_id"]) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::SnapshotListV2.new(:snapshots => msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Rollback to a snapshot
  put "/gateway/v1/configurations/:service_id/snapshots/:snapshot_id" do
    service_id = params["service_id"]
    snapshot_id = params["snapshot_id"]
    @logger.info("Rollback service_id=#{service_id} to snapshot_id=#{snapshot_id}")
    @provisioner.rollback_snapshot(service_id, snapshot_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Delete a snapshot
  delete "/gateway/v1/configurations/:service_id/snapshots/:snapshot_id" do
    service_id = params["service_id"]
    snapshot_id = params["snapshot_id"]
    @logger.info("Delete service_id=#{service_id} to snapshot_id=#{snapshot_id}")
    @provisioner.delete_snapshot(service_id, snapshot_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Create a serialized url for a service snapshot
  post "/gateway/v1/configurations/:service_id/serialized/url/snapshots/:snapshot_id" do
    service_id = params["service_id"]
    snapshot_id = params["snapshot_id"]
    @logger.info("Create serialized url for snapshot=#{snapshot_id} of service_id=#{service_id} ")
    @provisioner.create_serialized_url(service_id, snapshot_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Get serialized url for a service snapshot
  get "/gateway/v1/configurations/:service_id/serialized/url/snapshots/:snapshot_id" do
    service_id = params["service_id"]
    snapshot_id = params["snapshot_id"]
    @logger.info("Get serialized url for snapshot=#{snapshot_id} of service_id=#{service_id} ")
    @provisioner.get_serialized_url(service_id, snapshot_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::SerializedURL.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Import serialized data from url
  put "/gateway/v1/configurations/:service_id/serialized/url" do
    req = VCAP::Services::Api::SerializedURL.decode(request_body)
    service_id = params["service_id"]
    @logger.info("Import serialized data from url:#{req.url} for service_id=#{service_id}")
    @provisioner.import_from_url(service_id, req.url) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Get Job details
  get "/gateway/v1/configurations/:service_id/jobs/:job_id" do
    service_id = params["service_id"]
    job_id = params["job_id"]
    @logger.info("Get job=#{job_id} for service_id=#{service_id}")
    @provisioner.job_details(service_id, job_id) do |msg|
      if msg['success']
        async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Restore an instance of the service
  #
  post '/service/internal/v1/restore' do
    @logger.info("Restore service")

    req = Yajl::Parser.parse(request_body)
    # TODO add json format check

    @provisioner.restore_instance(req['instance_id'], req['backup_path']) do |msg|
      if msg['success']
        async_reply
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Recovery an instance if node is crashed.
  post '/service/internal/v1/recover' do
    @logger.info("Recover service request.")
    request = Yajl::Parser.parse(request_body)
    instance_id = request['instance_id']
    backup_path = request['backup_path']
    fetch_handles do |resp|
      @provisioner.recover(instance_id, backup_path, resp.handles) do |msg|
        if msg['success']
          async_reply
        else
          async_reply_error(msg['response'])
        end
      end
    end
    async_mode
  end

  post '/service/internal/v1/check_orphan' do
    @logger.info("Request to check orphan")
    fetch_handles do |resp|
      check_orphan(resp.handles,
                   lambda { async_reply },
                   lambda { |errmsg| async_reply_error(errmsg) })
    end
    async_mode
  end

  delete '/service/internal/v1/purge_orphan' do
    @logger.info("Purge orphan request")
    req = Yajl::Parser.parse(request_body)
    orphan_ins_hash = req["orphan_instances"]
    orphan_binding_hash = req["orphan_bindings"]
    @provisioner.purge_orphan(orphan_ins_hash,orphan_binding_hash) do |msg|
      if msg['success']
        async_reply
      else
        async_reply_error(msg['response'])
      end
    end
    async_mode
  end

  # Service migration API
  post "/service/internal/v1/migration/:node_id/:instance_id/:action" do
    @logger.info("Migration: #{params["action"]} instance #{params["instance_id"]} in #{params["node_id"]}")
    @provisioner.migrate_instance(params["node_id"], params["instance_id"], params["action"]) do |msg|
      if msg["success"]
        async_reply(msg["response"].to_json)
      else
        async_reply_error(msg["response"])
      end
    end
    async_mode
  end

  get "/service/internal/v1/migration/:node_id/instances" do
    @logger.info("Migration: get instance id list of node #{params["node_id"]}")
    @provisioner.get_instance_id_list(params["node_id"]) do |msg|
      if msg["success"]
        async_reply(msg["response"].to_json)
      else
        async_reply_error(msg["response"])
      end
    end
    async_mode
  end

  ###################### V2 handlers ########################




  #################### Helpers ####################

  helpers do

    # Fetches canonical state (handles) from the Cloud Controller
    def fetch_handles(&cb)
      f = Fiber.new do
        @catalog_manager.fetch_handles_from_cc(@service[:label], cb)
      end
      f.resume
    end

    # Update a service handle using REST
    def update_service_handle(handle, &cb)
      f = Fiber.new do
        @catalog_manager.update_handle_in_cc(
          @service[:label],
          handle,
          lambda {
            # Update local array in provisioner
            @provisioner.update_handles([handle])
            cb.call(true) if cb
          },
          lambda { cb.call(false) if cb }
        )
      end
      f.resume
    end

    # Lets the cloud controller know we're alive and where it can find us
    def send_heartbeat
      @catalog_manager.update_catalog(
        true,
        lambda { return get_current_catalog },
        nil
      )
    end

    # Lets the cloud controller know that we're going away
    def send_deactivation_notice(stop_event_loop=true)
      @catalog_manager.update_catalog(
        false,
        lambda { return get_current_catalog },
        lambda { event_machine.stop if stop_event_loop }
      )
    end

  end
end
