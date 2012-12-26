require 'base/warden/service'

DEF_OPTIONS = {
  :base_dir => "/tmp/base_test",
  :service_log_dir => "/tmp/base_test",
  :local_db => "sqlite:/tmp/base_test/base.db",
}

class Binduser < VCAP::Services::Base::Warden::Service
  include DataMapper::Resource
  property :name,       String,   :key => true
  property :default_user,    Boolean, :default => true
  belongs_to :wardenservice
end

class Wardenservice < VCAP::Services::Base::Warden::Service
  include DataMapper::Resource
  property :name,       String,   :key => true
  property :container,  String
  property :default,    Boolean
  has n, :bindusers

  def self.create
    instance = new
    instance.name = UUIDTools::UUID.random_create.to_s
    instance.container = instance.name[0, 8]
    instance.default = true
    user = Binduser.new
    user.name = UUIDTools::UUID.random_create.to_s
    instance.bindusers << user
    user.save

    user = Binduser.new
    user.name = UUIDTools::UUID.random_create.to_s
    user.default_user = false
    instance.bindusers << user
    user.save
    instance.save!
  end

  def users
    bindusers
  end
end
