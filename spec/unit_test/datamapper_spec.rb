# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/spec_helper'

describe DataMapperTests do
  describe "lock file" do
    before :each do
      DataMapperTests.clean_lock_file
    end

    after :all do
      DataMapperTests.clean_lock_file
    end

    it "should be able to initialize lock" do
      expect{DataMapper::initialize_lock_file(LOCK_FILE)}.to_not raise_error
    end

    it "should be able to initialize lock by setup with string" do
      DataMapper.should_receive(:initialize_lock_file).with(LOCK_FILE)
      DataMapper.setup(:default, "sqlite:#{LOCALDB_FILE}", :lock_file => LOCK_FILE)
    end

    it "should be able to initialize lock by setup with options" do
      DataMapper.should_receive(:initialize_lock_file).with(LOCK_FILE)
      DataMapper.setup(:default, :adapter => "sqlite", :database => LOCALDB_FILE, :lock_file => LOCK_FILE)
    end
  end
end
