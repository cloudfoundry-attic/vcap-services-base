$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), "lib"))
require "base/version"

Gem::Specification.new do |s|
  s.name         = "vcap_services_base"
  s.version      = VCAP::Services::Base::VERSION
  s.platform     = Gem::Platform::RUBY
  s.summary      = "VCAP services base module"
  s.description  = "Base class/module to develop CloudFoundry service"
  s.homepage     = "https://github.com/cloudfoundry/vcap-services-base"
  s.files        = Dir.glob("lib/**/*")
  s.require_path = [ "lib" ]
  s.author       = "CloudFoundry Services Team"
  s.email        = "cfpi-services@googlegroups.com"

  s.add_dependency "nats", ">= 0.4.22.beta.8", "< 0.4.28"
  s.add_dependency "data_mapper", "~> 1.2"
  s.add_dependency "do_sqlite3"
  s.add_dependency "eventmachine", "~> 1.0"
  s.add_dependency "eventmachine_httpserver", "~> 0.2.1"
  s.add_dependency "json"
  s.add_dependency "ruby-hmac", "~> 0.4.0"
  s.add_dependency "em-http-request", "~> 1.0"
  s.add_dependency "sinatra", ">= 1.2.3"
  s.add_dependency "thin", "~> 1.3.1"
  s.add_dependency "vcap_common", ">= 2.1.0"
  s.add_dependency "vcap_logging", ">= 1.0.2"
  s.add_dependency "resque", "~> 1.20"
  s.add_dependency "resque-status"
  s.add_dependency "curb", "~> 0.7.16"
  s.add_dependency "rubyzip", "~> 0.9.8"
  s.add_dependency "warden-client"
  s.add_dependency "warden-protocol"
  s.add_dependency "cf-uaa-lib"
end
