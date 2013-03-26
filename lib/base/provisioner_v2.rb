# -*- coding: utf-8 -*-
# Copyright (c) 2009-2011 VMware, Inc.

$LOAD_PATH.unshift File.dirname(__FILE__)
require "base/provisioner"

module VCAP::Services::Base::ProvisionerV2

  attr_accessor :service_instances
  attr_accessor :service_bindings

  # Updates our internal handle state from external v2 handles, e.g., ccdb handles
  # @param array handles
  #    handles[0] contains all instance handles
  #    handles[1] contains all binding handles
  def update_handles(handles)
    if handles.size == 2
      @logger.info("[#{service_description}] Updating #{handles[0].size} instance handles and #{handles[1].size} binding handles in v2 api...")
      update_instance_handles(handles[0])
      update_binding_handles(handles[1])
      @logger.info("[#{service_description}] Handles updated")
    elsif handles.size == 1
      # this is for the internal update when doing version update and some other updates
      # and thus it would only be updating either binding or instance handle;
      # binding handle would have a field of gateway_name but instance handle would not;
      if handles[0].has_key?('gateway_name')
        internal_handle = { handles[0]['gateway_name'] => handles[0] }
        update_binding_handles(internal_handle)
      else
        internal_handle = { handles[0]['credentials']['name'] => handles[0] }
        update_instance_handles(internal_handle)
      end
    else
      raise "unknown handle type in update handles v2"
    end
  end

  def update_instance_handles(instance_handles)
    instance_handles.each do |instance_id, instance_handle|
      unless verify_instance_handle_format(instance_handle)
        @logger.warn("Skip not well-formed instance handle:#{instance_handle}.")
        next
      end

      handle = instance_handle.deep_dup
      @service_instances[instance_id] = {
        :credentials   => handle['credentials'],
        # NOTE on gateway we have have 'configuration' field in instance handle in replacement
        # of the 'gateway_data' field as in ccdb handle, this is for a easy management/translation
        # between gateway v1 and v2 provisioner code
        :configuration => handle['gateway_data'],
        :gateway_name  => handle['credentials']['name'],
      }
    end
  end

  def update_binding_handles(binding_handles)
    binding_handles.each do |binding_id, binding_handle|
      unless verify_binding_handle_format(binding_handle)
        @logger.warn("Skip not well-formed binding handle:#{binding_handle}.")
        next
      end

      handle = binding_handle.deep_dup
      @service_bindings[binding_id] = {
        :credentials   => handle['credentials'],
        # NOTE on gateway we have have 'configuration' field in binding handle in replacement
        # of the 'gateway_data' field as in ccdb, this is for a easy management/translation
        # between gateway v1 and v2 provisioner code
        :configuration => handle['gateway_data'],
        :gateway_name  => handle['gateway_name'],
      }
    end
  end

  def verify_instance_handle_format(handle)
    return nil unless handle
    return nil unless handle.is_a? Hash

    VCAP::Services::Internal::ServiceInstanceHandleV2.new(handle)
    true
  rescue => e
    @logger.warn("Verify v2 instance handle #{handle} failed:#{e}")
    return nil
  end

  def verify_binding_handle_format(handle)
    return nil unless handle
    return nil unless handle.is_a? Hash

    VCAP::Services::Internal::ServiceBindingHandleV2.new(handle)
    true
  rescue => e
    @logger.warn("Verify v2 binding handle #{handle} failed:#{e}")
    return nil
  end

  # indexing handles for (double) check orphan only
  # @param: array handles
  #         handles[0] contains an array of instance handles
  #         handles[1] contains an array of binding handles
  # returns: array of handles which contains two hashes for instance handles and binding handle.
  def indexing_handles(handles)
    instance_handles = {}
    binding_handles  = {}
    handles[0].each { |instance_id, _| instance_handles[instance_id] = nil }
    handles[1].each do |binding_id, binding_handle|
      user = binding_handle["credentials"]["username"] || binding_handle["credentials"]["user"]
      next unless user
      key = binding_handle["credentials"]["name"] + user
      binding_handles[key] = nil
    end
    [instance_handles, binding_handles]
  end

  def get_instance_id_list(node_id, &blk)
    @logger.debug("Get instance id list for migration")

    id_list = []
    @service_instances.each do |service_id, entity|
      id_list << service_id if node_id == entity[:credentials]["node_id"]
    end
    blk.call(success(id_list))
  end

  ########
  # Helpers
  ########

  def get_all_instance_handles
    instance_handles = @service_instances.deep_dup
    instance_handles.each {|instance_id, handle| yield handle if block_given?}
    instance_handles
  end

  def get_all_binding_handles
    binding_handles = @service_bindings.deep_dup
    binding_handles.each {|binding_id, handle| yield handle if block_given?}
    binding_handles
  end

  def get_instance_handle(instance_id)
    @service_instances[instance_id].deep_dup
  end

  def get_binding_handle(binding_id)
    @service_bindings[binding_id].deep_dup
  end

  def add_instance_handle(entity)
    # NOTE this handle contains a subset of the information of the handles in ccdb
    # the handle will possess the full information after the next fetch handle operation
    # on the gateway and update the corresponding handle; but these information is sufficient
    # for current operations
    @service_instances[entity[:service_id]] = {
      :credentials   => entity[:credentials],
      :configuration => entity[:configuration],
      :gateway_name  => entity[:service_id],
    }
  end

  def add_binding_handle(entity)
    # NOTE this handle contains a subset of the information of the handles in ccdb
    # the handle will possess the full information after the next fetch handle operation
    # on the gateway and update the corresponding handle; but these information is sufficient
    # for current operations
    @service_bindings[entity[:service_id]] = {
      :credentials   => entity[:credentials],
      :configuration => entity[:configuration],
      :gateway_name  => entity[:service_id],
    }
  end

  def delete_instance_handle(instance_handle)
    @service_instances.delete(instance_handle[:credentials]["name"])
  end

  def delete_binding_handle(binding_handle)
    @service_bindings.delete(binding_handle[:gateway_name])
  end

  def find_instance_bindings(instance_id)
    binding_handles = []
    @service_bindings.each do |_, handle|
      binding_handles << handle if handle[:credentials]["name"] == instance_id
    end
    binding_handles
  end

  def get_all_handles
    @service_instances.merge(@service_bindings).deep_dup
  end
end
