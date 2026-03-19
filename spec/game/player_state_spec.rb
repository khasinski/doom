# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::PlayerState do
  subject(:player) { described_class.new }

  describe '#reset' do
    it 'starts with 100 health' do
      expect(player.health).to eq(100)
    end

    it 'starts with 0 armor' do
      expect(player.armor).to eq(0)
    end

    it 'starts with pistol and fist' do
      expect(player.has_weapons[0]).to be true  # fist
      expect(player.has_weapons[1]).to be true  # pistol
      expect(player.has_weapons[2]).to be false # shotgun
    end

    it 'starts with 50 bullets' do
      expect(player.ammo_bullets).to eq(50)
    end

    it 'starts with viewheight at 41' do
      expect(player.viewheight).to eq(41.0)
    end
  end

  describe '#switch_weapon' do
    it 'switches to owned weapons' do
      player.switch_weapon(0)
      expect(player.weapon).to eq(0)
    end

    it 'does not switch to unowned weapons' do
      player.switch_weapon(2) # shotgun not owned
      expect(player.weapon).to eq(1) # stays on pistol
    end

    it 'does not switch while attacking' do
      player.start_attack
      player.switch_weapon(0)
      expect(player.weapon).to eq(1)
    end
  end

  describe '#start_attack' do
    it 'begins attack with ammo' do
      player.start_attack
      expect(player.attacking).to be true
    end

    it 'consumes ammo' do
      initial = player.ammo_bullets
      player.start_attack
      expect(player.ammo_bullets).to eq(initial - 1)
    end

    it 'does not attack without ammo' do
      player.ammo_bullets = 0
      player.start_attack
      expect(player.attacking).to be false
    end

    it 'fist attacks without ammo' do
      player.weapon = 0
      player.ammo_bullets = 0
      player.start_attack
      expect(player.attacking).to be true
    end
  end

  describe '#update_attack' do
    it 'advances attack tics' do
      player.start_attack
      player.update_attack
      expect(player.attack_tics).to eq(1)
    end

    it 'ends attack after duration' do
      player.start_attack
      20.times { player.update_attack }
      expect(player.attacking).to be false
    end
  end

  describe '#notify_step' do
    it 'reduces viewheight for step up' do
      player.notify_step(8)
      expect(player.viewheight).to eq(33.0)
    end

    it 'increases viewheight for step down' do
      player.notify_step(-8)
      expect(player.viewheight).to eq(49.0)
    end

    it 'sets deltaviewheight for recovery' do
      player.notify_step(16)
      expect(player.deltaviewheight).to eq(2.0) # (41 - 25) / 8
    end
  end

  describe '#update_viewheight' do
    it 'recovers viewheight toward 41 after step up' do
      player.notify_step(16) # viewheight = 25
      10.times { player.update_viewheight }
      expect(player.viewheight).to be > 25.0
      expect(player.viewheight).to be <= 41.0
    end

    it 'recovers viewheight toward 41 after step down' do
      player.notify_step(-16) # viewheight = 57
      20.times { player.update_viewheight }
      expect(player.viewheight).to be < 57.0
    end

    it 'fully recovers to 41' do
      player.notify_step(16)
      50.times { player.update_viewheight }
      expect(player.viewheight).to eq(41.0)
    end
  end

  describe '#update_view_bob' do
    it 'produces zero bob with no momentum' do
      player.set_movement_momentum(0, 0)
      player.update_view_bob(0.016)
      expect(player.view_bob_offset).to eq(0.0)
    end

    it 'produces non-zero bob with momentum' do
      player.set_movement_momentum(200, 0)
      player.update_view_bob(0.016)
      expect(player.view_bob_offset).not_to eq(0.0)
    end

    it 'caps bob at MAXBOB' do
      player.set_movement_momentum(99999, 0)
      # Run several frames to get past zero-crossing
      10.times { player.update_view_bob(0.016) }
      expect(player.view_bob_offset.abs).to be <= 8.0 # MAXBOB/2
    end
  end

  describe '#health_level' do
    it 'returns 4 for full health' do
      player.health = 100
      expect(player.health_level).to eq(4)
    end

    it 'returns 0 for low health' do
      player.health = 10
      expect(player.health_level).to eq(0)
    end
  end
end
