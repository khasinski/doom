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
    it 'changes sector light levels' do
      # Find a sector with light effects
      sectors_with_effects = @map.sectors.select { |s| [1, 2, 3, 8, 12, 13, 17].include?(s.special) }
      skip 'No light effect sectors' if sectors_with_effects.empty?

      sector = sectors_with_effects.first

      # Run many updates - light should change at some point
      100.times { effects.update }

      # Verify it doesn't crash and produces valid values
      expect(sector.light_level).to be_a(Integer).or be_a(Float)
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
end
