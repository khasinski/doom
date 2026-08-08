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
  # ItemPickup takes a player entity now; reuse one actor so it keeps identity
  # while moving, and share the PlayerState the assertions read.
  let(:actor) { Doom::Game::Player.new(state: player) }
  subject(:pickup) { described_class.new(@map) }

  def at(x, y, z = 41.0)
    actor.place(x, y, z, 0)
    actor
  end

  describe '#update' do
    it 'picks up health bonus when player is near' do
      # Find a health bonus (type 2014) in the map
      bonus = @map.things.each_with_index.find { |t, _| t.type == 2014 }
      skip 'No health bonus in map' unless bonus
      thing, idx = bonus

      player.health = 99
      pickup.update(at(thing.x.to_f, thing.y.to_f))

      expect(player.health).to eq(100)
      expect(pickup.picked_up[idx]).to be true
    end

    it 'does not pick up items when too far' do
      initial_health = player.health
      pickup.update(at(-99999, -99999))
      expect(player.health).to eq(initial_health)
    end

    it 'does not pick up same item twice' do
      bonus = @map.things.each_with_index.find { |t, _| t.type == 2014 }
      skip 'No health bonus in map' unless bonus
      thing, _ = bonus

      player.health = 98
      pickup.update(at(thing.x.to_f, thing.y.to_f))
      pickup.update(at(thing.x.to_f, thing.y.to_f))
      expect(player.health).to eq(99) # only +1, not +2
    end
  end

  describe 'weapon pickup' do
    it 'gives weapon and ammo' do
      shotgun = @map.things.each_with_index.find { |t, _| t.type == 2001 }
      skip 'No shotgun in map' unless shotgun
      thing, _ = shotgun

      expect(player.has_weapons[2]).to be false
      pickup.update(at(thing.x.to_f, thing.y.to_f))
      expect(player.has_weapons[2]).to be true
      expect(player.ammo_shells).to be > 0
    end
  end

  describe 'armor pickup' do
    it 'picks up armor bonus' do
      bonus = @map.things.each_with_index.find { |t, _| t.type == 2015 }
      skip 'No armor bonus in map' unless bonus
      thing, _ = bonus

      pickup.update(at(thing.x.to_f, thing.y.to_f))
      expect(player.armor).to eq(1)
    end

    it 'does not pick up green armor when already better' do
      player.armor = 150
      ga = @map.things.each_with_index.find { |t, _| t.type == 2018 }
      skip 'No green armor in map' unless ga
      thing, _ = ga

      pickup.update(at(thing.x.to_f, thing.y.to_f))
      expect(player.armor).to eq(150) # unchanged
    end

    # Blue (mega) armor upgrades even over full green armor, unlike green, which
    # only replaces a weaker set. Driven through the pickup branch directly so it
    # does not depend on a blue armor being placed in E1M1.
    it 'picks up blue armor over existing green armor' do
      player.armor = 100
      taken = pickup.send(:give_armor, { armor_type: 2, amount: 200 }, player)
      expect(taken).to be true
      expect(player.armor).to eq(200)
    end
  end

  describe 'backpack pickup' do
    it 'doubles max ammo and grants some of each type' do
      expect(player.max_bullets).to eq(200)

      taken = pickup.send(:give_backpack, player)

      expect(taken).to be true
      expect(player.max_bullets).to eq(400)
      expect(player.max_shells).to eq(100)
      expect(player.max_rockets).to eq(100)
      expect(player.max_cells).to eq(600)
      expect(player.ammo_bullets).to eq(60) # 50 at start + 10 from the pack
      expect(player.ammo_shells).to eq(4)
    end
  end

  describe 'key pickup' do
    it 'grants a key not yet held' do
      expect(pickup.send(:give_key, :blue_card, player)).to be true
      expect(player.keys[:blue_card]).to be true
    end

    it 'is not re-picked when already held' do
      player.keys[:blue_card] = true
      expect(pickup.send(:give_key, :blue_card, player)).to be false
    end
  end
end
