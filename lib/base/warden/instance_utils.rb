# Copyright (c) 2009-2011 VMware, Inc.
require "warden/client"
require "warden/protocol"

$LOAD_PATH.unshift File.join("..", File.dirname(__FILE__))
require "base/utils"
require "base/abstract"
require "base/service_error"

module VCAP
  module Services
    module Base
      module Warden
      end
    end
  end
end

module VCAP::Services::Base::Warden::InstanceUtils

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def warden_connect
      warden_client = Warden::Client.new(warden_socket_path)
      warden_client.connect
      warden_client
    end

    def warden_socket_path
      "/tmp/warden.sock"
    end
  end

  # warden container operation helper
  def container_start(bind_mounts=[])
    warden = self.class.warden_connect
    req = Warden::Protocol::CreateRequest.new
    unless bind_mounts.empty?
      req.bind_mounts = bind_mounts
    end
    rsp = warden.call(req)
    handle = rsp.handle
    handle
  ensure
    warden.disconnect if warden
  end

  def container_stop(handle, force=true)
    warden = self.class.warden_connect
    req = Warden::Protocol::StopRequest.new
    req.handle = handle
    req.background = !force
    warden.call(req)
    true
  ensure
    warden.disconnect if warden
  end

  def container_destroy(handle)
    warden = self.class.warden_connect
    req = Warden::Protocol::DestroyRequest.new
    req.handle = handle
    warden.call(req)
    true
  ensure
    warden.disconnect if warden
  end

  def container_running?(handle)
    handle != "" && container_info(handle) != nil
  end

  def container_run_command(handle, cmd, is_privileged=false)
    warden = self.class.warden_connect
    req = Warden::Protocol::RunRequest.new
    req.handle = handle
    req.script = cmd
    req.privileged = is_privileged
    res = warden.call(req)
    if res.exit_status == 0
      res
    else
      raise VCAP::Services::Base::Error::ServiceError::new(VCAP::Services::Base::Error::ServiceError::WARDEN_RUN_COMMAND_FAILURE, cmd, handle, res.exit_status, res.stdout, res.stderr)
    end
  ensure
    warden.disconnect if warden
  end

  def container_spawn_command(handle, cmd, is_privileged=false)
    warden = self.class.warden_connect
    req = Warden::Protocol::SpawnRequest.new
    req.handle = handle
    req.script = cmd
    req.privileged = is_privileged
    res = warden.call(req)
    res
  ensure
    warden.disconnect if warden
  end

  def container_info(handle)
    warden = self.class.warden_connect
    req = Warden::Protocol::InfoRequest.new
    req.handle = handle
    warden.call(req)
  rescue => e
    nil
  ensure
    warden.disconnect if warden
  end

  def limit_memory(handle, limit)
    warden = self.class.warden_connect
    req = Warden::Protocol::LimitMemoryRequest.new
    req.handle = handle
    req.limit_in_bytes = limit * 1024 * 1024
    warden.call(req)
    true
  ensure
    warden.disconnect if warden
  end

  def limit_bandwidth(handle, rate)
    warden = self.class.warden_connect
    req = Warden::Protocol::LimitBandwidthRequest.new
    req.handle = handle
    req.rate = (rate * 1024 * 1024).to_i
    req.burst = (rate * 1 * 1024 * 1024).to_i # Set burst the same size as rate
    warden.call(req)
    true
  ensure
    warden.disconnect if warden
  end

  def map_port(handle, src_port, dest_port)
    warden = self.class.warden_connect
    req = Warden::Protocol::NetInRequest.new
    req.handle = handle
    req.host_port = src_port
    req.container_port = dest_port
    res = warden.call(req)
    res
  ensure
    warden.disconnect if warden
  end

  def bind_mount_request(bind_dir)
    bind = Warden::Protocol::CreateRequest::BindMount.new
    bind.src_path = bind_dir[:src]
    bind.dst_path = bind_dir[:dst] || bind_dir[:src]
    if bind_dir[:read_only]
      bind.mode = Warden::Protocol::CreateRequest::BindMount::Mode::RO
    else
      bind.mode = Warden::Protocol::CreateRequest::BindMount::Mode::RW
    end
    bind
  end
end
