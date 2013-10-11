require 'helper/spec_helper'
require 'base/service_advertiser'
require 'base/service'

module VCAP::Services
  describe ServiceAdvertiser do
    it 'advertises all services' do
      pending "needs a test"
    end

    let(:logger) { double.as_null_object }
    let(:http_handler) { double.as_null_object }

    def build_service(options)
      defaults = {
        'guid' => nil,
        'unique_id' => nil,
        'provider' => nil,
        'version' => nil,
        'url' => nil,
        'extra' => nil,
        'plans' => []
      }
      Service.new(defaults.merge(options))
    end

    describe "#initialize" do
      it 'sets the guids for services in the catalog that exist in CC' do
        guid_1 = 'guid_1'
        unique_id_1 = 'unique_id_1'
        unique_id_2 = 'unique_id_2'
        catalog = [
          build_service('guid' => nil, 'unique_id' => unique_id_1),
          build_service('guid' => nil, 'unique_id' => unique_id_2)
        ]
        registered_services = [build_service('guid' => guid_1, 'unique_id' => unique_id_1)]
        advertiser = ServiceAdvertiser.new(
          current_catalog: catalog,
          catalog_in_ccdb: registered_services,
          logger: logger,
          http_handler: http_handler
        )
        service_1 = advertiser.catalog_services.detect { |s| s.unique_id == unique_id_1 }
        service_1.guid.should == guid_1

        service_2 = advertiser.catalog_services.detect { |s| s.unique_id == unique_id_2 }
        service_2.guid.should be_nil
      end
    end

    describe "#advertise_services" do
      let(:mock_http_handler) { double('HttpHandler') }

      context "for services that are active in cloud controller" do
        it "updates the service" do
          active_service_in_cc_db = build_service( 'guid' => "someguid90dsf9j", 'unique_id' => "12345ABC")
          active_service_in_catalog = build_service( 'guid' => nil, 'unique_id' => "12345ABC")

          service_advertiser = ServiceAdvertiser.new(
            catalog_in_ccdb: [active_service_in_cc_db],
            current_catalog: [active_service_in_catalog],
            logger: double.as_null_object,
            http_handler: mock_http_handler
          )

          mock_http_handler.should_receive(:cc_http_request).with do |options|
            options[:uri].should == '/v2/services/someguid90dsf9j'
            options[:method].should == 'put'

            expected_payload = active_service_in_catalog.to_hash
            expected_payload.delete('unique_id')
            expected_payload.delete('plans')
            Yajl::Parser.parse(options[:body]).should == expected_payload
          end

          service_advertiser.advertise_services
        end

        class FakeCCHttp
          attr_reader :response, :error
          def initialize(opts)
            @error = opts[:error]
            @status = opts[:status]
            @response = opts[:response]
          end

          Header = Struct.new(:status)
          def response_header
            Header.new(@status)
          end
        end

        context 'for plans that are in CC' do
          let(:active_service_in_cc_db) do
            build_service(
              'guid' => "someguid90dsf9j",
              'unique_id' => "12345ABC",
              'plans' => {
                'what' => {
                  unique_id: 'plan_external_id',
                  guid: 'plan_guid',
                }
              }
            )
          end

          it "updates the plans, not including public and unique_id fields" do
            active_service_in_catalog = build_service(
              'guid' => nil,
              'unique_id' => "12345ABC",
              'plans' => {
                'what' => {
                  unique_id: 'plan_external_id'
                }
              }
            )

            service_advertiser = ServiceAdvertiser.new(
              catalog_in_ccdb: [active_service_in_cc_db],
              current_catalog: [active_service_in_catalog],
              logger: double.as_null_object,
              http_handler: mock_http_handler
            )

            plan = active_service_in_catalog.plans.fetch(0)
            expected_plan_payload = plan.to_hash.tap do |h|
              h.delete('unique_id')
              h.delete('public')
              h['service_guid'] = 'someguid90dsf9j'
            end

            mock_http_handler.stub(:cc_http_request).ordered.
              with(hash_including(uri: "/v2/services/someguid90dsf9j")).
              and_yield(FakeCCHttp.new(error: nil, status: 201, response: {"metadata" => {"guid" => "someguid90dsf9j"}}.to_json))

            mock_http_handler.should_receive(:cc_http_request).ordered.with(
              hash_including(
                uri: "/v2/service_plans/plan_guid",
                method: "put",
              )
            ) do |opts|
              Yajl::Parser.parse(opts[:body]).should == expected_plan_payload
            end

            service_advertiser.advertise_services
          end
        end

        it "adds plans that are not in cloud controller" do
          active_service_in_cc_db = build_service(
            'guid' => "someguid90dsf9j",
            'unique_id' => "12345ABC",
            'plans' => {},
          )

          active_service_in_catalog = build_service(
            'guid' => nil,
            'unique_id' => "12345ABC",
            'plans' => {
              'what' => {
                unique_id: 'plan_external_id'
              }
            }
          )

          service_advertiser = ServiceAdvertiser.new(
            catalog_in_ccdb: [active_service_in_cc_db],
            current_catalog: [active_service_in_catalog],
            logger: double.as_null_object,
            http_handler: mock_http_handler
          )

          plan = active_service_in_catalog.plans.fetch(0)

          expected_plan_payload = plan.to_hash.tap do |h|
            h['service_guid'] = 'someguid90dsf9j'
          end
          mock_http_handler.stub(:cc_http_request).ordered.
            with(hash_including(uri: "/v2/services/someguid90dsf9j")).
            and_yield(FakeCCHttp.new(error: nil, status: 201, response: {"metadata" => {"guid" => "someguid90dsf9j"}}.to_json))

          mock_http_handler.should_receive(:cc_http_request).ordered.with(
            hash_including(
              uri: "/v2/service_plans",
              method: "post",
            )
          ) do |opts|
            Yajl::Parser.parse(opts[:body]).should == expected_plan_payload
          end

          service_advertiser.advertise_services
        end
      end

      context "for new services that are not yet in cloud controller" do
        it "adds the service" do
          service_in_catalog = build_service(
            'guid' => nil,
            'unique_id' => "12345ABC",
            'documentation_url' => 'docs.strongbodb.example.com',
            'plans' => {
            }
          )
          advertiser = ServiceAdvertiser.new(
            current_catalog: [service_in_catalog],
            catalog_in_ccdb: [],
            logger: double.as_null_object,
            http_handler: mock_http_handler,
          )

          expected_payload = service_in_catalog.to_hash.tap { |h| h.delete("plans") }
          mock_http_handler.should_receive(:cc_http_request).with do |options|
            options[:uri].should == "/v2/services"
            options[:method].should == 'post'
            Yajl::Parser.parse(options[:body]).should == expected_payload
          end

          advertiser.advertise_services
        end

        it "adds the service's plans" do
          service_in_catalog = build_service(
            'guid' => nil,
            'unique_id' => "12345ABC",
            'plans' => {
              'mahcoolplan' => {unique_id: "abcdefg123"}
            }
          )
          advertiser = ServiceAdvertiser.new(
            current_catalog: [service_in_catalog],
            catalog_in_ccdb: [],
            logger: double.as_null_object,
            http_handler: mock_http_handler,
          )
          mock_http_handler.should_receive(:cc_http_request).with(hash_including({ uri: '/v2/services', method: 'post'})).and_yield(FakeCCHttp.new(error: nil, status: 201, response: {"metadata" => {"guid" => "new_service_guid"}}.to_json))

          mock_http_handler.should_receive(:cc_http_request).with do |options|
            options[:uri].should == "/v2/service_plans"
            options[:method].should == "post"

            plan = service_in_catalog.plans.first
            Yajl::Parser.parse(options[:body]).should == plan.to_hash.merge("service_guid" => "new_service_guid")
          end

          advertiser.advertise_services
        end
      end
    end

    describe "#active_count" do
      context "when the advertiser is active" do
        it "returns the number of services in the catalog" do
          service_advertiser = ServiceAdvertiser.new(
            current_catalog: [double('catalog service1'), double('catalog service2')],
            catalog_in_ccdb: [double('ccdb service')],
            http_handler: double.as_null_object,
            logger: double.as_null_object,
            active: true,
          )

          service_advertiser.active_count.should == 2
        end
      end

      context "when the advertiser is inactive" do
        it "returns 0" do
          service_advertiser = ServiceAdvertiser.new(
            current_catalog: [double('catalog service1'), double('catalog service2')],
            catalog_in_ccdb: [double('ccdb service')],
            http_handler: double.as_null_object,
            logger: double.as_null_object,
            active: false,
          )

          service_advertiser.active_count.should == 0
        end
      end
    end

    describe "#disabled_count" do
      let(:service_in_cc_and_catalog) { double('service in both', :guid => 'service guid', "guid=" => nil) }

      context "when the advertiser is active" do
        it "returns the number of services that are in cc that are not in the catalog" do
          service_advertiser = ServiceAdvertiser.new(
            current_catalog: [double('catalog service1'), double('catalog service2'), service_in_cc_and_catalog],
            catalog_in_ccdb: [double('inactive ccdb service'), service_in_cc_and_catalog],
            http_handler: double.as_null_object,
            logger: double.as_null_object,
            active: true,
          )

          service_advertiser.disabled_count.should == 1
        end
      end

      context "when the advertiser is inactive" do
        it "returns the number of services in cloud controller" do
          service_advertiser = ServiceAdvertiser.new(
            current_catalog: [double('catalog service1'), service_in_cc_and_catalog],
            catalog_in_ccdb: [double('inactive ccdb service1'), double('inactive ccdb service2'), service_in_cc_and_catalog],
            http_handler: service_in_cc_and_catalog.as_null_object,
            logger: service_in_cc_and_catalog.as_null_object,
            active: false,
          )

          service_advertiser.disabled_count.should == 3
        end
      end
    end
  end
end
