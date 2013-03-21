require "resque-status"
require "fileutils"
require "vcap/logging"

require_relative "../service_error"
require_relative "snapshot_client"



module VCAP::Services::Base::SnapshotV2

  class MySqlSnapshotJob
    def self.queue_lookup_key
      'mysql'
    end
  end

  # common utils for snapshot job
  class SnapshotJob
    include Resque::Plugins::Status

    class QueueResolver
      extend Forwardable
      def_delegator :@job_class, :queue_lookup_key

      def initialize(job_class)
        @job_class = job_class
      end

      def resolve(*args)
        result = nil
        args.each do |arg|
          result = arg[queue_lookup_key] if (arg.is_a? Hash) && (arg.has_key?(queue_lookup_key))
        end
        raise "no queue matched for look up key #{queue_lookup_key} and args #{args}" unless result
        result
      end
    end

    class << self
      def queue_lookup_key
        :node_id
      end

      def select_queue(*args)
        QueueResolver.new(self).resolve(*args)
      end
    end

    def initialize(*args)
      super(*args)
      parse_config
      #client = SnapshotClient.new(Config.redis_config)
      # @logger = Config.logger
      # Snapshot.redis_connect
    end

    # def fmt_error(e)
      # "#{e}: [#{e.backtrace.join(" | ")}]"
    # end

    # def required_options(*args)
      # missing_opts = args.select{|arg| !options.has_key? arg.to_s}
      # raise ArgumentError, "Missing #{missing_opts.join(', ')} in options: #{options.inspect}" unless missing_opts.empty?
    # end

    # def create_lock(lock_name)
      # # lock_name = "lock:lifecycle:#{name}"
      # ttl = @config['job_ttl'] || 600
      # lock = Lock.new(lock_name, :logger => @logger, :ttl => ttl)
      # lock
    # end

    # def get_dump_path(name, snapshot_id)
      # snapshot_filepath(@config["snapshots_base_dir"], @config["service_name"], name, snapshot_id)
    # end

    # def cleanup(name, snapshot_id)
      # return unless name && snapshot_id
      # @logger.info("Clean up snapshot and files for #{name}, snapshot id: #{snapshot_id}")
      # client.delete_snapshot(name, snapshot_id)
      # FileUtils.rm_rf(get_dump_path(name, snapshot_id))
    # end

    # def handle_error(e)
      # @logger.error("Error in #{self.class} uuid:#{@uuid}: #{fmt_error(e)}")
      # err = (e.instance_of?(ServiceError)? e : ServiceError.new(ServiceError::INTERNAL_ERROR)).to_hash
      # err_msg = Yajl::Encoder.encode(err["msg"])
      # failed(err_msg)
    # end

    def parse_config
      @config = Yajl::Parser.parse(ENV['WORKER_CONFIG'])
      raise "Need environment variable: WORKER_CONFIG" unless @config
      @config
    end
  end
end
