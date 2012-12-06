require "open3"

module VCAP::Services::Base::Utils

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def sh(*args)
      options = args[-1].respond_to?(:to_hash) ? args.pop.to_hash: {}
      options = { :timeout => 5.0, :max => 1024 * 1024, :sudo => true, :block => true }.merge(options)
      arg = options[:sudo] == false ? args[0] : "sudo " << args[0]

      begin
        stdin, stdout, stderr, status = Open3.popen3(arg)
        pid = status[:pid]
        out_buf = ""
        err_buf = ""
        if options[:block]
          start = Time.now
          # Manually ping the process per second to check whether the process is alive or not
          while (Time.now - start) < options[:timeout] && status.alive?
            begin
              out_buf << stdout.read_nonblock(4096)
              err_buf << stderr.read_nonblock(4096)
            rescue IO::WaitReadable, EOFError
            end
            sleep 0.2
          end

          if status.alive?
            Process.kill("TERM", pid)
            Process.detach(pid)
            raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} timed out:\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}"
          end
          exit_status = status.value.exitstatus
          raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} exited with #{status.value.exitstatus}:\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}" unless exit_status == 0
          exit_status
        else
          # If the work is still not done after timeout, then kill the process and record an erorr log
          Thread.new do
            sleep options[:timeout]
            if status.alive?
              Process.kill("TERM", pid)
              Process.detach(pid)
              logger.error "sh #{args} executed with pid #{pid} timed out" if logger
            else
              logger.error "sh #{args} executed with failure, the exit status is #{status.value.exitstatus}" if status.value.exitstatus != 0 && logger
            end
          end
          return 0
        end
      rescue Errno::EPERM
        raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} cannot be killed (privilege issue?):\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}"
      rescue Errno::ESRCH
        raise RuntimeError, "sh #{args} executed with failure and process with pid #{pid} does not exist:\nstdout:\n#{out_buf}\nstderr:\n#{err_buf}"
      rescue => e
        raise e
      end
    end
  end
end
