# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::RemoteError do
  subject(:error) do
    described_class.new('TypeError', 'nil can\'t be coerced into Integer', [
                          "/app/controllers/services_controller.rb:5:in 'Integer#*'",
                          "/app/controllers/services_controller.rb:5:in 'ServicesController#index'"
                        ])
  end

  describe '#to_s' do
    it 'does not cause infinite recursion (message -> to_s -> message)' do
      expect(error.to_s).to eq("BugBunny::RemoteError(TypeError): nil can't be coerced into Integer")
    end
  end

  describe '#message' do
    it 'returns the formatted string without stack overflow' do
      expect(error.message).to eq("BugBunny::RemoteError(TypeError): nil can't be coerced into Integer")
    end
  end

  describe '#inspect' do
    it 'is renderable by IRB without raising' do
      expect { error.inspect }.not_to raise_error
    end
  end

  describe '.serialize' do
    it 'serializes an exception with class, message and backtrace' do
      exception = TypeError.new('test error')
      exception.set_backtrace(%w[line1 line2])

      result = described_class.serialize(exception)

      expect(result).to eq(class: 'TypeError', message: 'test error', backtrace: %w[line1 line2])
    end

    it 'truncates backtrace to max_lines' do
      exception = TypeError.new('test')
      exception.set_backtrace(Array.new(30) { |i| "line#{i}" })

      result = described_class.serialize(exception, max_lines: 5)

      expect(result[:backtrace].size).to eq(5)
    end
  end

  describe 'attributes' do
    it 'exposes the original exception class' do
      expect(error.original_class).to eq('TypeError')
    end

    it 'exposes the original message' do
      expect(error.original_message).to eq("nil can't be coerced into Integer")
    end

    it 'exposes the original backtrace' do
      expect(error.original_backtrace.size).to eq(2)
    end

    it 'sets the Ruby backtrace to the remote backtrace' do
      expect(error.backtrace).to eq(error.original_backtrace)
    end
  end
end
