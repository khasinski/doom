# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Game::Random do
  describe 'table fidelity' do
    it 'has exactly 256 entries, all bytes' do
      expect(described_class::RNDTABLE.size).to eq(256)
      expect(described_class::RNDTABLE).to all(be_between(0, 255))
    end

    it 'reproduces the first draws of DOOM P_Random from index 0' do
      # P_Random increments before reading, so from index 0 the first value is
      # rndtable[1] == 8.
      rng = described_class.new(0)
      expect(Array.new(5) { rng.byte }).to eq([8, 109, 220, 222, 241])
    end

    it 'wraps the index at 256' do
      rng = described_class.new(255)
      expect(rng.byte).to eq(described_class::RNDTABLE[0])
      expect(rng.index).to eq(0)
    end
  end

  describe 'determinism' do
    it 'gives identical sequences for the same seed' do
      a = described_class.new(42)
      b = described_class.new(42)
      expect(Array.new(600) { a.rand(256) }).to eq(Array.new(600) { b.rand(256) })
    end

    it 'diverges for different seeds' do
      a = Array.new(50) { described_class.new(1).byte }
      b = Array.new(50) { described_class.new(2).byte }
      expect(a).not_to eq(b)
    end

    it 'restores a sequence from a saved index' do
      rng = described_class.new(0)
      10.times { rng.byte }
      saved = rng.index
      expected = Array.new(10) { rng.byte }

      rng.index = saved
      expect(Array.new(10) { rng.byte }).to eq(expected)
    end
  end

  describe '#rand compatibility with Kernel#rand shapes' do
    let(:rng) { described_class.new(0) }

    it 'returns a float in [0,1) with no argument' do
      values = Array.new(300) { rng.rand }
      expect(values).to all(be >= 0.0)
      expect(values).to all(be < 1.0)
    end

    it 'returns 0...n for an integer argument' do
      expect(Array.new(300) { rng.rand(8) }).to all(be_between(0, 7))
    end

    it 'returns a..b inclusive for a range argument' do
      expect(Array.new(300) { rng.rand(3..7) }).to all(be_between(3, 7))
    end

    it 'handles exclusive ranges' do
      expect(Array.new(300) { rng.rand(3...7) }).to all(be_between(3, 6))
    end

    it 'covers the whole range given enough draws' do
      expect(Array.new(600) { rng.rand(1..6) }.uniq.sort).to eq([1, 2, 3, 4, 5, 6])
    end

    it 'does not raise on degenerate arguments' do
      expect(rng.rand(0)).to eq(0)
      expect(rng.rand(5..5)).to eq(5)
    end
  end

  describe '#diff' do
    it 'stays within -255..255' do
      rng = described_class.new(0)
      expect(Array.new(300) { rng.diff }).to all(be_between(-255, 255))
    end
  end
end
