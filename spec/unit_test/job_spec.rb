# Copyright (c) 2009-2012 VMware, Inc.
require 'helper/job_spec_helper'

describe VCAP::Services::Base::AsyncJob::Lock do

  before :all do
    @timeout = 10
    @expiration = 5
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::ERROR
    @name = "foo"
  end

  before :each do
    @redis = double("redis")

    @stored_value = nil
    Redis.should_receive(:new).at_least(1).times.and_return(@redis)
    VCAP::Services::Base::AsyncJob::Config.redis_config = {}

    @redis.should_receive(:setnx).with(@name, anything).at_least(1).times do |_, value|
      if @stored_value.nil?
        @stored_value = value
        true
      else
        nil
      end
    end
    @redis.should_receive(:get).with(@name).at_least(1).times do
      @stored_value
    end
    @redis.should_receive(:set).with(@name, anything).at_least(1).times do |_, value|
      @stored_value = value
    end
    @redis.should_receive(:del).with(@name) do
      @stored_value = nil
      nil
    end
  end

  it "should acquire and release a lock" do
    @redis.should_receive(:watch).with(@name).at_least(1).times
    @redis.should_receive(:multi).at_least(1).times.and_yield

    lock = VCAP::Services::Base::AsyncJob::Lock.new(@name,:timeout => @timeout, :expiration => @expiration)

    ran_once = false
    lock.lock do
      ran_once = true
    end

    expect(ran_once).to eq(true)
  end

  it "should not let two clients acquire the same lock at the same time" do
    @redis.should_receive(:watch).with(@name).at_least(1).times
    @redis.should_receive(:multi).at_least(1).times.and_yield

    lock_a = VCAP::Services::Base::AsyncJob::Lock.new(@name,:timeout => @timeout, :expiration => @expiration, :logger => @logger)
    lock_b = VCAP::Services::Base::AsyncJob::Lock.new(@name,:timeout => 0.1, :logger => @logger)

    lock_a_ran = false
    lock_b_ran = false
    lock_a.lock do
      lock_a_ran = true
      expect{lock_b.lock{ lock_b_ran = true } }.to raise_error(VCAP::Services::Base::Error::ServiceError, /Job timeout/)
    end

    expect(lock_a_ran).to eq(true)
    expect(lock_b_ran).not_to be(true)
  end

  it "should acquire an expired lock" do
    start = Time.now.to_f
    @stored_value = (start + 3)  #lock that expires in 3 seconds

    @redis.should_receive(:watch).with(@name).at_least(1).times
    @redis.should_receive(:multi).at_least(1).times.and_yield

    lock = VCAP::Services::Base::AsyncJob::Lock.new(@name,:timeout => @timeout, :expiration => @expiration, :logger => @logger)

    ran_once = false
    lock.lock{ran_once = true}

    expect(ran_once).to eq(true)
    expect(@stored_value == start - 1).not_to be(true)
  end

  it "should not update expiration time after the lock is released" do
    start = Time.now.to_f

    @redis.should_receive(:watch).with(@name).at_least(1).times
    @redis.should_receive(:multi).at_least(1).times.and_yield

    expiration = 0.5
    lock = VCAP::Services::Base::AsyncJob::Lock.new(@name,:timeout => @timeout, :expiration => expiration, :logger => @logger)

    ran_once = false
    lock.lock{ran_once = true; sleep expiration *2 }

    current_value = @stored_value
    sleep expiration * 2
    current_value.should == @stored_value
    expect(ran_once).to eq(true)
  end

  it "should raise error if lock exceed ttl" do
    @redis.should_receive(:watch).with(@name).at_least(1).times
    @redis.should_receive(:multi).at_least(1).times.and_yield

    ttl = 1
    lock = VCAP::Services::Base::AsyncJob::Lock.new(@name, :logger => @logger, :ttl => ttl)

    ran_once = false
    expect { lock.lock{ ran_once = true; sleep ttl * 2} }.to raise_error(VCAP::Services::Base::Error::ServiceError, /ttl: #{ttl} seconds/)
    expect(ran_once).to eq(true)
  end
end
