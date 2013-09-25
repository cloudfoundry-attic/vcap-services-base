require 'helper/spec_helper'
require 'api/message'

describe ServiceMessage do
  class TestMessage < ServiceMessage
    required :i_am_needed, String
    optional :dont_really_need_me, String
  end

  describe '.new' do
    it 'allows nil optional fields' do
      expect {
        TestMessage.new(
          'i_am_needed' => 'here',
          'dont_really_need_me' => nil,
        )
      }.not_to raise_error
    end
  end

  describe 'field writer' do
    context 'when updating a field to a nil value' do
      let(:message) { TestMessage.new(i_am_needed: 'here', dont_really_need_me: 'optional') }

      it 'removes the key from the message body' do
        expect {
          message.dont_really_need_me = nil
        }.to change { message.extract.has_key?(:dont_really_need_me) }.to(false)
      end
    end
  end

  describe '.from_decoded_json' do
    it 'accepts required fields' do
      message = TestMessage.from_decoded_json('i_am_needed' => "here")
      message.i_am_needed.should == 'here'
    end

    it 'accepts optional fields' do
      message = TestMessage.from_decoded_json(
        'i_am_needed' => "here",
        'dont_really_need_me' => "also_here",
      )
      message.dont_really_need_me.should == 'also_here'
    end

    it 'errors when required fields are omitted' do
      expect {
        TestMessage.from_decoded_json('dont_really_need_me' => "also_here")
      }.to raise_error(JsonMessage::ValidationError)
    end

    it 'ignores unknown fields' do
      message = TestMessage.from_decoded_json(
        'i_am_needed' => 'here',
        'you_dont_know' => 'me'
      )
      message.i_am_needed.should == 'here'
    end
  end
end
