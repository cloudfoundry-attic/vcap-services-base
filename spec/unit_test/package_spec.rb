# Copyright (c) 2009-2012 VMware, Inc.
require 'helper/package_spec_helper'
require 'tempfile'
require 'fileutils'
require 'yajl'

describe VCAP::Services::Base::AsyncJob::Package do

  it "should able to generate and load package file" do
    temp_file = Tempfile.new("all.zip")
    package = VCAP::Services::Base::AsyncJob::Package.new(temp_file.path)
    package.add_files([
      assets_path("test.sql"),
      assets_path("test.zip")
    ])
    package.manifest = {
      :version => 1,
    }
    package.pack force=true

    if detect_zip
      begin
        temp_dir = Dir.mktmpdir
        res = system("unzip #{temp_file.path} -d #{temp_dir}")
        res.should_not be_nil

        File.open(File.join(temp_dir, "manifest")) do |f|
          manifest = Yajl::Parser.parse(f.read)
          manifest["version"].should == 1
        end

        %w(test.sql test.zip).each do |f|
          files_identical?( assets_path(f),
                           File.join(temp_dir, "content", f)
                         ).should == true
        end
      ensure
        FileUtils.rm_rf temp_dir if temp_dir
      end
    else
      pending "zip or unzip binary is not installed."
    end
  end

  it "should able to load a package file" do
    temp_file = Tempfile.new("test.zip")
    package = VCAP::Services::Base::AsyncJob::Package.new(temp_file.path)
    package.add_files([
      assets_path("test.sql"),
    ])
    package.manifest = {
      :version => 1,
    }
    package.pack force=true

    begin
      temp_dir = Dir.mktmpdir
      package2 = VCAP::Services::Base::AsyncJob::Package.load(temp_file.path)

      # read manifest
      package2.manifest[:version].should == 1

      # unpack
      package2.unpack(temp_dir)
      f = "test.sql"
      files_identical?( assets_path(f), File.join(temp_dir, f)).should == true
    ensure
      FileUtils.rm_rf temp_dir if temp_dir
    end
  end

  it "should raise error if package file is corrupted" do
    package = VCAP::Services::Base::AsyncJob::Package.load(assets_path("test.zip"))
    package.manifest.should_not be_empty

    temp_file = Tempfile.open("corrupted.zip") do |tf|
      origin_file = nil
      File.open(assets_path "test.zip") do |f|
        origin_file = f.read
      end
      # modify random bits
      origin_file[300] = '0'
      tf << origin_file
    end

    begin
      temp_dir = Dir.mktmpdir
      expect{
        package = VCAP::Services::Base::AsyncJob::Package.load temp_file.path
        package.unpack(temp_dir)
      }.to raise_error(/corrupted/)
      # unpack should auto cleanup
      Dir.glob("#{temp_dir}/**/*").should be_empty
    ensure
      FileUtils.rm_rf temp_dir if temp_dir
    end
  end

  it "should create package file with proper permission mode" do
    temp_file = Tempfile.new("all.zip")
    package = VCAP::Services::Base::AsyncJob::Package.new(temp_file.path)
    package.add_files([
      assets_path("test.sql"),
    ])
    package.pack force=true

    # default file mode is 0644
    File.stat(temp_file).mode.should == 0100644

    mode = 0600
    package = VCAP::Services::Base::AsyncJob::Package.new(temp_file.path, :mode => mode)
    package.add_files([
      assets_path("test.sql"),
    ])
    package.pack force=true

    File.stat(temp_file).mode.should == 0100000 + mode
  end
end
