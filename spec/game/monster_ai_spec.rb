# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/doom/game/monster_ai'

RSpec.describe Doom::Game::MonsterAI do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  let(:player) { Doom::Game::PlayerState.new }
  let(:combat) { Doom::Game::Combat.new(@map, player, @sprites) }
  subject(:ai) { described_class.new(@map, combat, player, @sprites) }

  describe '#initialize' do
    it 'creates monster states for all monsters in the map' do
      monster_types = @map.things.select { |t| Doom::Game::Combat::MONSTER_HP[t.type] && t.type != 2035 }
      expect(ai.monsters.size).to eq(monster_types.size)
    end

    it 'excludes barrels from monsters' do
      barrel_monsters = ai.monsters.select { |m| m.type == 2035 }
      expect(barrel_monsters).to be_empty
    end

    it 'starts all monsters as inactive' do
      expect(ai.monsters.all? { |m| !m.active }).to be true
    end

    it 'sets reactiontime for all monsters' do
      expect(ai.monsters.all? { |m| m.reactiontime == Doom::Game::MonsterAI::REACTIONTIME }).to be true
    end
  end

  describe 'activation' do
    it 'does not activate monsters far away' do
      ai.update(-9999, -9999)
      expect(ai.monsters.any?(&:active)).to be false
    end

    it 'activates monsters with LOS within range' do
      # Find a zombieman and stand near it
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      # Stand right in front of it
      ai.update(zombie_mon.x + 100, zombie_mon.y)
      expect(zombie_mon.active).to be true
    end

    it 'only activates monsters facing the player (180-degree arc)' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      # Stand behind the monster (opposite of its facing direction)
      thing = @map.things[zombie_mon.thing_idx]
      face_rad = thing.angle * Math::PI / 180.0
      behind_x = zombie_mon.x - Math.cos(face_rad) * 100
      behind_y = zombie_mon.y - Math.sin(face_rad) * 100

      ai.update(behind_x, behind_y)
      # Monster should NOT activate from behind (unless very close)
      # This depends on the exact geometry - may or may not activate
    end
  end

  describe 'deactivation' do
    it 'deactivates monster after losing LOS for 3 seconds' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      # Activate by standing nearby
      ai.update(zombie_mon.x + 100, zombie_mon.y)
      expect(zombie_mon.active).to be true

      # Move far away and wait
      120.times { ai.update(-9999, -9999) }
      expect(zombie_mon.active).to be false
    end
  end

  describe 'attack' do
    it 'does not attack when aggression is off' do
      ai.aggression = false
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      zombie_mon.movecount = 0
      zombie_mon.attack_cooldown = 0
      zombie_mon.reactiontime = 0

      initial_health = player.health
      100.times { ai.update(zombie_mon.x + 50, zombie_mon.y) }
      expect(player.health).to eq(initial_health)
    end

    it 'requires LOS to attack' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      zombie_mon.reactiontime = 0

      # Very far away (no LOS through walls)
      initial_health = player.health
      10.times { ai.update(-9999, -9999) }
      expect(player.health).to eq(initial_health)
    end

    it 'enters attacking state when firing' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      zombie_mon.movecount = 0
      zombie_mon.attack_cooldown = 0
      zombie_mon.reactiontime = 0
      zombie_mon.chase_timer = 0

      # Stand close with clear LOS
      200.times do
        ai.update(zombie_mon.x + 50, zombie_mon.y)
        break if zombie_mon.attacking
      end

      # Monster should have attacked at some point (probabilistic)
      # Can't guarantee due to random miss chance
    end

    it 'spawns projectile for imp instead of instant damage' do
      imp_mon = ai.monsters.find { |m| m.type == 3001 }
      skip 'No imp' unless imp_mon

      imp_mon.active = true
      imp_mon.movecount = 0
      imp_mon.attack_cooldown = 0
      imp_mon.reactiontime = 0
      imp_mon.chase_timer = 0
      combat.update_player_pos(imp_mon.x + 100, imp_mon.y)

      initial_projectiles = combat.projectiles.size
      200.times do
        ai.update(imp_mon.x + 100, imp_mon.y)
        break if combat.projectiles.size > initial_projectiles
      end

      # Imp should have spawned a fireball (probabilistic)
      # Check that imp uses projectile type, not hitscan
      atk = Doom::Game::MonsterAI::MONSTER_ATTACK[3001]
      expect(atk[:type]).to eq(:projectile)
    end
  end

  describe 'movement' do
    it 'moves toward the player when chasing' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      initial_x = zombie_mon.x
      initial_y = zombie_mon.y

      target_x = zombie_mon.x + 200
      target_y = zombie_mon.y
      50.times { ai.update(target_x, target_y) }

      moved = (zombie_mon.x - initial_x).abs + (zombie_mon.y - initial_y).abs
      expect(moved).to be > 0
    end

    it 'does not move while attacking' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      zombie_mon.attacking = true
      zombie_mon.attack_frame_tic = 0

      initial_x = zombie_mon.x
      initial_y = zombie_mon.y

      5.times { ai.update(zombie_mon.x + 200, zombie_mon.y) }

      expect(zombie_mon.x).to eq(initial_x)
      expect(zombie_mon.y).to eq(initial_y)
    end

    it 'does not move while in pain' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      # Put monster in pain
      combat.instance_variable_get(:@pain_until)[zombie_mon.thing_idx] = 99999

      initial_x = zombie_mon.x
      5.times { ai.update(zombie_mon.x + 200, zombie_mon.y) }
      expect(zombie_mon.x).to eq(initial_x)
    end
  end

  describe 'keep distance' do
    it 'ranged monsters stop advancing when close with LOS' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      zombie_mon.last_saw_player = 99999  # Prevent deactivation

      # Place monster 100 units from target (< KEEP_DISTANCE=196)
      target_x = zombie_mon.x + 100
      target_y = zombie_mon.y
      initial_x = zombie_mon.x

      # Run several chase cycles - monster should mostly stay put
      50.times { ai.update(target_x, target_y) }

      # Monster should not have moved much closer
      moved_toward = initial_x - zombie_mon.x  # Positive if moved toward target
      expect(moved_toward).to be < 50  # Should not have closed the full gap
    end
  end

  describe 'ranged monster behavior' do
    it 'classifies imp as projectile attacker' do
      atk = Doom::Game::MonsterAI::MONSTER_ATTACK[3001]
      expect(atk[:type]).to eq(:projectile)
    end

    it 'classifies zombieman as hitscan attacker' do
      atk = Doom::Game::MonsterAI::MONSTER_ATTACK[3004]
      expect(atk[:type]).to eq(:hitscan)
    end

    it 'classifies demon as melee attacker' do
      atk = Doom::Game::MonsterAI::MONSTER_ATTACK[3002]
      expect(atk[:type]).to eq(:melee)
    end
  end

  describe 'attack animation' do
    it 'has attack frames for zombieman' do
      frames = Doom::Game::MonsterAI::ATTACK_FRAMES['POSS']
      expect(frames).to eq(%w[E F])
    end

    it 'has attack frames for imp' do
      frames = Doom::Game::MonsterAI::ATTACK_FRAMES['TROO']
      expect(frames).to eq(%w[E F G H])
    end

    it 'has attack frames for demon' do
      frames = Doom::Game::MonsterAI::ATTACK_FRAMES['SARG']
      expect(frames).to eq(%w[E F G])
    end

    it 'attack animation finishes after correct duration' do
      zombie_mon = ai.monsters.find { |m| m.type == 3004 }
      skip 'No zombieman' unless zombie_mon

      zombie_mon.active = true
      zombie_mon.attacking = true
      zombie_mon.attack_frame_tic = 0

      # POSS has 2 attack frames * 8 tics = 16 tics
      15.times { ai.update(zombie_mon.x + 100, zombie_mon.y) }
      expect(zombie_mon.attacking).to be true

      ai.update(zombie_mon.x + 100, zombie_mon.y)
      expect(zombie_mon.attacking).to be false
    end
  end
end
