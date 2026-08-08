# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::SectorEffects do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
  end

  after(:all) { @wad&.close }

  subject(:effects) { described_class.new(@map) }

  # A self-contained two-sector map: a flickering sector (special 1) next to a
  # darker neighbour, so find_min_light has a real lower bound to flicker to.
  # Built fresh per run so determinism comparisons don't fight over shared
  # sector state loaded from the WAD.
  def flicker_map(special: 1)
    bright = Doom::Map::Sector.new(0, 128, 'F', 'C', 255, special, 0)
    dark   = Doom::Map::Sector.new(0, 128, 'F', 'C', 100, 0, 0)
    sidedefs = [
      Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 0),  # front -> bright
      Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 1),  # back  -> dark
    ]
    linedefs = [Doom::Map::Linedef.new(0, 1, 0x0004, 0, 0, 0, 1)]  # TWOSIDED
    map = Object.new
    map.define_singleton_method(:sectors) { [bright, dark] }
    map.define_singleton_method(:sidedefs) { sidedefs }
    map.define_singleton_method(:linedefs) { linedefs }
    map
  end

  # Run the flicker for `tics` and return the bright sector's light each tic.
  def light_sequence(seed, tics: 200)
    map = flicker_map
    fx = described_class.new(map, random: Doom::Game::Random.new(seed))
    sector = map.sectors.first
    Array.new(tics) { fx.update; sector.light_level }
  end

  describe '#initialize' do
    it 'finds light effects in E1M1' do
      effect_list = effects.instance_variable_get(:@effects)
      expect(effect_list.size).to be > 0
    end

    it 'finds scrolling walls in E1M1' do
      scroll_list = effects.instance_variable_get(:@scroll_sides)
      expect(scroll_list.size).to eq(8)
    end
  end

  describe '#update' do
    it 'actually varies a flickering sector light over time' do
      levels = light_sequence(1)
      # A flickering sector must swing between its bright and dark levels,
      # not sit at a single value across the whole run.
      expect(levels.min).not_to eq(levels.max)
      expect(levels).to include(255)  # reaches its bright (max) level
      expect(levels.min).to be < 255  # and drops below it
    end

    it 'scrolls wall textures' do
      scroll_sides = effects.instance_variable_get(:@scroll_sides)
      skip 'No scrolling walls' if scroll_sides.empty?

      side = scroll_sides.first
      initial_offset = side.x_offset
      effects.update
      expect(side.x_offset).to eq(initial_offset + 1)
    end
  end

  # Lockstep multiplayer needs flicker to be reproducible: peers running the
  # same seed must observe identical light levels every tic.
  describe 'deterministic RNG' do
    it 'produces identical light sequences for the same seed' do
      expect(light_sequence(7)).to eq(light_sequence(7))
    end

    it 'produces different light sequences for different seeds' do
      expect(light_sequence(7)).not_to eq(light_sequence(99))
    end
  end
end
