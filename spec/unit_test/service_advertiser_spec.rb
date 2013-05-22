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

    def build_service(guid, unique_id)
      Service.new(
        'guid' => guid,
        'unique_id' => unique_id,
        'provider' => nil,
        'version' => nil,
        'url' => nil,
        'extra' => nil,
        'plans' => []
      )
    end

    it 'sets the guids for services in the catalog that exist in CC' do
      guid_1 = 'guid_1'
      unique_id_1 = 'unique_id_1'
      unique_id_2 = 'unique_id_2'
      catalog = double('gateway service catalog',
                       services: [ build_service(nil, unique_id_1), build_service(nil, unique_id_2) ]
                      )
      registered_services = [ build_service(guid_1, unique_id_1) ]
      advertiser = ServiceAdvertiser.new(
        current_catalog: catalog,
        catalog_in_ccdb: registered_services,
        logger: logger,
        http_handler: http_handler
      )
      service_1 = advertiser.catalog_services.detect {|s| s.unique_id == unique_id_1 }
      service_1.guid.should == guid_1

      service_2 = advertiser.catalog_services.detect {|s| s.unique_id == unique_id_2 }
      service_2.guid.should be_nil
    end
  end
end
