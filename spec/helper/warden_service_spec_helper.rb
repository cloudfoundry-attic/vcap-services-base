require 'base/warden/service'

DEF_OPTIONS = {
  :base_dir => "/tmp/base_test",
  :service_log_dir => "/tmp/base_test",
  :local_db => "sqlite:/tmp/base_test/base.db",
}

class Wardenservice < VCAP::Services::Base::Warden::Service
  include DataMapper::Resource
  property :name,       String,   :key => true
  property :container,  String

  def self.create
    instance = new
    instance.name = UUIDTools::UUID.random_create.to_s
    instance.container = instance.name[0, 8]
    instance.save!
  end
end
