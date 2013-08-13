require 'helper/spec_helper'
require 'lib/base/base_async_gateway'

describe VCAP::Services::BaseAsynchronousServiceGateway do
  include Rack::Test::Methods

  around do |example|
    begin
      original_config = Steno.config
      example.run
    ensure
      Steno.init(original_config)
    end
  end

  def app
    Class.new(VCAP::Services::BaseAsynchronousServiceGateway) do
      get '/' do
        200
      end
    end.new({})
  end

  it "includes the CloudController request ID in the Steno context" do
    Steno.init(Steno::Config.new(context: Steno::Context::ThreadLocal.new))
    get '/', {}, {'HTTP_X_VCAP_REQUEST_ID' => 'deadbeef'}
    Steno.config.context.data.fetch("request_guid").should == 'deadbeef'
  end
end
