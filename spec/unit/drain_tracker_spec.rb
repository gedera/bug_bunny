# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BugBunny::DrainTracker do
  # Reloj controlado por el test: el tiempo avanza sólo cuando el spec lo mueve.
  let(:current_time) { [100.0] }
  let(:tracker) { described_class.new(clock: -> { current_time.first }) }

  def advance(seconds)
    current_time[0] += seconds
  end

  it 'no está ocioso mientras una entrega sigue en proceso, aunque venza la ventana' do
    tracker.track do
      advance(10)
      expect(tracker.idle?(5)).to be(false)
    end
  end

  it 'queda ocioso recién cuando pasa la ventana completa desde la última entrega' do
    tracker.track { advance(1) }

    advance(4.9)
    expect(tracker.idle?(5)).to be(false)

    advance(0.1)
    expect(tracker.idle?(5)).to be(true)
  end

  it 'cuenta la entrega como procesada y la libera aunque el procesamiento levante' do
    expect { tracker.track { raise 'boom' } }.to raise_error('boom')

    expect(tracker.processed).to eq(1)
    expect(tracker.busy?).to be(false)
  end
end
