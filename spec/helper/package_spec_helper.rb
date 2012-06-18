# Copyright (c) 2009-2012 VMware, Inc.
require 'helper/spec_helper'

require 'base/job/package'
require 'digest/md5'

# detect whether zip utilities are installed in system path
def detect_zip
  system("which zip") && system("which unzip")
end

# get file path for certain asset
def assets_path file
  File.expand_path("../assets/#{file}", File.dirname(__FILE__))
end

# return true if content of two files are identical
def files_identical? file1, file2
  digest1 = Digest::MD5.file (file1)
  digest2 = Digest::MD5.file (file2)
  digest1 == digest2
end
