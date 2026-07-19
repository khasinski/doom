# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::Ticcmd do
  describe '.none' do
    it 'is a fully neutral command' do
      cmd = described_class.none
      expect(cmd.forwardmove).to eq(0.0)
      expect(cmd.sidemove).to eq(0.0)
      expect(cmd.angleturn).to eq(0.0)
      expect(cmd).not_to be_fire
      expect(cmd).not_to be_use
      expect(cmd).not_to be_moving
    end
  end

  describe 'button predicates' do
    it 'reads fire and use independently' do
      both = described_class.new(0, 0, 0, described_class::BTN_FIRE | described_class::BTN_USE)
      expect(both).to be_fire
      expect(both).to be_use

      fire_only = described_class.new(0, 0, 0, described_class::BTN_FIRE)
      expect(fire_only).to be_fire
      expect(fire_only).not_to be_use
    end
  end

  describe '#moving?' do
    it 'is true for forward or side motion but not for turning alone' do
      expect(described_class.new(1.0, 0, 0, 0)).to be_moving
      expect(described_class.new(0, -1.0, 0, 0)).to be_moving
      expect(described_class.new(0, 0, 5.0, 0)).not_to be_moving
    end
  end

  describe 'wire format' do
    it 'packs to a fixed small size' do
      packed = described_class.new(1.0, -1.0, 3.0, 3).pack
      expect(packed.bytesize).to eq(described_class::PACKED_SIZE)
    end

    it 'round-trips a command within quantisation error' do
      cmd = described_class.new(1.0, -1.0, 2.5, described_class::BTN_FIRE)
      back = described_class.unpack(cmd.pack)

      expect(back.forwardmove).to be_within(1e-3).of(1.0)
      expect(back.sidemove).to be_within(1e-3).of(-1.0)
      expect(back.angleturn).to be_within(1e-2).of(2.5)
      expect(back.buttons).to eq(described_class::BTN_FIRE)
    end

    it 'round-trips a neutral command exactly' do
      back = described_class.unpack(described_class.none.pack)
      expect([back.forwardmove, back.sidemove, back.angleturn, back.buttons]).to eq([0.0, 0.0, 0.0, 0])
    end

    it 'packs identically for equal commands on any peer' do
      a = described_class.new(0.5, -0.25, 1.75, 1)
      b = described_class.new(0.5, -0.25, 1.75, 1)
      expect(a.pack).to eq(b.pack)
    end

    it 'survives a large accumulated mouse turn' do
      back = described_class.unpack(described_class.new(0, 0, 180.0, 0).pack)
      expect(back.angleturn).to be_within(1e-2).of(180.0)
    end

    it 'clamps absurd values instead of raising' do
      expect { described_class.new(0, 0, 100_000.0, 0).pack }.not_to raise_error
    end
  end
end
