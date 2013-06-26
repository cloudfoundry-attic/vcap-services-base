source "http://rubygems.org"

gemspec

group :test do
  gem "rake"
  gem "rspec"
  gem "ci_reporter"
  gem "dm-sqlite-adapter"
  gem 'vcap_common', :require => ['vcap/common', 'vcap/component'], :git => 'git://github.com/cloudfoundry/vcap-common.git'
  gem 'vcap_logging', :require => ['vcap/logging'], :git => 'git://github.com/cloudfoundry/common.git'
  gem 'warden-client', :require => ['warden/client'], :git => 'git://github.com/cloudfoundry/warden.git'
  gem 'warden-protocol', :require => ['warden/protocol'], :git => 'git://github.com/cloudfoundry/warden.git'
  gem 'debugger'
  gem 'webmock'
  gem 'rack-test'
end
