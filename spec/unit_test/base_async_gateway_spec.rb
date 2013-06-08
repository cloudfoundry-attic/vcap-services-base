require 'helper/spec_helper'

describe "Base" do
  include Rack::Test::Methods

  class AsyncGw < VCAP::Services::BaseAsynchronousServiceGateway
    get "/" do

    end

    get "/error" do
      raise "Oh noes!"
    end
  end

  def app
    AsyncGw.new({})
  end

  it "notifies of exceptions" do
    Cf::ExceptionNotifier.should_receive(:notify).with(an_instance_of RuntimeError)
    get "/error"
    last_response.should_not be_ok
  end

  it "sets up exception notification" do
    ex_opts = {:squash => "opts"}
    Cf::ExceptionNotifier.should_receive(:setup).with(ex_opts)
    AsyncGw.new({:exception_notifier => ex_opts})
  end
end
