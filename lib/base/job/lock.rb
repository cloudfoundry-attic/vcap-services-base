# Copyright (c) 2009-2011 VMware, Inc.
require "logger"
require "redis"

$LOAD_PATH.unshift File.dirname(__FILE__)
require "config"

# redis locking primitive using setnx.
# http://redis.io/commands/setnx
module VCAP::Services::Base::AsyncJob
  class Lock
    attr_reader :expiration, :timeout, :name
    include VCAP::Services::Base::Error

    # Options for lock
    # name       - The uuid of the lock
    # timeout    - The time that waits to acquire the lock, default 20 seconds
    # expiration - Lock expires in given seconds if not refreshed, default 10 seconds
    # logger     - The logger..
    # ttl        - The max time that a thread can acquire the lock, default 600 seconds. Lock raise +JOB_TIMEOUT+ error once the ttl is exceeded.
    def initialize(name, opts={})
      @name = name
      @timeout = opts[:timeout] || 20 #seconds
      @expiration = opts[:expiration] || 10  # seconds
      @ttl = opts[:ttl] || 600 # seconds
      @logger = opts[:logger] || make_logger
      config = Config.redis_config
      raise "Can't find configuration of redis." unless config
      @redis = ::Redis.new(config)
      @released_thread = {}
    end

    def make_logger
      logger = Logger.new(STDOUT)
      logger.level = Logger::ERROR
      logger
    end

    def lock
      @logger.debug("Acquiring lock: #{@name}")
      started = Time.now.to_f
      expiration = started.to_f + @expiration + 1
      until @redis.setnx(@name, expiration)
        existing_lock = @redis.get(@name)
        if existing_lock.to_f < Time.now.to_f
          @logger.debug("Lock #{@name} is expired, trying to acquire it.")
          break if watch_and_update(@redis, expiration)
        end

        raise ServiceError.new(ServiceError::JOB_QUEUE_TIMEOUT, @timeout)if Time.now.to_f - started > @timeout

        sleep(1)

        expiration = Time.now.to_f + @expiration + 1
      end

      @lock_expiration = expiration
      refresh_thread = setup_refresh_thread
      @logger.debug("Lock #{@name} is acquired, will expire at #{@lock_expiration}")

      begin
        Timeout::timeout(@ttl) do
          yield if block_given?
        end
      rescue Timeout::Error =>e
        raise ServiceError.new(ServiceError::JOB_TIMEOUT, @ttl)
      ensure
        release_thread(refresh_thread)
        delete
      end
    end

    def watch_and_update(redis, expiration)
      redis.watch(@name)
      res = redis.multi do
        redis.set(@name, expiration)
      end
      if res
        @logger.debug("Lock #{@name} is renewed and acquired.")
      else
        @logger.debug("Lock #{@name} was updated by others.")
      end
      res
    end

    def release_thread t
      # gracefully terminate refresh thread.
      @released_thread[t.object_id] = true
      waited = 0
      while (waited += 1) <= 5
        # thread is terminated when t.status == nil or false
        return unless t.status
        sleep 1
      end
      # force terminate after wait 5 seconds.
      t.exit
    end

    def released?
      @released_thread[Thread.current.object_id]
    end

    def setup_refresh_thread
      t = Thread.new do
        redis = ::Redis.new(Config.redis_config)
        sleep_interval = [1.0, @expiration/2].max.to_i
        begin
          while not released? do
            @logger.debug("Renewing lock #{@name}")
            redis.watch(@name)
            existing_lock = redis.get(@name)

            break if existing_lock.to_f > @lock_expiration # lock has been updated by others
            expiration = Time.now.to_f + @expiration + 1
            break unless watch_and_update(redis, expiration)
            @lock_expiration = expiration
            sleep_interval.times do
              sleep 1
              break if released?
            end
          end
        rescue => e
          @logger.error("Can't renew lock #{@name}, #{e}")
        ensure
          begin
            @logger.debug("Lock renew thread for #{@name} exited.")
            redis.quit
          rescue => e
            # just logging, ignore error
            @logger.debug("Ignore error when quit: #{e}")
          end
        end
      end
      t
    end

    def delete
      @logger.debug("Deleting lock: #{@name}")
      existing_lock = @redis.get(@name)
      @logger.debug("Lock #{@name} is acquired by others.")if existing_lock.to_f > @lock_expiration
      @redis.watch(@name)
      res = @redis.multi do
        @redis.del(@name)
      end
      if res
        @logger.debug("Lock #{@name} is deleted.")
      else
        @logger.debug("Lock #{@name} is acquired by others.")
      end
      true
    end
  end
end
