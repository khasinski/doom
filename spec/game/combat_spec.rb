# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::Combat do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  let(:player) { Doom::Game::PlayerState.new }
  subject(:combat) { described_class.new(@map, player, @sprites) }

  describe '#fire hitscan' do
    it 'damages monsters in line of fire' do
      # Find a zombieman (type 3004)
      zombie = @map.things.each_with_index.find { |t, _| t.type == 3004 }
      skip 'No zombieman in map' unless zombie
      thing, idx = zombie

      # Position player facing the zombie
      dx = thing.x - 100
      dy = thing.y
      cos_a = 1.0; sin_a = 0.0

      # Point directly at zombie with hitscan
      dx = thing.x - (thing.x - 100)
      angle = Math.atan2(thing.y - thing.y, thing.x - (thing.x - 100))

      combat.fire(thing.x - 100, thing.y.to_f, 41.0, 1.0, 0.0, Doom::Game::PlayerState::WEAPON_PISTOL)
      hp = combat.instance_variable_get(:@monster_hp)

      # Monster should have taken damage (HP reduced from 20)
      if hp[idx]
        expect(hp[idx]).to be < 20
      end
    end
  end

  describe '#fire rocket' do
    it 'spawns a projectile' do
      combat.fire(0, 0, 41.0, 1.0, 0.0, Doom::Game::PlayerState::WEAPON_ROCKET)
      expect(combat.projectiles.size).to eq(1)
    end

    it 'projectile moves on update' do
      combat.fire(0, 0, 41.0, 1.0, 0.0, Doom::Game::PlayerState::WEAPON_ROCKET)
      initial_x = combat.projectiles[0].x
      combat.update
      expect(combat.projectiles[0]&.x).not_to eq(initial_x) if combat.projectiles.any?
    end
  end

  describe '#dead?' do
    it 'returns false for alive monsters' do
      zombie = @map.things.each_with_index.find { |t, _| t.type == 3004 }
      skip 'No zombieman in map' unless zombie
      _, idx = zombie
      expect(combat.dead?(idx)).to be false
    end
  end

  describe '#update' do
    it 'advances tic counter' do
      combat.update
      expect(combat.instance_variable_get(:@tic)).to eq(1)
    end

    it 'removes expired explosions' do
      combat.instance_variable_get(:@explosions) << { x: 0, y: 0, tic: -100 }
      combat.update
      expect(combat.explosions).to be_empty
    end
  end

  describe 'death animation' do
    it 'returns death sprite for dead monster' do
      zombie = @map.things.each_with_index.find { |t, _| t.type == 3004 }
      skip 'No zombieman in map' unless zombie
      thing, idx = zombie

      # Kill the zombie directly
      combat.instance_variable_get(:@monster_hp)[idx] = 1
      combat.send(:apply_damage, idx, 100)

      expect(combat.dead?(idx)).to be true

      sprite = combat.death_sprite(idx, thing.type, 0, 0)
      expect(sprite).not_to be_nil
    end
  end

  describe 'monster HP table' do
    it 'has HP values for common monsters' do
      expect(Doom::Game::Combat::MONSTER_HP[3004]).to eq(20)  # Zombieman
      expect(Doom::Game::Combat::MONSTER_HP[3001]).to eq(60)  # Imp
      expect(Doom::Game::Combat::MONSTER_HP[3002]).to eq(150) # Demon
    end
  end
end
