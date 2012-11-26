require "fileutils"
require "monitor"
require "datamapper"

# Export Monitor's count
class Monitor
  def count
    @mon_count
  end
end

module DataMapper

  class GlobalMutex
    def initialize(lockfile)
      @lockfile = lockfile
      @monitor = Monitor.new
    end

    def synchronize
      @monitor.synchronize do
        File.open(@lockfile, 'r') do |file|
          # Only Lock/Unlock on first entrance of synchronize to avoid
          # deadlock on flock
          file.flock(File::LOCK_EX) if @monitor.count == 1
          begin
            yield
          ensure
            file.flock(File::LOCK_UN) if @monitor.count == 1
          end
        end
      end
    end
  end

  class << self
    attr_reader :lock

    # extend DataMapper.setup parameters for a new :lock_file options
    # new setup can be called as following:
    # DataMapper.setup(<name>, <String>, :lock_file => file)
    # DataMapper.setup(<name>, <Addressable::URI>, :lock_file => file)
    # DataMapper.setup(<name>, <other_connection_options, :lock_file => file>)
    alias original_setup setup
    def setup(*args)
      unless @lock
        lock_file = args[1][:lock_file] if args.size == 2 && args[1].kind_of?(Hash)
        lock_file = args[2][:lock_file] if args.size == 3
        lock_file ||= '/var/vcap/sys/run/LOCK'
        initialize_lock_file(lock_file)
      end
      original_setup(*(args[0..1]))
    end

    def initialize_lock_file(lock_file)
      FileUtils.mkdir_p(File.dirname(lock_file))
      File.open(lock_file, 'w') do |file|
        file.truncate(0)
      end
      @lock = GlobalMutex.new(lock_file)
    end
  end

  # The following code will overwrite DataMapper's functions, and replace
  # them with a synchronized version of the same function.
  module Resource
    alias original_save save
    alias original_destroy destroy

    def save
      DataMapper.lock.synchronize do
        original_save
      end
    end

    def destroy
      DataMapper.lock.synchronize do
        original_destroy
      end
    end
  end

  module Model
    alias original_get get
    alias original_all all

    def get(*args)
      DataMapper.lock.synchronize do
        original_get(*args)
      end
    end

    def all(*args)
      DataMapper.lock.synchronize do
        original_all(*args)
      end
    end
  end

  class Collection
    alias original_each each
    alias original_at []
    alias original_get get
    alias original_empty? empty?

    def each(&block)
      instances = []
      DataMapper.lock.synchronize do
        original_each do |instance|
          instances << instance
        end
      end
      instances.each(&block)
    end

    def [](*args)
      DataMapper.lock.synchronize do
        original_at(*args)
      end
    end

    def get(*args)
      DataMapper.lock.synchronize do
        original_get(*args)
      end
    end

    def empty?()
      DataMapper.lock.synchronize do
        original_empty?()
      end
    end
  end

  # For auto_upgrade!
  module Migrations
    module SingletonMethods
      alias original_repository_execute repository_execute

      def repository_execute(*args)
        DataMapper.lock.synchronize do
          original_repository_execute(*args)
        end
      end
    end
  end

end
