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
      ins.failed_times = id
      verify[ins.name] = id
    end

    Wardenservice.all.each do |ins|
      ins.failed_times.should == verify[ins.name]
    end
  end
end
