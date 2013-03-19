# -*- coding: utf-8 -*-
# Copyright (c) 2009-2011 VMware, Inc.

$LOAD_PATH.unshift File.dirname(__FILE__)
require "base/provisioner"

module VCAP::Services::Base::ProvisionerV1

  attr_accessor :prov_svcs

  # Updates our internal handle state from external v1 handles, e.g., ccdb handles
  # @param hash handles
  def update_handles(handles)
    @logger.info("[#{service_description}] Updating #{handles.size} handles v1")
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
        key = h["credentials"]["name"] + user
        bin_handles[key] = h
      end
    end

    [ins_handles, bin_handles]
  end

  def get_instance_id_list(node_id, &blk)
    @logger.debug("Get instance id list for migration")

    id_list = []
    @prov_svcs.each do |k, v|
      id_list << k if (k == v[:credentials]["name"] && node_id == v[:credentials]["node_id"])
    end
    blk.call(success(id_list))
  end

  ########
  # Helpers
  ########

  def get_all_instance_handles
    instance_handles = @prov_svcs.select {|service_id, entity| service_id.to_s == entity[:credentials]["name"]}
    instance_handles.each {|service_id, handle| yield handle if block_given?}
    instance_handles
  end

  def get_all_binding_handles
    binding_handles = @prov_svcs.select {|service_id, entity| service_id.to_s != entity[:credentials]["name"]}
    binding_handles.each {|service_id, handle| yield handle if block_given?}
    binding_handles
  end

  def get_instance_handle(instance_id)
    @prov_svcs[instance_id].deep_dup
  end

  def get_binding_handle(binding_id)
    @prov_svcs[binding_id].deep_dup
  end

  def add_instance_handle(response)
    @prov_svcs[response[:service_id]] = response
  end

  def add_binding_handle(response)
    @prov_svcs[response[:service_id]] = response
  end

  def delete_instance_handle(instance_handle)
    @prov_svcs.delete(instance_handle[:service_id])
  end

  def delete_binding_handle(binding_handle)
    @prov_svcs.delete(binding_handle[:service_id])
  end

  def find_instance_bindings(instance_id)
    binding_handles = []
    @prov_svcs.each do |_, handle|
      if handle[:credentials]["name"] == instance_id
        binding_handles << handle if handle[:service_id] != instance_id
      end
    end
    binding_handles
  end

  def get_all_handles
    @prov_svcs.deep_dup
  end
end
