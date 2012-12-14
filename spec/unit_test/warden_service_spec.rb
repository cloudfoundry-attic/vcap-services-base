# Copyright (c) 2009-2012 VMware, Inc.
require 'helper/spec_helper'

describe "Warden Service test" do
  before :all do
    WardenService.init(DEF_OPTIONS)
    5.times { WardenService.create }
  end

  after :all do
    FileUtils.rm_rf(DEF_OPTIONS[:base_dir])
  end

  it "should store in_memory properties" do
    verify = {}

    WardenService.all.each do |ins|
      id = UUIDTools::UUID.random_create.to_s
      ins.my_mem_status = id
      verify[ins.name] = id
    end

    WardenService.all.each do |ins|
      ins.my_mem_status.should == verify[ins.name]
      ins.my_new_prop.should be_nil
    end
  end
end
