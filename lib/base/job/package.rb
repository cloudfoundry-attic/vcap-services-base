# Copyright (c) 2009-2012 VMware, Inc.
require "zip/zip"
require "yajl"
require 'vcap/common'

module VCAP::Services::Base::AsyncJob

  class Package
    include VCAP::Services::Base::Error

    MANIFEST_FILE = "manifest".freeze
    CONTENT_FOLDER = "content".freeze
    attr_reader :manifest

    class << self
      def load path
        raise "File #{path} not exists." unless File.exists? path
        p = new(path)
        p.load_manifest
        p
      end
    end

    def initialize(zipfile, opts={})
      @zipfile = zipfile
      @files = {}
      @manifest = {}
      @filemode = opts[:mode] || 0644
    end

    def add_files(files)
      files =  Array(files)
      files.each do |file|
        raise "File #{file} not found." unless File.exists? file
        raise "File #{file} is not readable." unless File.readable? file
        basename = File.basename file
        @files[basename] = file
      end
    end

    # add +hash+ to manifest file.
    def manifest=(hash)
      return unless hash
      raise "Input should be Hash" unless hash.is_a? Hash
      @manifest.merge! VCAP.symbolize_keys(hash)
    end

    # package files and manifest in +zipfile+. If +force+ is true, we'll try to delete the target +zipfile+ if it already exists.
    def pack(force=nil)
      if File.exists? @zipfile
        if force
          File.delete @zipfile
        else
          raise "File #{@zipfile} already exists."
        end
      end

      dirname = File.dirname(@zipfile)
      raise "Dir #{dirname} is not exists." unless File.exists? dirname
      raise "Dir #{dirname} is not writable." unless File.writable? dirname

      Zip::ZipFile.open(@zipfile, Zip::ZipFile::CREATE) do |zf|
        # manifest file
        zf.get_output_stream(MANIFEST_FILE) {|o| o << Yajl::Encoder.encode(@manifest)}

        @files.each do |f, path|
          zf.add("#{CONTENT_FOLDER}/#{f}", path)
        end
      end

      begin
        File.chmod(@filemode, @zipfile)
      rescue => e
        raise "Fail to change the mode of #{@zipfile} to #{@filemode.to_s(8)}: #{e}"
      end
    end

    # unpack the content to +path+ and return extraced file list.
    def unpack path
      raise "File #{@zipfile} not exists." unless File.exists? @zipfile
      raise "unpack path: #{path} not found." unless Dir.exists? path
      raise "unpack path: #{path} is not writable." unless File.writable? path

      files = []
      Zip::ZipFile.foreach(@zipfile) do |entry|
        next if entry.to_s == MANIFEST_FILE
        entry_name = File.basename entry.to_s
        dst_path = File.join(path, entry_name)
        dirname = File.dirname(dst_path)
        FileUtils.mkdir_p(dirname) unless File.exists? dirname
        files << dst_path
        entry.extract(dst_path)
      end
      files.freeze
      yield files if block_given?
      files
    rescue => e
      # auto cleanup if error raised.
      files.each{|f| File.delete f if File.exists? f} if files
      raise ServiceError.new(ServiceError::FILE_CORRUPTED) if e.is_a? Zlib::DataError
      raise e
    end

    # read manifest in a zip file
    def load_manifest
      zf = Zip::ZipFile.open(@zipfile)
      @manifest = VCAP.symbolize_keys(Yajl::Parser.parse(zf.read(MANIFEST_FILE)))
    rescue Errno::ENOENT => e
      raise ServiceError.new(ServiceError::BAD_SERIALIZED_DATAFILE, "request. Missing manifest.")
    end
  end
end
