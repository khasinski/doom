# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/doom/wad/hud_graphics'
require_relative '../../lib/doom/game/intermission'

# Intermission is wired into real gameplay (the window shows it between levels)
# but had no coverage. The logic worth pinning is the stat math: percentages,
# the zero-total guard, time conversion, and the map/par lookups.
RSpec.describe Doom::Game::Intermission do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @gfx = Doom::Wad::HudGraphics.new(@wad)
  end

  after(:all) { @wad&.close }

  def stats(over)
    { map: 'E1M1', kills: 0, total_kills: 0, items: 0, total_items: 0,
      secrets: 0, total_secrets: 0, time_tics: 0 }.merge(over)
  end

  def build(over = {})
    described_class.new(nil, @gfx, stats(over))
  end

  def pct(inter, which)
    inter.instance_variable_get(:"@#{which}_pct")
  end

  describe 'percentages' do
    it 'computes kill/item/secret percentages from the totals' do
      inter = build(kills: 3, total_kills: 4, items: 1, total_items: 2,
                    secrets: 1, total_secrets: 5)
      expect(pct(inter, :kill)).to eq(75)
      expect(pct(inter, :item)).to eq(50)
      expect(pct(inter, :secret)).to eq(20)
    end

    it 'reports 100% when a category has no total, not a divide-by-zero' do
      inter = build(kills: 0, total_kills: 0, items: 0, total_items: 0,
                    secrets: 0, total_secrets: 0)
      expect(pct(inter, :kill)).to eq(100)
      expect(pct(inter, :item)).to eq(100)
      expect(pct(inter, :secret)).to eq(100)
    end

    it 'floors a partial ratio rather than rounding up' do
      inter = build(kills: 1, total_kills: 3) # 33.3%
      expect(pct(inter, :kill)).to eq(33)
    end
  end

  describe 'time' do
    it 'converts tics to seconds at 35 Hz' do
      expect(build(time_tics: 35 * 90).instance_variable_get(:@time_secs)).to eq(90)
    end
  end

  describe 'map lookups' do
    it 'knows the par time for a stock map' do
      expect(build(map: 'E1M1').instance_variable_get(:@par_time))
        .to eq(described_class::PAR_TIMES['E1M1'])
    end

    it 'falls back to 0 par for an unknown map' do
      expect(build(map: 'E9M9').instance_variable_get(:@par_time)).to eq(0)
    end

    it 'points at the next map in the episode' do
      expect(build(map: 'E1M1').instance_variable_get(:@next_map))
        .to eq(described_class::NEXT_MAP['E1M1'])
    end

    it 'maps a map name to its level index' do
      expect(build.send(:map_to_level_index, 'E1M3')).to eq(2)
    end
  end
end
