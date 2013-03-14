require "redis"
require "time"
require_relative "../service_error"

module VCAP::Services::Base::SnapshotV2
  class SnapshotClient
    include VCAP::Services::Base::Error

    SNAPSHOT_KEY_PREFIX = "vcap:snapshotv2".freeze
    SNAPSHOT_ID = "maxid".freeze
    FILTER_KEYS = %w(snapshot_id date size name).freeze
    MAX_NAME_LENGTH = 512

    def initialize(redis_config)
      @redis = ::Redis.new(redis_config)
      # FIXME: use UUID?
      redis_init
    end

    def create_empty_snapshot(service_id, name)
      snapshot = {
        'state' => 'empty',
        'size'  => 0,
        'name'  => name,
        'snapshot_id' => new_snapshot_id,
      }
      msg = Yajl::Encoder.encode(snapshot)
      client.hset(redis_key(service_id), snapshot['snapshot_id'], msg)
      snapshot
    end

    # Get all snapshots related to a service instance
    #
    def service_snapshots(service_id)
      return unless service_id
      res = client.hgetall(redis_key(service_id))
      res.values.map{|v| Yajl::Parser.parse(v)}
    end

    # Return total snapshots count
    #
    def service_snapshots_count(service_id)
      return unless service_id
      client.hlen(redis_key(service_id))
    end

    # Get detail information for a single snapshot
    #
    def snapshot_details(service_id, snapshot_id)
      return unless service_id && snapshot_id
      res = client.hget(redis_key(service_id), snapshot_id)
      raise ServiceError.new(ServiceError::NOT_FOUND, "snapshot #{snapshot_id}") unless res
      Yajl::Parser.parse(res)
    end

    # filter internal keys of a given snapshot object, return a new snapshot object in canonical format
    def self.filter_keys(snapshot)
      return unless snapshot.is_a? Hash
      snapshot.select {|k,v| FILTER_KEYS.include? k.to_s}
    end

    # Generate a new unique id for a snapshot
    def new_snapshot_id
      client.incr(redis_key(SNAPSHOT_ID)).to_s
    end

    # Get the snapshot file path that service should save the dump file to.
    # the snapshot path structure looks like <base_dir>\snapshots\<service-name>\<aa>\<bb>\<cc>\<aabbcc-rest-of-instance-guid>\snapshot_id\<service specific data>
    def self.snapshot_filepath(base_dir, service_name, service_id, snapshot_id)
      File.join(base_dir, "snapshots", service_name, service_id[0,2], service_id[2,2], service_id[4,2], service_id, snapshot_id.to_s)
    end

    # Update the name of given snapshot.
    # This function is not protected by redis lock so a optimistic lock
    # is applied to prevent concurrent update.
    #
    def update_name(service_id, snapshot_id, name)
      return unless service_id && snapshot_id && name
      verify_input_name(name)

      key = self.class.redis_key(service_id)
      # NOTE: idealy should watch on combination of (service_id, snapshot_id)
      # but current design doesn't support such fine-grained watching.
      client.watch(key)

      snapshot = client.hget(redis_key(service_id), snapshot_id)
      return nil unless snapshot
      snapshot = Yajl::Parser.parse(snapshot)
      snapshot["name"] = name

      res = client.multi do
        save_snapshot(service_id, snapshot)
      end

      unless res
        raise ServiceError.new(ServiceError::REDIS_CONCURRENT_UPDATE)
      end
      true
    end

    def save_snapshot(service_id , snapshot)
      return unless service_id && snapshot
      # FIXME: srsly? where are we using symbols?
      sid = snapshot[:snapshot_id] || snapshot["snapshot_id"]
      return unless sid
      msg = Yajl::Encoder.encode(snapshot)
      client.hset(redis_key(service_id), sid, msg)
    end

    def delete_snapshot(service_id , snapshot_id)
      return unless service_id && snapshot_id
      client.hdel(redis_key(service_id), snapshot_id)
    end


    def self.fmt_time()
      # UTC time in ISO 8601 format.
      Time.now.utc.strftime("%FT%TZ")
    end

    def self.redis_key(key)
      "#{SNAPSHOT_KEY_PREFIX}:#{key}"
    end

    private
    def filter_keys(snapshot)
      self.class.filter_keys(snapshot)
    end

    def snapshot_filepath(base_dir, service_name, service_id, snapshot_id)
      self.class.snapshot_filepath(base_dir, service_name, service_id, snapshot_id)
    end

    def redis_key(key)
      self.class.redis_key(key)
    end

    attr_reader :redis

    # initialize necessary keys
    def redis_init
      @redis.setnx("#{SNAPSHOT_KEY_PREFIX}:#{SNAPSHOT_ID}", 1)
    end

    def client
      redis
    end

    def verify_input_name(name)
      return unless name

      raise ServiceError.new(ServiceError::INVALID_SNAPSHOT_NAME,
                             "Input name exceed the max allowed #{MAX_NAME_LENGTH} characters.") if name.size > MAX_NAME_LENGTH

      #TODO: shall we sanitize the input?
    end
  end
end
