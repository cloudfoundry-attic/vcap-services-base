require "spec_helper"
require "base/snapshot_v2/snapshot_job"

describe VCAP::Services::Base::SnapshotV2::SnapshotJob do
  describe ".new" do
    subject { described_class.new("uuid", {}) }

    it "parse the WORKER_CONFIG env var as json" do
      with_env('WORKER_CONFIG' => '{"name":"id1"}') do
        subject.parse_config.should == {"name" => "id1"}
      end
    end

    it "raises when WORKER_CONFIG env var is empty" do
      with_env('WORKER_CONFIG' => '' ) do
        expect { subject }.to raise_error /Need environment variable: WORKER_CONFIG/
      end
    end

    describe ".select_queue" do
      let(:job_parameters) { {:node_id => 1, :some_lookup_key => 2}}
      it "uses the default queue_lookup_key" do
        described_class.select_queue(job_parameters).should == 1
      end

      it "uses some_other_lookup_key" do
        a_subclass = Class.new(described_class) do
          def self.queue_lookup_key
            :some_lookup_key
          end
        end
        a_subclass.select_queue(job_parameters).should == 2
      end

      it "raises error when there is no queue matched" do
        job_parameters = { :some_lookup_key => 2}
        expect { described_class.select_queue(job_parameters) }.to raise_error /no queue matched/
      end
    end
  end
end
