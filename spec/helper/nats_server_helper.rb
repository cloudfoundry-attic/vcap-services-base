module IntegrationHelpers
  def run_cmd(cmd, opts={})
    project_path = File.join(File.dirname(__FILE__), "../..")
    spawn_opts = {
      :chdir => project_path,
      :out => opts[:debug] ? :out : "/dev/null",
      :err => opts[:debug] ? :out : "/dev/null",
    }

    Process.spawn(cmd, spawn_opts).tap do |pid|
      if opts[:wait]
        Process.wait(pid)
        raise "`#{cmd}` exited with #{$?}" unless $?.success?
      end
    end
  end

  def port_open?(nats_port)
    socket = TCPSocket.open("localhost", nats_port)
    socket.close
    true
  rescue Errno::ECONNREFUSED
    false
  end

  def check_process_alive!(name, pid, options={})
    sleep(options[:sleep]) if options[:sleep]
    raise "Process #{name} with pid #{pid} is not alive." \
      unless process_alive?(pid)
  end

  def graceful_kill(name, pid)
    Process.kill("TERM", pid)
    Timeout.timeout(1) do
      while process_alive?(pid) do
      end
    end
  rescue Timeout::Error
    Process.kill("KILL", pid)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end

RSpec.configure do |c|
  c.include IntegrationHelpers
  c.before(:all) do
    if !port_open?(4222)
      @nats_pid = run_cmd("nats-server -V -D")
      remaining_sleeps = 10
      while !port_open?(4222)
        sleep(0.5)
        remaining_sleeps -= 1
        raise "NATS failed to bind" if remaining_sleeps == 0
      end
    end
  end
  c.after(:all) do
    if @nats_pid
      graceful_kill(:nats, @nats_pid)
    end
  end
end
