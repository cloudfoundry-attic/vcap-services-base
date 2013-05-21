require 'helper/spec_helper'
require 'base/gateway_service_catalog'


module VCAP::Services
  describe GatewayServiceCatalog do
    describe '#to_hash' do
      let(:service_catalog) { GatewayServiceCatalog.new([service]) }
      let(:service) { {version_aliases: {}, provider: "provider", label: "test-data-here-version", plans: {}} }

      it "allows a dash in the label name" do
        expect do
          service_catalog.to_hash
        end.not_to raise_error
      end

      it "publishes a configured unique_id when present" do
        service.merge!(:unique_id => "uniqueness")
        data = service_catalog.to_hash.fetch("test-data-here_provider")
        data.fetch("unique_id").should == "uniqueness"
      end

      it "only publishes the unique_id if there is one" do
        data = service_catalog.to_hash.fetch("test-data-here_provider")
        data.should_not have_key "unique_id"
      end

      it 'constructs extra data from parts via the config file' do
        service.merge!(:logo_url => "http://example.com/pic.png", :blurb => "One sweet service", :provider_name => "USGOV")
        data = service_catalog.to_hash.fetch("test-data-here_provider").fetch("extra")
        decoded_extra = Yajl::Parser.parse(data)
        decoded_extra.should == {"listing" => {"imageUrl" => "http://example.com/pic.png", "blurb" => "One sweet service"}, "provider" => {"name" => "USGOV"}}
      end

      it 'wont send extra if not needed' do
        data = service_catalog.to_hash.fetch("test-data-here_provider")
        data.should_not have_key("extra")
      end

      it 'sets the name for the plans' do
        service.merge!(
          plans: {
            'name_of_plan_1' => {free: true},
            'name_of_plan_2' => {free: false}
          }
        )
        data = service_catalog.to_hash.fetch("test-data-here_provider")
        plans = data.fetch("plans")
        plans.fetch("name_of_plan_1").fetch(:name).should == "name_of_plan_1"
        plans.fetch("name_of_plan_2").fetch(:name).should == "name_of_plan_2"
      end
    end
  end
end
