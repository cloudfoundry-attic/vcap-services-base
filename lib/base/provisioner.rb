# -*- coding: utf-8 -*-
# Copyright (c) 2009-2011 VMware, Inc.
require "set"
require "datamapper"
require "uuidtools"

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'base/base'
require 'base/simple_aop'
require 'base/job/async_job'
require 'base/job/snapshot'
require 'base/job/serialization'
require 'barrier'
require 'service_message'

class VCAP::Services::Base::Provisioner < VCAP::Services::Base::Base
  include VCAP::Services::Internal
  include VCAP::Services::Base::AsyncJob
  include VCAP::Services::Base::AsyncJob::Snapshot
  include Before

  BARRIER_TIMEOUT = 2
  MASKED_PASSWORD = '********'

  def initialize(options)
    super(options)
    @opts = options
    @node_timeout = options[:node_timeout]
    @nodes     = {}
    @provision_refs = Hash.new(0)
    @prov_svcs = {}
    @instance_handles_CO = {}
    @binding_handles_CO = {}
    @plan_mgmt = options[:plan_management] && options[:plan_management][:plans] || {}

    init_service_extensions

    reset_orphan_stat

    z_interval = options[:z_interval] || 30

    EM.add_periodic_timer(z_interval) do
      update_varz
    end if @node_nats

    # Defer 5 seconds to give service a change to wake up
    EM.add_timer(5) do
      update_varz
    end if @node_nats

    EM.add_periodic_timer(60) { process_nodes }
  end

  def create_redis(opt)
    redis_client = ::Redis.new(opt)
    raise "Can't connect to redis:#{opt.inspect}" unless redis_client
    redis_client
  end

  def flavor
    'Provisioner'
  end

  def init_service_extensions
    @extensions = {}
    @plan_mgmt.each do |plan, value|
      lifecycle = value[:lifecycle]
      next unless lifecycle
      @extensions[plan] ||= {}
      @extensions[plan][:snapshot] = lifecycle.has_key? :snapshot
      %w(serialization job).each do |ext|
        ext = ext.to_sym
        @extensions[plan][ext] = true if lifecycle[ext] == "enable"
      end
    end
  end

  def reset_orphan_stat
    @staging_orphan_instances = {}
    @staging_orphan_bindings = {}
    @final_orphan_instances = {}
    @final_orphan_bindings = {}
  end

  # Updates our internal state to match that supplied by handles
  # +handles+  An array of config handles
  def update_handles(handles)
    @logger.info("[#{service_description}] Updating #{handles.size} handles")
    handles.each do |handle|
      unless verify_handle_format(handle)
        @logger.warn("Skip not well-formed handle:#{handle}.")
        next
      end

      h = handle.deep_dup
      @prov_svcs[h['service_id']] = {
        :configuration => h['configuration'],
        :credentials => h['credentials'],
        :service_id => h['service_id']
      }
    end
    @logger.info("[#{service_description}] Handles updated")
  end

  def verify_handle_format(handle)
    return nil unless handle
    return nil unless handle.is_a? Hash

    VCAP::Services::Internal::ServiceHandle.new(handle)
    true
  rescue => e
    @logger.warn("Verify handle #{handle} failed:#{e}")
    return nil
  end

  def find_all_bindings(name)
    res = []
    @prov_svcs.each do |k,v|
      res << v if v[:credentials]["name"] == name && v[:service_id] != name
    end
    res
  end

  def process_nodes
    @nodes.delete_if do |id, node|
      stale = (Time.now.to_i - node["time"]) > 300
      @provision_refs.delete(id) if stale
      stale
    end
  end

  def pre_send_announcement
    addition_opts = @opts[:additional_options]
    if addition_opts
      if addition_opts[:resque]
        # Initial AsyncJob module
        job_repo_setup()
        VCAP::Services::Base::AsyncJob::Snapshot.redis_connect
      end
    end
  end

  # update version information of existing instances
  def update_version_info(current_version)
    @logger.debug("[#{service_description}] Update version of existing instances to '#{current_version}'")

    updated_prov_handles = []
    @prov_svcs.each do |service_id, handle|
      next unless service_id == handle[:credentials]["name"]
      next if handle[:configuration].has_key? "version"

      updated_prov_handle = {}
      # update_handle_callback need string as key
      handle.each {|k, v| updated_prov_handle[k.to_s] = v.deep_dup}
      updated_prov_handle["configuration"]["version"] = current_version

      updated_prov_handles << updated_prov_handle
    end

    f = Fiber.new do
      failed, successful = 0, 0
      updated_prov_handles.each do |handle|
        @logger.debug("[#{service_description}] trying to update handle: #{handle}")
        # NOTE: serialized update_handle in case CC/router overload
        res = fiber_update_handle(handle)
        if res
          @logger.info("Successful update version of handle:#{handle}")
          successful += 1
        else
          @logger.error("Failed to update version of handle:#{handle}")
          failed += 1
        end
      end
      @logger.info("Result of update handle version: #{successful} successful, #{failed} failed.")
    end
    f.resume
  rescue => e
    @logger.error("Unexpected error when update version info: #{e}, #{e.backtrace.join("|")}")
  end

  def fiber_update_handle(updated_handle)
    f = Fiber.current

    @update_handle_callback.call(updated_handle) {|res| f.resume(res)}

    Fiber.yield
  end

  def on_connect_node
    @logger.debug("[#{service_description}] Connected to node mbus..")
    %w[announce node_handles handles update_service_handle].each do |op|
      eval %[@node_nats.subscribe("#{service_name}.#{op}") { |msg, reply| on_#{op}(msg, reply) }]
    end

    pre_send_announcement()
    @node_nats.publish("#{service_name}.discover")
  end

  def on_announce(msg, reply=nil)
    @logger.debug("[#{service_description}] Received node announcement: #{msg}")
    announce_message = Yajl::Parser.parse(msg)
    if announce_message["id"]
      id = announce_message["id"]
      announce_message["time"] = Time.now.to_i
      if @provision_refs[id] > 0
        announce_message['available_capacity'] = @nodes[id]['available_capacity']
      end
      @nodes[id] = announce_message
    end
  end

  # query all handles for a given instance
  def on_handles(instance, reply)
    @logger.debug("[#{service_description}] Receive query handles request for instance: #{instance}")
    if instance.empty?
      res = Yajl::Encoder.encode(@prov_svcs)
    else
      handles = find_all_bindings(instance)
      res = Yajl::Encoder.encode(handles)
    end
    @node_nats.publish(reply, res)
  end

  def on_node_handles(msg, reply)
    @logger.debug("[#{service_description}] Received node handles")
    response = NodeHandlesReport.decode(msg)
    nid = response.node_id
    @staging_orphan_instances[nid] ||= []
    @staging_orphan_bindings[nid] ||= []
    response.instances_list.each do |ins|
      @staging_orphan_instances[nid] << ins unless @instance_handles_CO.has_key?(ins)
    end
    response.bindings_list.each do |bind|
      user = bind["username"] || bind["user"]
      next unless user
      key = bind["name"].concat(user)
      @staging_orphan_bindings[nid] << bind unless @binding_handles_CO.has_key?(key)
    end
    oi_count = @staging_orphan_instances.values.reduce(0) { |m, v| m += v.count }
    ob_count = @staging_orphan_bindings.values.reduce(0) { |m, v| m += v.count }
    @logger.debug("Staging Orphans: Instances: #{oi_count}; Bindings: #{ob_count}")
  rescue => e
    @logger.warn("Exception at on_node_handles #{e}")
  end

  def indexing_handles(handles)
    # instance handles hash's key is service_id, value is handle
    # binding handles hash's key is credentials name & username, value is handle
    ins_handles = {}
    bin_handles = {}

    handles.each do |h|
      if h["service_id"] == h["credentials"]["name"]
        ins_handles[h["service_id"]] = h
      else
        user = h["credentials"]["username"] || h["credentials"]["user"]
        next unless user
        key = h["credentials"]["name"].concat(user)
        bin_handles[key] = h
      end
    end

    [ins_handles, bin_handles]
  end

  def check_orphan(handles, &blk)
    @logger.debug("[#{service_description}] Check if there are orphans")
    reset_orphan_stat
    @instance_handles_CO, @binding_handles_CO = indexing_handles(handles.deep_dup)
    @node_nats.publish("#{service_name}.check_orphan","Send Me Handles")
    blk.call(success)
  rescue => e
    @logger.warn("Exception at check_orphan #{e}")
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  def double_check_orphan(handles)
    @logger.debug("[#{service_description}] Double check the orphan result")
    ins_handles, bin_handles = indexing_handles(handles)
    @staging_orphan_instances.each do |nid, oi_list|
      @final_orphan_instances[nid] ||= []
      oi_list.each do |oi|
        @final_orphan_instances[nid] << oi unless ins_handles.has_key?(oi)
      end
    end
    @staging_orphan_bindings.each do |nid, ob_list|
      @final_orphan_bindings[nid] ||= []
      ob_list.each do |ob|
        user = ob["username"] || ob["user"]
        next unless user
        key = ob["name"].concat(user)
        @final_orphan_bindings[nid] << ob unless bin_handles.has_key?(key)
      end
    end
    oi_count = @final_orphan_instances.values.reduce(0) { |m, v| m += v.count }
    ob_count = @final_orphan_bindings.values.reduce(0) { |m, v| m += v.count }
    @logger.debug("Final Orphans: Instances: #{oi_count}; Bindings: #{ob_count}")
  rescue => e
    @logger.warn("Exception at double_check_orphan #{e}")
  end

  def purge_orphan(orphan_ins_hash,orphan_bind_hash, &blk)
    @logger.debug("[#{service_description}] Purge orphans for given list")
    handles_size = @max_nats_payload - 200

    send_purge_orphan_request = Proc.new do |node_id, i_list, b_list|
      group_handles_in_json(i_list, b_list, handles_size) do |ins_list, bind_list|
        @logger.debug("[#{service_description}] Purge orphans for #{node_id} instances: #{ins_list.count} bindings: #{bind_list.count}")
        req = PurgeOrphanRequest.new
        req.orphan_ins_list = ins_list
        req.orphan_binding_list = bind_list
        @node_nats.publish("#{service_name}.purge_orphan.#{node_id}", req.encode)
      end
    end

    orphan_ins_hash.each do |nid, oi_list|
      ob_list = orphan_bind_hash.delete(nid) || []
      send_purge_orphan_request.call(nid, oi_list, ob_list)
    end

    orphan_bind_hash.each do |nid, ob_list|
      send_purge_orphan_request.call(nid, [], ob_list)
    end
    blk.call(success)
  rescue => e
    @logger.warn("Exception at purge_orphan #{e}")
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  def unprovision_service(instance_id, &blk)
    @logger.debug("[#{service_description}] Unprovision service #{instance_id}")
    begin
      svc = @prov_svcs[instance_id]
      @logger.debug("[#{service_description}] Unprovision service #{instance_id} found instance: #{svc}")
      raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      bindings = find_all_bindings(instance_id)
      @logger.debug("[#{service_description}] Unprovisioning instance #{instance_id} from #{node_id}")
      request = UnprovisionRequest.new
      request.name = instance_id
      request.bindings = bindings.map{|h| h[:credentials]}
      @logger.debug("[#{service_description}] Sending request #{request}")
      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request(
          "#{service_name}.unprovision.#{node_id}", request.encode
       ) do |msg|
          # Delete local entries
          @prov_svcs.delete(instance_id)
          bindings.each do |b|
            @prov_svcs.delete(b[:service_id])
          end

          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = SimpleResponse.decode(msg)
          if opts.success
            blk.call(success())
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at unprovision_service #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def provision_service(request, prov_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to provision instance (request=#{request.extract})")
    subscription = nil
    plan = request.plan || "free"
    version = request.version

    plan_nodes = @nodes.select{ |_, node| node["plan"] == plan}.values

    @logger.debug("[#{service_description}] Picking version nodes from the following #{plan_nodes.count} \'#{plan}\' plan nodes: #{plan_nodes}")
    if plan_nodes.count > 0
      allow_over_provisioning = @plan_mgmt[plan.to_sym] && @plan_mgmt[plan.to_sym][:allow_over_provisioning] || false

      version_nodes = plan_nodes.select{ |node|
        node["supported_versions"] != nil && node["supported_versions"].include?(version)
      }
      @logger.debug("[#{service_description}] #{version_nodes.count} nodes allow provisioning for version: #{version}")

      if version_nodes.count > 0

        best_node = version_nodes.max_by { |node| node_score(node) }

        if best_node && ( allow_over_provisioning || node_score(best_node) > 0 )
          best_node = best_node["id"]
          @logger.debug("[#{service_description}] Provisioning on #{best_node}")

          prov_req = ProvisionRequest.new
          prov_req.plan = plan
          prov_req.version = version
          # use old credentials to provision a service if provided.
          prov_req.credentials = prov_handle["credentials"] if prov_handle

          @provision_refs[best_node] += 1
          @nodes[best_node]['available_capacity'] -= @nodes[best_node]['capacity_unit']
          subscription = nil

          timer = EM.add_timer(@node_timeout) {
            @provision_refs[best_node] -= 1
            @node_nats.unsubscribe(subscription)
            blk.call(timeout_fail)
          }

          subscription = @node_nats.request("#{service_name}.provision.#{best_node}", prov_req.encode) do |msg|
            @provision_refs[best_node] -= 1
            EM.cancel_timer(timer)
            @node_nats.unsubscribe(subscription)
            response = ProvisionResponse.decode(msg)

            if response.success
              @logger.debug("Successfully provision response:[#{response.inspect}]")

              # credentials is not necessary in cache
              prov_req.credentials = nil
              credential = response.credentials
              svc = {:configuration => prov_req.dup, :service_id => credential['name'], :credentials => credential}
              @logger.debug("Provisioned: #{svc.inspect}")
              @prov_svcs[svc[:service_id]] = svc
              blk.call(success(svc))
            else
              blk.call(wrap_error(response))
            end
          end
        else
          # No resources
          @logger.warn("[#{service_description}] Could not find a node to provision")
          blk.call(internal_fail)
        end
      else
        @logger.error("No available nodes supporting version #{version}")
        blk.call(failure(ServiceError.new(ServiceError::UNSUPPORTED_VERSION, version)))
      end
    else
      @logger.error("Unknown plan(#{plan})")
      blk.call(failure(ServiceError.new(ServiceError::UNKNOWN_PLAN, plan)))
    end
  rescue => e
    @logger.warn("Exception at provision_service #{e}")
    blk.call(internal_fail)
  end

  def bind_instance(instance_id, binding_options, bind_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to bind to service #{instance_id}")

    begin
      svc = @prov_svcs[instance_id]
      raise ServiceError.new(ServiceError::NOT_FOUND, instance_id) if svc.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      @logger.debug("[#{service_description}] bind instance #{instance_id} from #{node_id}")
      #FIXME options = {} currently, should parse it in future.
      request = BindRequest.new
      request.name = instance_id
      request.bind_opts = binding_options
      service_id = nil
      if bind_handle
        request.credentials = bind_handle["credentials"]
        service_id = bind_handle["service_id"]
      else
        service_id = UUIDTools::UUID.random_create.to_s
      end
      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request( "#{service_name}.bind.#{node_id}",
                           request.encode
       ) do |msg|
          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = BindResponse.decode(msg)
          if opts.success
            opts = opts.credentials
            # Save binding-options in :data section of configuration
            config = svc[:configuration].clone
            config['data'] ||= {}
            config['data']['binding_options'] = binding_options
            res = {
              :service_id => service_id,
              :configuration => config,
              :credentials => opts
            }
            @logger.debug("[#{service_description}] Binded: #{res.inspect}")
            @prov_svcs[res[:service_id]] = res
            blk.call(success(res))
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at bind_instance #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def unbind_instance(instance_id, handle_id, binding_options, &blk)
    @logger.debug("[#{service_description}] Attempting to unbind to service #{instance_id}")
    begin
      svc = @prov_svcs[instance_id]
      raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?

      handle = @prov_svcs[handle_id]
      raise ServiceError.new(ServiceError::NOT_FOUND, "handle_id #{handle_id}") if handle.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      @logger.debug("[#{service_description}] Unbind instance #{handle_id} from #{node_id}")
      request = UnbindRequest.new
      request.credentials = handle[:credentials]

      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request( "#{service_name}.unbind.#{node_id}",
                           request.encode
       ) do |msg|
          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = SimpleResponse.decode(msg)
          if opts.success
            @prov_svcs.delete(handle_id)
            blk.call(success())
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at unbind_instance #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def restore_instance(instance_id, backup_path, &blk)
    @logger.debug("[#{service_description}] Attempting to restore to service #{instance_id}")

    begin
      svc = @prov_svcs[instance_id]
      raise ServiceError.new(ServiceError::NOT_FOUND, instance_id) if svc.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      @logger.debug("[#{service_description}] restore instance #{instance_id} from #{node_id}")
      request = RestoreRequest.new
      request.instance_id = instance_id
      request.backup_path = backup_path
      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request( "#{service_name}.restore.#{node_id}",
          request.encode
       ) do |msg|
          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = SimpleResponse.decode(msg)
          if opts.success
            blk.call(success())
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at restore_instance #{e}")
        blk.call(internal_fail)
      end
    end
  end

  # Recover an instance
  # 1) Provision an instance use old credential
  # 2) restore instance use backup file
  # 3) re-bind bindings use old credential
  def recover(instance_id, backup_path, handles, &blk)
    @logger.debug("Recover instance: #{instance_id} from #{backup_path} with #{handles.size} handles.")
    prov_handle, binding_handles = find_instance_handles(instance_id, handles)
    @logger.debug("Provsion handle: #{prov_handle.inspect}. Binding_handles: #{binding_handles.inspect}")
    req = prov_handle["configuration"]
    request = VCAP::Services::Api::GatewayProvisionRequest.new
    request.label = "SERVICENAME-#{req["version"]}" # TODO: TEMPORARY CHANGE UNTIL WE UPDATE vcap_common gem git ref
    request.plan = req["plan"]
    request.version = req["version"]
    provision_service(request, prov_handle) do |msg|
      if msg['success']
        updated_prov_handle = msg['response']
        updated_prov_handle = hash_sym_key_to_str(updated_prov_handle)
        @logger.info("Recover: Success re-provision instance. Updated handle:#{updated_prov_handle}")
        @update_handle_callback.call(updated_prov_handle) do |update_res|
          if not update_res
            @logger.error("Recover: Update provision handle failed.")
            blk.call(internal_fail)
          else
            @logger.info("Recover: Update provision handle success.")
            restore_instance(instance_id, backup_path) do |res|
              if res['success']
                @logger.info("Recover: Success restore instance data.")
                barrier = VCAP::Services::Base::Barrier.new(:timeout => BARRIER_TIMEOUT, :callbacks => binding_handles.length) do |responses|
                  @logger.debug("Response from barrier: #{responses}.")
                  updated_handles = responses.select{|i| i[0] }
                  if updated_handles.length != binding_handles.length
                    @logger.error("Recover: re-bind or update handle failed. Expect #{binding_handles.length} successful responses, got #{updated_handles.length} ")
                    blk.call(internal_fail)
                  else
                    @logger.info("Recover: recover instance #{instance_id} complete!")
                    result = {
                      'success' => true,
                      'response' => "{}"
                    }
                    blk.call(result)
                  end
                end
                @logger.info("Recover: begin rebind binding handles.")
                bcb = barrier.callback
                binding_handles.each do |handle|
                  bind_instance(instance_id, nil, handle) do |bind_res|
                    if bind_res['success']
                      updated_bind_handle = bind_res['response']
                      updated_bind_handle = hash_sym_key_to_str(updated_bind_handle)
                      @logger.info("Recover: success re-bind binding: #{updated_bind_handle}")
                      @update_handle_callback.call(updated_bind_handle) do |update_res|
                        if update_res
                          @logger.error("Recover: success to update handle: #{updated_prov_handle}")
                          bcb.call(updated_bind_handle)
                        else
                          @logger.error("Recover: failed to update handle: #{updated_prov_handle}")
                          bcb.call(false)
                        end
                      end
                    else
                      @logger.error("Recover: failed to re-bind binding handle: #{handle}")
                      bcb.call(false)
                    end
                  end
                end
              else
                @logger.error("Recover: failed to restore instance: #{instance_id}.")
                blk.call(internal_fail)
              end
            end
          end
        end
      else
        @logger.error("Recover: failed to re-provision instance. Handle: #{prov_handle}.")
        blk.call(internal_fail)
      end
    end
  rescue => e
    @logger.warn("Exception at recover #{e}")
    blk.call(internal_fail)
  end

  def migrate_instance(node_id, instance_id, action, &blk)
    @logger.debug("[#{service_description}] Attempting to #{action} instance #{instance_id} in node #{node_id}")

    begin
      svc = @prov_svcs[instance_id]
      raise ServiceError.new(ServiceError::NOT_FOUND, instance_id) if svc.nil?

      binding_handles = []
      @prov_svcs.each do |_, handle|
        if handle[:service_id] != instance_id
          binding_handles << handle if handle[:credentials]["name"] == instance_id
        end
      end
      subscription = nil
      message = nil
      channel = nil
      if action == "disable" || action == "enable" || action == "import" || action == "update" || action == "cleanupnfs"
        channel = "#{service_name}.#{action}_instance.#{node_id}"
        message = Yajl::Encoder.encode([svc, binding_handles])
      elsif action == "unprovision"
        channel = "#{service_name}.unprovision.#{node_id}"
        bindings = find_all_bindings(instance_id)
        request = UnprovisionRequest.new
        request.name = instance_id
        request.bindings = bindings
        message = request.encode
      elsif action == "check"
        if node_id == svc[:credentials]["node_id"]
          blk.call(success())
          return
        else
          raise ServiceError.new(ServiceError::NOT_FOUND, instance_id)
        end
      else
        raise ServiceError.new(ServiceError::NOT_FOUND, action)
      end
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription = @node_nats.request(channel, message) do |msg|
        EM.cancel_timer(timer)
        @node_nats.unsubscribe(subscription)
        if action != "update"
          response = SimpleResponse.decode(msg)
          if response.success
            blk.call(success())
          else
            blk.call(wrap_error(response))
          end
        else
          handles = Yajl::Parser.parse(msg)
          handles.each do |handle|
            @update_handle_callback.call(handle) do |update_res|
              if update_res
                @logger.info("Migration: success to update handle: #{handle}")
              else
                @logger.error("Migration: failed to update handle: #{handle}")
                blk.call(wrap_error(response))
              end
            end
            blk.call(success())
          end
        end
      end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at migrate_instance #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def get_instance_id_list(node_id, &blk)
    @logger.debug("Get instance id list for migration")

    id_list = []
    @prov_svcs.each do |k, v|
      id_list << k if (k == v[:credentials]["name"] && node_id == v[:credentials]["node_id"])
    end
    blk.call(success(id_list))
  end

  # Snapshot apis filter
  def before_snapshot_apis service_id, *args, &blk
    raise "service_id can't be nil" unless service_id

    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc

    plan = find_service_plan(svc)
    extensions_enabled?(plan, :snapshot, &blk)
  rescue => e
    handle_error(e, &blk)
    nil # terminate evoke chain
  end

  def find_service_plan(svc)
    config = svc[:configuration] || svc["configuration"]
    raise "Can't find configuration for service=#{service_id} #{svc.inspect}" unless config
    plan = config["plan"] || config[:plan]
    raise "Can't find plan for service=#{service_id} #{svc.inspect}" unless plan
    plan
  end

  # Serialization apis filter
  def before_serialization_apis service_id, *args, &blk
    raise "service_id can't be nil" unless service_id

    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc

    plan = find_service_plan(svc)
    extensions_enabled?(plan, :serialization, &blk)
  rescue => e
    handle_error(e, &blk)
    nil # terminate evoke chain
  end

  def before_job_apis service_id, *args, &blk
    raise "service_id can't be nil" unless service_id

    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc

    plan = find_service_plan(svc)
    extensions_enabled?(plan, :job, &blk)
  rescue => e
    handle_error(e, &blk)
    nil # terminate evoke chain
  end

  def extensions_enabled?(plan, extension, &blk)
    unless (@extensions[plan.to_sym] && @extensions[plan.to_sym][extension.to_sym])
      @logger.warn("Extension #{extension} is not enabled for plan #{plan}")
      blk.call(failure(ServiceError.new(ServiceError::EXTENSION_NOT_IMPL, extension)))
      nil
    else
      true
    end
  end

  # Create a create_snapshot job and return the job object.
  #
  def create_snapshot(service_id, &blk)
    @logger.debug("Create snapshot job for service_id=#{service_id}")
    job_id = create_snapshot_job.create(:service_id => service_id, :node_id =>find_node(service_id))
    job = get_job(job_id)
    @logger.info("CreateSnapshotJob created: #{job.inspect}")
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  # Get detail job information by job id.
  #
  def job_details(service_id, job_id, &blk)
    @logger.debug("Get job_id=#{job_id} for service_id=#{service_id}")
    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc
    job = get_job(job_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, job_id) unless job
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  # Get detail snapshot information
  #
  def get_snapshot(service_id, snapshot_id, &blk)
    @logger.debug("Get snapshot_id=#{snapshot_id} for service_id=#{service_id}")
    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc
    snapshot = snapshot_details(service_id, snapshot_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, snapshot_id) unless snapshot
    blk.call(success(filter_keys(snapshot)))
  rescue => e
    handle_error(e, &blk)
  end

  # Update the name of a snapshot
  def update_snapshot_name(service_id, snapshot_id, name, &blk)
    @logger.debug("Update name of snapshot=#{snapshot_id} for service_id=#{service_id} to '#{name}'")
    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc

    update_name(service_id, snapshot_id, name)
    blk.call(success())
  rescue => e
    handle_error(e, &blk)
  end

  # Get all snapshots related to an instance
  #
  def enumerate_snapshots(service_id, &blk)
    @logger.debug("Get snapshots for service_id=#{service_id}")
    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc
    snapshots = service_snapshots(service_id)
    res = snapshots.map{|s| filter_keys(s)}
    blk.call(success({:snapshots => res }))
  rescue => e
    handle_error(e, &blk)
  end

  def rollback_snapshot(service_id, snapshot_id, &blk)
    @logger.debug("Rollback snapshot=#{snapshot_id} for service_id=#{service_id}")
    svc = @prov_svcs[service_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc
    snapshot = snapshot_details(service_id, snapshot_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, snapshot_id) unless snapshot
    job_id = rollback_snapshot_job.create(:service_id => service_id, :snapshot_id => snapshot_id,
                  :node_id => find_node(service_id))
    job = get_job(job_id)
    @logger.info("RoallbackSnapshotJob created: #{job.inspect}")
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  def delete_snapshot(service_id, snapshot_id, &blk)
    @logger.debug("Delete snapshot=#{snapshot_id} for service_id=#{service_id}")
    snapshot = snapshot_details(service_id, snapshot_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, snapshot_id) unless snapshot
    job_id = delete_snapshot_job.create(:service_id => service_id, :snapshot_id => snapshot_id, :node_id => find_node(service_id))
    job = get_job(job_id)
    @logger.info("DeleteSnapshotJob created: #{job.inspect}")
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  def create_serialized_url(service_id, snapshot_id, &blk)
    @logger.debug("create serialized url for snapshot=#{snapshot_id} of service_id=#{service_id}")
    snapshot = snapshot_details(service_id, snapshot_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, snapshot_id) unless snapshot
    job_id = create_serialized_url_job.create(:service_id => service_id, :node_id => find_node(service_id), :snapshot_id => snapshot_id)
    job = get_job(job_id)
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  # Genereate the serialized URL of service snapshot.
  # Return NOTFOUND error if no download token is associate with service instance.
  def get_serialized_url(service_id, snapshot_id, &blk)
    @logger.debug("get serialized url for snapshot=#{snapshot_id} of service_id=#{service_id}")
    snapshot = snapshot_details(service_id, snapshot_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, snapshot_id) unless snapshot
    token = snapshot["token"]
    raise ServiceError.new(ServiceError::NOT_FOUND, "Download url for service_id=#{service_id}, snapshot=#{snapshot_id}") unless token

    url_template = @opts[:download_url_template]
    service = @opts[:service][:name]
    raise "Configuration error, can't find download_url_template" unless url_template
    raise "Configuration error, can't find service name." unless service
    url = url_template % {:service => service, :name => service_id, :snapshot_id => snapshot_id, :token => token}
    blk.call(success({:url => url}))
  rescue => e
    handle_error(e, &blk)
  end

  #
  def import_from_url(service_id, url, &blk)
    @logger.debug("import serialized data from url:#{url} for service_id=#{service_id}")
    job_id = import_from_url_job.create(:service_id => service_id, :url => url, :node_id => find_node(service_id))
    job = get_job(job_id)
    blk.call(success(job))
  rescue => e
    wrap_error(e, &blk)
  end

  # convert symbol key to string key
  def hash_sym_key_to_str(hash)
    new_hash = {}
    hash.each do |k, v|
      if v.is_a? Hash
        v = hash_sym_key_to_str(v)
      end
      if k.is_a? Symbol
        new_hash[k.to_s] = v
      else
        new_hash[k] = v
      end
    end
    return new_hash
  end

  def on_update_service_handle(msg, reply)
    @logger.debug("[#{service_description}] Update service handle #{msg.inspect}")
    handle = Yajl::Parser.parse(msg)
    @update_handle_callback.call(handle) do |response|
      response = Yajl::Encoder.encode(response)
      @node_nats.publish(reply, response)
    end
  end

  # Gateway invoke this function to register a block which provisioner could use to update a service handle
  def register_update_handle_callback(&blk)
    @logger.debug("Register update handle callback with #{blk}")
    @update_handle_callback = blk
  end

  def varz_details()
    # Service Provisioner subclasses may want to override this method
    # to provide service specific data beyond the following

    # Mask password from varz details
    svcs = @prov_svcs.deep_dup
    svcs.each do |k,v|
      v[:credentials]['pass'] &&= MASKED_PASSWORD
      v[:credentials]['password'] &&= MASKED_PASSWORD
    end

    orphan_instances = @final_orphan_instances.deep_dup
    orphan_bindings = @final_orphan_bindings.deep_dup
    orphan_bindings.each do |k, list|
      list.each do |v|
        v['pass'] &&= MASKED_PASSWORD
        v['password'] &&= MASKED_PASSWORD
      end
    end

    plan_mgmt = []
    @plan_mgmt.each do |plan, v|
      plan_nodes = @nodes.select { |_, node| node["plan"] == plan.to_s }.values
      score = plan_nodes.inject(0) { |sum, node| sum + node_score(node) }
      plan_mgmt << {
        :plan => plan,
        :score => score,
        :low_water => v[:low_water],
        :high_water => v[:high_water],
        :allow_over_provisioning => v[:allow_over_provisioning]?1:0
      }
    end

    varz = {
      :nodes => @nodes,
      :prov_svcs => svcs,
      :orphan_instances => orphan_instances,
      :orphan_bindings => orphan_bindings,
      :plans => plan_mgmt
    }
    return varz
  rescue => e
    @logger.warn("Exception at varz_details #{e}")
  end

  ########
  # Helpers
  ########

  # Find instance related handles in all handles
  def find_instance_handles(instance_id, handles)
    prov_handle = nil
    binding_handles = []
    handles.each do |h|
      if h['service_id'] == instance_id
        prov_handle = h
      else
        binding_handles << h if h['credentials']['name'] == instance_id
      end
    end
    return [prov_handle, binding_handles]
  end

  # wrap a service message to hash
  def wrap_error(service_msg)
    {
      'success' => false,
      'response' => service_msg.error
    }
  end

  # handle request exception
  def handle_error(e, &blk)
    @logger.error("[#{service_description}] Unexpected Error: #{e}:[#{e.backtrace.join(" | ")}]")
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  # Find which node the service instance is running on.
  def find_node(instance_id)
    svc = @prov_svcs[instance_id]
    raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?
    node_id = svc[:credentials]["node_id"]
    raise "Cannot find node_id for #{instance_id}" if node_id.nil?
    node_id
  end

  # node_score(node) -> number.  this base class provisions on the
  # "best" node (lowest load, most free capacity, etc). this method
  # should return a number; higher scores represent "better" nodes;
  # negative/zero scores mean that a node should be ignored
  def node_score(node)
    node['available_capacity'] if node
  end

  # Service Provisioner subclasses must implement the following
  # methods

  # service_name() --> string
  # (inhereted from VCAP::Services::Base::Base)
  #

  # various lifecycle jobs class
  abstract :create_snapshot_job, :rollback_snapshot_job, :delete_snapshot_job, :create_serialized_url_job, :import_from_url_job
  # register before filter
  before [:create_snapshot, :get_snapshot, :enumerate_snapshots, :delete_snapshot, :rollback_snapshot, :update_snapshot_name],  :before_snapshot_apis

  before [:create_serialized_url, :get_serialized_url, :import_from_url], :before_serialization_apis

  before :job_details, :before_job_apis

end
