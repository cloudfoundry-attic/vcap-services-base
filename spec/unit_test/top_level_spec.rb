# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/spec_helper'

describe "main entry point" do
  it "should load cleanly" do
    require 'vcap_services_base'
  end
end
