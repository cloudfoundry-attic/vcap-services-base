# Copyright (c) 2009-2011 VMware, Inc.
require 'eventmachine'
require 'vcap/common'
require 'vcap/component'
require 'nats/client'

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'abstract'
require 'service_error'

module VCAP
  module Services
    module Base
      class Base
      end
    end
  end
end

class Object
  def deep_dup
    Marshal::load(Marshal.dump(self))
  end
end

class VCAP::Services::Base::Base

  include VCAP::Services::Base::Error

  def initialize(options)
    @logger = options[:logger]
    @options = options
    @local_ip = VCAP.local_ip(options[:ip_route])
    @logger.info("#{service_description}: Initializing")

    @node_nats = nil
    if options[:mbus]

      NATS.on_error do |e|
        @logger.error("Exiting due to NATS error: #{e}")
        if $!.nil?
          exit
        else
          @logger.error("Exception in scope: #{$!}")
        end
      end
      @node_nats = NATS.connect(:uri => options[:mbus]) do
        status_port = status_user = status_password = nil
        if not options[:status].nil?
          status_port = options[:status][:port]
          status_user = options[:status][:user]
          status_password = options[:status][:password]
        end

        VCAP::Component.register(
          :nats => @node_nats,
          :type => service_description,
          :host => @local_ip,
          :index => options[:index] || 0,
          :config => options,
          :port => status_port,
          :user => status_user,
          :password => status_password
        )
        on_connect_node
      end
    else
      @logger.info("NATS is disabled")
    end

    @max_nats_payload = options[:max_nats_payload] || 1024 * 1024
  end

  def service_description()
    return "#{service_name}-#{flavor}"
  end

  def publish(reply, msg)
    # nats publish are only allowed to be called in reactor thread.
    EM.schedule do
      @node_nats.publish(reply, msg) if @node_nats
    end
  end

  def update_varz()
    vz = varz_details
    vz.each { |k,v|
      VCAP::Component.varz[k] = v
    }
  end

  def shutdown()
    @logger.info("#{service_description}: Shutting down")
    @node_nats.close if @node_nats
  end

  def group_handles_in_json(instances_list, bindings_list, size_limit)
    while instances_list.count > 0 or bindings_list.count > 0
      ins_list = []
      bind_list = []
      send_len = 0
      idx_ins = 0
      idx_bind = 0

      instances_list.each do |ins|
        len = ins.to_json.size + 1
        if send_len + len < size_limit
          send_len += len
          idx_ins += 1
          ins_list << ins
        else
          break
        end
      end
      instances_list.slice!(0, idx_ins) if idx_ins > 0

      bindings_list.each do |bind|
        len = bind.to_json.size + 1
        if send_len + len < size_limit
          send_len += len
          idx_bind += 1
          bind_list << bind
        else
          break
        end
      end
      bindings_list.slice!(0, idx_bind) if idx_bind > 0

      # Generally, the size_limit is far more bigger than the length
      # of any handles. If there's a huge handle or the size_limit is too
      # small that the size_limit can't contain one handle the in one batch,
      # we have to break the loop if no handle can be stuffed into batch.
      if ins_list.count == 0 and bind_list.count == 0
        @logger.warn("NATS message limit #{size_limit} is too small.")
        break
      else
        yield ins_list, bind_list
      end
    end
  end

  # Subclasses VCAP::Services::Base::{Node,Provisioner} implement the
  # following methods. (Note that actual service Provisioner or Node
  # implementations should NOT need to touch these!)

  # TODO on_connect_node should be on_connect_nats
  abstract :on_connect_node
  abstract :flavor # "Provisioner" or "Node"
  abstract :varz_details

  # Service Provisioner and Node classes must implement the following
  # method
  abstract :service_name

end
