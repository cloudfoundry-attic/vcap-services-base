# Copyright (c) 2009-2012 VMware, Inc.
require 'helper/spec_helper'

describe "Warden Service test" do
  before :all do
    Wardenservice.init(DEF_OPTIONS)
    5.times { Wardenservice.create }
  end

  after :all do
    FileUtils.rm_rf(DEF_OPTIONS[:base_dir])
  end

  it "should store in_memory properties" do
    verify = {}

    Wardenservice.all.each do |ins|
      id = UUIDTools::UUID.random_create.to_s
      ins.im_my_mem_status = id
      verify[ins.name] = id
    end

    Wardenservice.all.each do |ins|
      ins.im_my_mem_status.should == verify[ins.name]
      ins.im_my_new_prop.should be_nil
    end
  end

  it "should be able to work with datamapper relations" do
    # DataMapper relations use method_missing as well.
    # Our method_missing should not interfere with it.
    Wardenservice.all.each do |ins|
      ins.users.all(:default_user => true).size.should == 1
    end
  end
end
