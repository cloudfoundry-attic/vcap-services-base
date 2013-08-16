require 'helper/spec_helper'

module VCAP::Services::Base::Error
  describe ServiceError do
    describe '#to_hash' do
      it 'includes code, description, backtrace, and types' do
        service_error = ServiceError.new(ServiceError::INTERNAL_ERROR)
        service_error.set_backtrace(['/foo.rb:12', '/bar.rb:34'])

        error_hash = service_error.to_hash.fetch('msg')

        error_hash.fetch('code').should == service_error.error_code
        error_hash.fetch('description').should == service_error.error_msg
        error_hash.fetch('error').fetch('backtrace').should == ['/foo.rb:12', '/bar.rb:34']
        error_hash.fetch('error').fetch('types').should == service_error.class.ancestors.map(&:name) - Object.ancestors.map(&:name)
      end
    end
  end
end
