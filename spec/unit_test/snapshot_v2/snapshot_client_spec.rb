require "helper/spec_helper"
require "base/snapshot_v2/snapshot_client"

describe VCAP::Services::Base::SnapshotV2::SnapshotClient do
  let(:redis_mock) { mock("redis") }
  before(:each) do
    Redis.stub(:new).with(kind_of(Hash)).and_return redis_mock
    redis_mock.stub(:setnx)
  end

  describe ".new" do
    before(:each) do
      Redis.unstub(:new)
    end

    let(:config_hash) { {:host => 'localhost', :port => 2345} }

    it "takes a redis config" do
      Redis.should_receive(:new).with(config_hash).and_return(redis_mock)
      client = described_class.new(config_hash)
    end

    it "uses v2 prefix" do
      Redis.should_receive(:new).with(config_hash).and_return(redis_mock)
      redis_mock.should_receive(:setnx).with("vcap:snapshotv2:maxid", 1)
      client = described_class.new(config_hash)
    end
  end

  context 'with fake redis' do
    let(:new_snapshot_id) { 'new snapshot id' }
    before :each do
      redis_mock.stub(:setnx)
      redis_mock.stub(:incr).and_return(new_snapshot_id)
      redis_mock.stub(:hset)
      Redis.should_receive(:new).and_return(redis_mock)
    end

    describe "#create_empty_snapshot" do
      it "create an emty snapshot with empty state" do
        new_empty_snapshot = described_class.new({}).create_empty_snapshot(1234, 'Awesome sn')
        new_empty_snapshot.fetch('state').should == 'empty'
        new_empty_snapshot.fetch('size').should == 0
        new_empty_snapshot.fetch('name').should == 'Awesome sn'
        new_empty_snapshot.fetch('snapshot_id').should == new_snapshot_id
      end

      it "should be persisted to redis" do
        encoded_message = Yajl::Encoder.encode(
          {
            'state' => 'empty',
            'size'  => 0,
            'name'  => 'Awesome sn',
            'snapshot_id' => new_snapshot_id,
          }
        )
        redis_mock.should_receive(:hset).with(described_class.redis_key("1234"),
                                              new_snapshot_id,
                                              encoded_message)
        new_empty_snapshot = described_class.new({}).create_empty_snapshot('1234', 'Awesome sn')
      end
    end

    describe "#service_snapshots" do

      subject { described_class.new({}).service_snapshots(service_id) }

      context "with nil service_id" do
        let(:service_id) { nil }
        it "returns nil" do
          expect(subject).to be(nil)
        end
      end

      context "when service_id is not nil" do
        let(:service_id) { "svc-id" }
        context "when service instance isn't in redis" do
          it "returns an empty array" do
            redis_mock.should_receive(:hgetall).
              with(described_class.redis_key("#{service_id}")).and_return( {} )
            expect(subject).to eq([])
          end
        end

        it "gets all hash values from the v2 key" do
          redis_mock.should_receive(:hgetall).
            with(described_class.redis_key("#{service_id}")).and_return( {} )
          expect(subject).to eq([])
        end

        it "deserializes all values" do
          snapshots = {
            "snapshot-1" => '{"foo":"bar"}',
          }
          redis_mock.should_receive(:hgetall).and_return(snapshots)
          expect(subject).to eq([{"foo" => "bar"}])
        end
      end
    end
  end

  # we are tired of spelling this out
  describe ".redis_key" do
    it "uses the v2 namespace" do
      described_class.redis_key("abc").should eq("vcap:snapshotv2:abc")
    end
  end

  describe "#service_snapshots_count" do
    subject { described_class.new({}).service_snapshots_count(service_id) }

    context "when service_id is nil" do
      let(:service_id) { nil }
      it "returns nil" do
        expect(subject).to be(nil)
      end
    end

    context "given service_id" do
      let(:service_id) { "svc-id" }
      context "when the service_id is not in redis" do
        it "returns 0" do
          redis_mock.should_receive(:hlen).with(described_class.redis_key(service_id)).and_return(0)
          expect(subject).to be(0)
        end
      end

      it "gets the hash size from the v2 key" do
        redis_mock.should_receive(:hlen).with(described_class.redis_key(service_id)).and_return(2)
        expect(subject).to be(2)
      end
    end
  end

  describe "#snapshot_details" do
    let(:subject) { described_class.new({}).snapshot_details(service_id, snapshot_id) }

    context "when service_id is nil" do
      let(:service_id) { nil }
      let(:snapshot_id) { "1" }
      it "returns nil" do
        expect(subject).to eq(nil)
      end
    end

    context "when snapshot_id is nil" do
      let(:service_id) { "1" }
      let(:snapshot_id) { nil }
      it "returns nil" do
        expect(subject).to eq(nil)
      end
    end

    context "given both service_id and snapshot_id" do
      let(:service_id) { "svc-id1" }
      let(:snapshot_id) { "snapshot-id1"}
      context "without the corresponding snapshot info in redis" do
        it "raises ServiceError" do
          redis_mock.should_receive(:hget).
            with(described_class.redis_key(service_id), snapshot_id).
            and_return nil
          expect {subject}.to raise_error(VCAP::Services::Base::Error::ServiceError, /not found/)
        end
      end

      it "gets the hash value" do
        redis_mock.should_receive(:hget).
          with(described_class.redis_key(service_id), snapshot_id).
          and_return('{}')
        subject
      end

      it "decodes the snapshot information from json" do
        redis_mock.should_receive(:hget).
          with(described_class.redis_key(service_id), snapshot_id).
          and_return('{"foo":"bar"}')
        expect(subject).to eq({"foo" => "bar"})
      end
    end
  end

  describe ".filter_keys" do
    context "when snapshot is not a Hash" do
      it "returns nil" do
        expect(
          described_class.filter_keys([])
        ).to be_nil
      end
    end

    context "given a hash(of snapshot info)" do
      def self.has_key(key)
        it "returns #{key}" do
          hash = {key => "#{key} value", "crapkey" => "sillyvalue" }
          described_class.filter_keys(hash).should eq({key => "#{key} value"})
        end
      end

      has_key("snapshot_id")
      has_key("date")
      has_key("size")
      has_key("name")

      it "excludes keys outside of whitelist" do
        hash = {"snapshot_id" => "snapshot_id value", "internal" => "internal value"}
        described_class.filter_keys(hash).should_not include("internal")
      end
    end
  end

  describe ".snapshot_file_path" do
    it "shards the service_id based on service_id"
  end

  describe "#new_snapshot_id" do
    it "increases a global key in redis" do
      redis_mock.should_receive(:incr).with(described_class.redis_key("maxid")).and_return(2)
      expect(described_class.new({}).new_snapshot_id).to eq("2")
    end
  end

  describe "#save_snapshot" do
    subject {
      described_class.new({}).save_snapshot(service_id, snapshot)
    }
    let(:snapshot_id) { "snapshot-1" }
    let(:snapshot) { { "snapshot_id" => snapshot_id } }
    let(:service_id) { "svc-id" }

    context "when service_id is nil" do
      let(:service_id) { nil }
      it "returns nil" do
        expect(subject).to be(nil)
      end
    end

    context "given service_id" do
      context "without snapshot_id in hash" do
        let(:snapshot) {{}}
        it "returns nil" do
          expect(subject).to be(nil)
        end
      end

      it "stores the snapshot info into redis" do
        redis_mock.should_receive(:hset).with(
          described_class.redis_key(service_id),
          snapshot_id,
          anything,
        )
        subject
      end

      it "encodes the snapshot info into json" do
        redis_mock.should_receive(:hset).with(
          described_class.redis_key(service_id),
          snapshot_id,
          json_match(eq(snapshot)),
        )
        subject
      end
    end
  end

  describe "#update_name" do
    subject {
      described_class.new({}).update_name(service_id, snapshot_id, name)
    }
    let(:service_id) { "svc-id" }
    let(:snapshot_id) { "snapshot-id" }
    let(:name) { "new_name" }

    def self.require_key(key)
      context "when #{key} is nil" do
        let(key) { nil }
        it "returns nil" do
          expect(subject).to be(nil)
        end
      end
    end
    require_key(:service_id)
    require_key(:snapshot_id)
    require_key(:name)

    context "when new name is too long" do
      let(:name) { "new_name_" + "a" * 1023 }
      it "raises ServiceError" do
        expect {
          subject
        }.to raise_error(VCAP::Services::Base::Error::ServiceError, /Input name exceed the max allowed/)
      end
    end

    context "watches the whole snapshots" do
      before(:each) do
        redis_mock.should_receive(:watch).with(described_class.redis_key(service_id))
        redis_mock.should_receive(:hget).
          with(described_class.redis_key(service_id), snapshot_id).
          and_return('{}')
      end

      context "when optimistic locking fails" do
        it "raises ServiceError" do
          redis_mock.should_receive(:multi).and_return(nil)
          expect {
            subject
          }.to raise_error(VCAP::Services::Base::Error::ServiceError, /Server busy/)
        end
      end

      it "updates the name" do
        described_class.any_instance.should_receive(:save_snapshot).
          with(service_id, hash_including("name" => name)).
          and_return([])
        redis_mock.should_receive(:multi).and_yield
        expect(subject).to be_true
      end
    end
  end

  describe "#delete_snapshot" do
    let(:service_id) { "svc-id" }
    let(:snapshot_id) { "snapshot-1" }
    subject {
      described_class.new({}).delete_snapshot(service_id, snapshot_id)
    }

    def self.require_key(key)
      context "when #{key} is nil" do
        let(key) { nil }
        it "returns nil" do
          expect(subject).to be(nil)
        end
      end
    end
    require_key(:service_id)
    require_key(:snapshot_id)

    it "deletes the snapshot entry from redis" do
      redis_mock.should_receive(:hdel).with(
        described_class.redis_key(service_id),
        snapshot_id,
      )
      subject
    end
  end

  # yuck
  # FIXME: test for timestamp being UTC ISO8601 CreateSnapshotJob#perform
  describe ".fmt_time" do
    it "returns UTC time in ISO 8601 format" do
      # This is gross
      now = Time.now
      Time.stub(:now).and_return(now)
      described_class.fmt_time().should eq(Time.now.utc.iso8601)
    end
  end
end
