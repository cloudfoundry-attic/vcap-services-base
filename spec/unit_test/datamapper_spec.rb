# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/spec_helper'

LOCK_FILE = "/tmp/foo"

describe "datamapper extensions" do

  before :all do
    File::delete(LOCK_FILE) if File::exists?(LOCK_FILE)
  end

  it "should be able to initialize lock" do
    require 'base/datamapper_l'
    DataMapper::initialize_lock_file(LOCK_FILE)
  end

end
