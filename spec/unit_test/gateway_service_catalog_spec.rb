require 'helper/spec_helper'
require 'base/gateway_service_catalog'


module VCAP::Services
  describe GatewayServiceCatalog do
    let(:service_catalog) { GatewayServiceCatalog.new([service_attrs]) }

    let(:service_attrs) {
      {
        version_aliases: version_aliases,
        provider: provider,
        label: "test-data-here-9.12.43",
        unique_id: unique_id,
        plans: {
          'name_of_plan_1' => {unique_id: 'unique-id-1'},
          'name_of_plan_2' => {unique_id: 'unique-id-2'}
        }
      }.merge(extra_components)
    }
    let(:version_aliases) { {} }
    let(:unique_id) { 'unique_id' }
    let(:provider) { 'provider' }
    let(:extra_components) { {} }

    describe "#initialize" do
      let(:unique_id) { nil }

      it 'requires :unique_id' do
        expect {
          GatewayServiceCatalog.new([service_attrs])
        }.to raise_error(ArgumentError)
      end
    end

    describe "#services" do
      let(:service) { service_catalog.services.first }

      it 'returns a list of services' do
        service_catalog.services.should have(1).entry
        service_catalog.services.first.should be_a(Service)
      end

      it 'removes the version from the label' do
        service.label.should == 'test-data-here'
      end

      it 'sets Service#unique_id' do
        service.unique_id.should == unique_id
      end

      it 'sets the name for the plans' do
        plans = service.plans
        plans[0].name.should == "name_of_plan_1"
        plans[1].name.should == "name_of_plan_2"
      end

      describe 'service provider' do
        context 'when no provider is given' do
          let(:provider) { nil }

          it 'defaults to "core"' do
            service.provider.should == 'core'
          end
        end

        context 'when a provider is given' do
          let(:provider) { 'myprovider' }

          it 'uses that provider' do
            service.provider.should == provider
          end
        end
      end

      describe 'extra' do
        context 'when extra data field parts are provided' do
          let(:extra_components) {
            {
              :logo_url => "http://example.com/pic.png",
              :blurb => "One sweet service",
              :provider_name => "USGOV"
            }
          }

          it 'constructs extra data from parts via the config file' do
            decoded_extra = Yajl::Parser.parse(service.extra)
            decoded_extra.should == {
              "listing" => {
                "imageUrl" => "http://example.com/pic.png",
                "blurb" => "One sweet service"
              },
              "provider" => {"name" => "USGOV"}
            }
          end
        end

        context 'when no extra data field parts are provided' do
          let(:extra_components) { {} }

          it 'sets the extra field to nil' do
            service.extra.should be_nil
          end
        end
      end

      context 'when no version_aliases is provided' do
        let(:version_aliases) { {} }

        it 'sets Service#version from the label' do
          service.version.should == '9.12.43'
        end
      end

      context 'when a current version_alias is given' do
        let(:version_aliases) { {current: '5.2'} }

        it 'sets uses that version' do
          service.version.should == '5.2'
        end
      end
    end
  end
end
