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
  task "spec" do |t|
    sh("if which nats-server > /dev/null; then
          cd spec && (nats-server &) && rake spec && pkill -f nats-server
        else
          cd spec && ../bin/nats-util start && rake spec && ../bin/nats-util stop
        fi")
  end

  task "spec:rcov" do |t|
    sh("if which nats-server > /dev/null; then
          cd spec && (nats-server &) && rake simcov && pkill -f nats-server
        else
          cd spec && ../bin/nats-util start && rake simcov && ../bin/nats-util stop
        fi")
  end

  task "spec:ci" do |t|
    sh("if which nats-server > /dev/null; then
          cd spec && (nats-server &) && rake spec:ci && pkill -f nats-server
        else
          cd spec && ../bin/nats-util start && rake spec:ci && ../bin/nats-util stop
        fi")
  end
end
