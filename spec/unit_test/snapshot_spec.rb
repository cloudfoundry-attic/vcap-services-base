require 'helper/job_spec_helper'

describe VCAP::Services::Base::AsyncJob::Snapshot::SnapshotJob do
  before do
    ENV['WORKER_CONFIG'] = "{}"
    VCAP::Services::Base::AsyncJob::Snapshot.stub(:redis_connect)
  end

  it "should select the correct queue name" do
    args =  {:node_id => "demo_node"}

    described_class.select_queue(args).should  == "demo_node"
  end

  describe "#create_lock" do
    it "creates a lock with name lock:lifecycle:<name>" do
      service_id = "demo_service"
      expected_lock_name = "lock:lifecycle:#{service_id}"
      VCAP::Services::Base::AsyncJob::Lock.should_receive(:new).with(expected_lock_name, anything)
      job = described_class.new(service_id: service_id)
      # Yuck
      job.instance_variable_set(:@name, service_id)
      job.create_lock
    end

    it "uses ttl set in env" do
      VCAP::Services::Base::AsyncJob::Lock.should_receive(:new).with(anything,
                                                                     hash_including(ttl: 100))
      with_env("WORKER_CONFIG" => '{"job_ttl": 100}') do
        job = described_class.new(:service_id => 'anything')
        job.create_lock
      end
    end
  end
end

describe VCAP::Services::Base::AsyncJob::Snapshot::BaseCreateSnapshotJob do
  describe "#perform" do
    before(:each) do
      VCAP::Services::Base::AsyncJob::Config.stub(:logger => mock("logger").as_null_object)
      VCAP::Services::Base::AsyncJob::Snapshot.stub(:redis_connect)
    end

    it "is sad without :service_id" do
      job = nil
      with_env("WORKER_CONFIG" => '{}') do
        job = described_class.new("uuid", {})
      end
      job.stub(:set_status)
      job.should_receive(:set_status).with(
        {"status" => "failed"},
        anything,
      ).at_least(:once)
      job.perform
    end

    it "should evoke execute method to sub class"
  end
end
