require 'rake'
require 'bundler'

desc "Run specs"
task "spec" => ["test:spec"]

desc "Run specs using SimpleCov"
task "spec:rcov" => ["test:spec:rcov"]

desc "Run ci using SimpleCov"
task "spec:ci" => ["test:spec:ci"]

namespace "bundler" do
  gem_helper = Bundler::GemHelper.new(Dir.pwd)
  desc "Build gem package"
  task "build" do
    gem_helper.build_gem
  end

  desc "Install gems"
  task "install" do
    sh("bundle install")
    gem_helper.install_gem
  end

  desc "Install gems for test"
  task "install:test" do
    sh("bundle install --without development production")
    gem_helper.install_gem
  end

  desc "Install gems for production"
  task "install:production" do
    sh("bundle install --without development test")
    gem_helper.install_gem
  end

  desc "Install gems for development"
  task "install:development" do
    sh("bundle install --without test production")
    gem_helper.install_gem
  end
end

namespace "test" do
  def run_spec
    Dir.chdir("spec")
    if `ps ax | grep nats-server | grep -v grep` == ""
      sh "nats-server &"
      yield
      sh "pkill -f nats-server"
    else
      yield
    end
  end

  def run_or_fail(cmd)
    raise "Failed to run '#{cmd}'" unless system(cmd)
  end

  task "spec" do |t|
    run_spec { run_or_fail "rake spec" }
  end

  task "spec:rcov" do |t|
    run_spec { run_or_fail "rake simcov" }
  end

  task "spec:ci" do |t|
    run_spec { run_or_fail "rake spec:ci" }
  end
end
