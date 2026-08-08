# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/doom/game/sound_engine'

# The one branch in SoundEngine worth pinning is the throttle: without it,
# rapid repeats (a chaingun, a monster horde) would retrigger a sample every
# tic. Everything else is a static name->sample dispatch.
RSpec.describe Doom::Game::SoundEngine do
  # A fake sound bank: indexing by name returns a sample that records plays.
  class FakeSample
    attr_reader :plays

    def initialize = @plays = 0
    def play(_volume) = @plays += 1
  end

  class FakeBank
    def initialize = @samples = Hash.new { |h, k| h[k] = FakeSample.new }
    def [](name) = @samples[name]
    def sample(name) = @samples[name]
  end

  let(:bank) { FakeBank.new }
  subject(:engine) { described_class.new(bank) }

  it 'plays a sample the first time' do
    engine.play('DSPISTOL')
    expect(bank.sample('DSPISTOL').plays).to eq(1)
  end

  it 'suppresses a repeat inside the throttle window' do
    engine.play('DSPISTOL', throttle: 100) # 100s window; the repeat is immediate
    engine.play('DSPISTOL', throttle: 100)
    expect(bank.sample('DSPISTOL').plays).to eq(1)
  end

  it 'does not throttle when throttle is zero' do
    3.times { engine.play('DSPISTOL', throttle: 0) }
    expect(bank.sample('DSPISTOL').plays).to eq(3)
  end

  it 'throttles each sound name independently' do
    engine.play('DSPISTOL', throttle: 100)
    engine.play('DSSHOTGN', throttle: 100)
    expect(bank.sample('DSPISTOL').plays).to eq(1)
    expect(bank.sample('DSSHOTGN').plays).to eq(1)
  end

  it 'does not raise when a sample is missing' do
    empty = Class.new { def [](_name) = nil }.new
    expect { described_class.new(empty).play('NOPE') }.not_to raise_error
  end
end
