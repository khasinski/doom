# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::ItemPickup do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
  end

  after(:all) { @wad&.close }

  let(:player) { Doom::Game::PlayerState.new }
  subject(:pickup) { described_class.new(@map, player) }

  describe '#update' do
    it 'picks up health bonus when player is near' do
      # Find a health bonus (type 2014) in the map
      bonus = @map.things.each_with_index.find { |t, _| t.type == 2014 }
      skip 'No health bonus in map' unless bonus
      thing, idx = bonus

      player.health = 99
      pickup.update(thing.x.to_f, thing.y.to_f)

      expect(player.health).to eq(100)
      expect(pickup.picked_up[idx]).to be true
    end

    it 'does not pick up items when too far' do
      initial_health = player.health
      pickup.update(-99999, -99999)
      expect(player.health).to eq(initial_health)
    end

    it 'does not pick up same item twice' do
      bonus = @map.things.each_with_index.find { |t, _| t.type == 2014 }
      skip 'No health bonus in map' unless bonus
      thing, _ = bonus

      player.health = 98
      pickup.update(thing.x.to_f, thing.y.to_f)
      pickup.update(thing.x.to_f, thing.y.to_f)
      expect(player.health).to eq(99) # only +1, not +2
    end
  end

  describe 'weapon pickup' do
    it 'gives weapon and ammo' do
      shotgun = @map.things.each_with_index.find { |t, _| t.type == 2001 }
      skip 'No shotgun in map' unless shotgun
      thing, _ = shotgun

      expect(player.has_weapons[2]).to be false
      pickup.update(thing.x.to_f, thing.y.to_f)
      expect(player.has_weapons[2]).to be true
      expect(player.ammo_shells).to be > 0
    end
  end

  describe 'armor pickup' do
    it 'picks up armor bonus' do
      bonus = @map.things.each_with_index.find { |t, _| t.type == 2015 }
      skip 'No armor bonus in map' unless bonus
      thing, _ = bonus

      pickup.update(thing.x.to_f, thing.y.to_f)
      expect(player.armor).to eq(1)
    end

    it 'does not pick up green armor when already better' do
      player.armor = 150
      ga = @map.things.each_with_index.find { |t, _| t.type == 2018 }
      skip 'No green armor in map' unless ga
      thing, _ = ga

      pickup.update(thing.x.to_f, thing.y.to_f)
      expect(player.armor).to eq(150) # unchanged
    end
  end
end
