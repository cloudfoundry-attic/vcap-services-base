source "http://rubygems.org"

gemspec

group :test do
  gem "rake"
  gem "sinatra"
  gem "rspec"
  gem "ci_reporter"
  gem "simplecov"
  gem "simplecov-rcov"
  gem "dm-sqlite-adapter"
  gem "cf-uaa-client", :git => 'git://github.com/cloudfoundry/cf-uaa-client.git'
  gem 'eventmachine', :git => 'git://github.com/cloudfoundry/eventmachine.git', :branch => 'release-0.12.11-cf'
  gem 'vcap_common', :require => ['vcap/common', 'vcap/component'], :git => 'git://github.com/cloudfoundry/vcap-common.git', :ref => 'fd6b6d91'
  gem 'vcap_logging', :require => ['vcap/logging'], :git => 'git://github.com/cloudfoundry/common.git', :ref => 'b96ec1192d'
  gem 'warden-client', :require => ['warden/client'], :git => 'git://github.com/cloudfoundry/warden.git', :ref => 'fe6cb51'
  gem 'warden-protocol', :require => ['warden/protocol'], :git => 'git://github.com/cloudfoundry/warden.git', :ref => 'fe6cb51'
end
