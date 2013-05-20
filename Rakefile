require 'rake'
require 'bundler'
Bundler.require(:default, :test)

require 'rspec/core/rake_task'
require 'ci/reporter/rake/rspec'

RSpec::Core::RakeTask.new do |t| # define 'spec' task
  t.pattern = "spec/unit_test/*_spec.rb"
end
task "default" => "spec"

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

