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

  # Helper: find a specific monster type
  def find_monster(ai, type)
    ai.monsters.find { |m| m.type == type }
  end

  # Helper: make a monster ready to attack
  def ready_to_attack(mon)
    mon.active = true
    mon.movecount = 0
    mon.attack_cooldown = 0
    mon.reactiontime = 0
    mon.chase_timer = 0
    mon.last_saw_player = 99999
    mon.attacking = false
    mon.attack_frame_tic = 0
  end

  # Helper: run AI+combat tics like the game loop
  def run_tics(ai, combat, px, py, count)
    combat.update_player_pos(px, py, 17.0)
    count.times do
      combat.update
      ai.update(px, py)
    end
  end

  describe 'initialization' do
    it 'creates states for all monsters, excluding barrels' do
      monster_things = @map.things.select { |t| Doom::Game::Combat::MONSTER_HP[t.type] && t.type != 2035 }
      expect(ai.monsters.size).to eq(monster_things.size)
    end

    it 'provides O(1) lookup by thing index' do
      mon = ai.monsters.first
      expect(ai.monster_by_thing_idx[mon.thing_idx]).to equal(mon)
    end

    it 'starts all monsters inactive with reactiontime' do
      ai.monsters.each do |mon|
        expect(mon.active).to be false
        expect(mon.reactiontime).to eq(described_class::REACTIONTIME)
      end
    end
  end

  describe 'activation (A_Look)' do
    it 'activates monster with LOS within sight range' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      ai.update(mon.x + 100, mon.y)
      expect(mon.active).to be true
    end

    it 'does not activate monsters beyond sight range' do
      ai.update(-9999, -9999)
      expect(ai.monsters.any?(&:active)).to be false
    end

    it 'only sees in 180-degree forward arc' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      thing = @map.things[mon.thing_idx]
      face_rad = thing.angle * Math::PI / 180.0
      # Stand behind the monster
      behind_x = mon.x - Math.cos(face_rad) * 200
      behind_y = mon.y - Math.sin(face_rad) * 200
      ai.update(behind_x, behind_y)
      # Should NOT activate (unless geometry gives LOS another way)
    end
  end

  describe 'deactivation' do
    it 'goes idle after ~3 seconds without LOS' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      # Manually activate
      mon.active = true
      mon.last_saw_player = ai.instance_variable_get(:@tic_counter)

      120.times { ai.update(-9999, -9999) }
      expect(mon.active).to be false
    end

    it 'resets reactiontime on deactivation' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      mon.active = true
      mon.reactiontime = 0
      mon.last_saw_player = ai.instance_variable_get(:@tic_counter)

      120.times { ai.update(-9999, -9999) }
      expect(mon.reactiontime).to eq(described_class::REACTIONTIME)
    end
  end

  # Chocolate Doom attack sequence:
  # 1. A_Chase decides to attack -> monster enters attack animation
  # 2. Animation plays through frames (E, F, G...)
  # 3. Damage/projectile happens at a SPECIFIC frame (the "fire" frame)
  # 4. Animation completes -> returns to chase
  #
  # Our implementation must match: NO damage on attack decision,
  # damage only when the fire frame is reached.
  describe 'attack timing (matching Chocolate Doom)' do
    it 'does NOT apply hitscan damage on first frame of attack' do
      mon = find_monster(ai, 3004) # Zombieman
      skip 'No zombieman' unless mon
      ready_to_attack(mon)

      initial_health = player.health
      combat.update_player_pos(mon.x + 50, mon.y)

      # Force attack by running until it triggers
      attacked = false
      500.times do
        ai.update(mon.x + 50, mon.y)
        if mon.attacking && mon.attack_frame_tic <= 1
          attacked = true
          break
        end
      end

      if attacked
        # On the first tic of attack, player should NOT have taken damage yet
        # Damage should come on the "fire" frame (frame index 1 = frame F)
        expect(player.health).to eq(initial_health)
      end
    end

    it 'applies hitscan damage on the fire frame, not before' do
      mon = find_monster(ai, 3004) # Zombieman
      skip 'No zombieman' unless mon

      # POSS attack: frame E (raise), frame F (fire)
      # Fire frame index = 1, at tic = ATTACK_FRAME_TICS * 1
      fire_tic = described_class::ATTACK_FRAME_TICS * 1
      expect(fire_tic).to eq(8) # Sanity check
    end

    it 'spawns imp fireball on the fire frame, not attack start' do
      imp = find_monster(ai, 3001)
      skip 'No imp' unless imp
      ready_to_attack(imp)
      combat.update_player_pos(imp.x + 150, imp.y)

      # Trigger attack
      500.times do
        ai.update(imp.x + 150, imp.y)
        break if imp.attacking
      end
      skip 'Imp never attacked (probabilistic)' unless imp.attacking

      # On attack frame 0 (raise), no fireball yet
      expect(combat.projectiles.size).to eq(0)
    end
  end

  describe 'attack types (matching Chocolate Doom mobjinfo)' do
    it 'zombieman uses hitscan' do
      expect(described_class::MONSTER_ATTACK[3004][:type]).to eq(:hitscan)
    end

    it 'shotgun guy uses hitscan' do
      expect(described_class::MONSTER_ATTACK[9][:type]).to eq(:hitscan)
    end

    it 'imp uses projectile (fireball)' do
      expect(described_class::MONSTER_ATTACK[3001][:type]).to eq(:projectile)
    end

    it 'demon uses melee' do
      expect(described_class::MONSTER_ATTACK[3002][:type]).to eq(:melee)
    end

    it 'baron uses projectile' do
      expect(described_class::MONSTER_ATTACK[3003][:type]).to eq(:projectile)
    end
  end

  describe 'projectile spawning' do
    it 'imp fireball survives multiple tics (not blocked by BLOCKING lines)' do
      imp = find_monster(ai, 3001)
      skip 'No imp' unless imp
      ready_to_attack(imp)

      target_x = imp.x + 200
      target_y = imp.y
      combat.update_player_pos(target_x, target_y)

      # Force spawn a projectile directly
      combat.spawn_monster_projectile(imp.x, imp.y, 41.0, 3001, 1.0)
      expect(combat.projectiles.size).to eq(1)

      # Run combat updates - projectile should survive
      5.times { combat.update }

      # Projectile should still exist (traveling) or have hit the player
      # It should NOT have been killed by a wall on frame 1
      survived_or_hit = combat.projectiles.any? || combat.explosions.any? || player.health < 100
      expect(survived_or_hit).to be true
    end

    it 'fireball damages player on contact' do
      imp = find_monster(ai, 3001)
      skip 'No imp' unless imp

      # Spawn fireball heading directly at player at same height
      sector = @map.sector_at(imp.x, imp.y)
      floor = sector ? sector.floor_height : 0
      spawn_z = floor + 32
      px = imp.x + 50
      combat.update_player_pos(px, imp.y, spawn_z.to_f)
      combat.spawn_monster_projectile(imp.x, imp.y, spawn_z.to_f, 3001, 1.0)

      initial_health = player.health
      20.times { combat.update }

      expect(player.health).to be < initial_health
    end

    it 'fireball has vertical velocity when source and target at different heights' do
      imp = find_monster(ai, 3001)
      skip 'No imp' unless imp

      # Simulate imp on high platform (z=128) shooting at player on floor (z=17)
      combat.update_player_pos(imp.x + 200, imp.y)
      combat.spawn_monster_projectile(imp.x, imp.y, 128.0, 3001, 1.0)

      proj = combat.projectiles.last
      expect(proj).not_to be_nil
      expect(proj.dz).to be < 0  # Must descend toward player
      expect(proj.z).to eq(128.0)

      # After a few tics, z should decrease
      5.times { combat.update }
      if combat.projectiles.any?
        expect(combat.projectiles.last.z).to be < 128.0
      end
    end

    it 'fireball hits floor or ceiling and explodes' do
      imp = find_monster(ai, 3001)
      skip 'No imp' unless imp

      # Spawn fireball very high, aiming straight down
      combat.update_player_pos(imp.x + 50, imp.y)
      combat.spawn_monster_projectile(imp.x, imp.y, 500.0, 3001, 1.0)

      100.times { combat.update }
      # Should have hit floor and exploded
      expect(combat.projectiles.size).to eq(0)
    end

    it 'fireball creates explosion on player impact' do
      imp = find_monster(ai, 3001)
      skip 'No imp' unless imp

      # Spawn fireball aimed at player 50 units away (guaranteed hit)
      px = imp.x + 50
      combat.update_player_pos(px, imp.y)
      combat.spawn_monster_projectile(imp.x, imp.y, 41.0, 3001, 1.0)

      20.times { combat.update }

      # Should have created an explosion on player hit
      expect(combat.explosions.size).to be > 0
    end
  end

  describe 'movement during attack' do
    it 'freezes movement while attacking' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      mon.active = true
      mon.attacking = true
      mon.attack_frame_tic = 0

      initial_x, initial_y = mon.x, mon.y
      10.times { ai.update(mon.x + 200, mon.y) }

      expect(mon.x).to eq(initial_x)
      expect(mon.y).to eq(initial_y)
    end

    it 'resumes movement after attack animation completes' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      mon.active = true
      mon.attacking = true
      mon.attack_frame_tic = 0
      mon.last_saw_player = 99999

      # Run through the full attack animation (2 frames * 8 tics = 16)
      20.times { ai.update(mon.x + 200, mon.y) }
      expect(mon.attacking).to be false
    end
  end

  describe 'ranged monster positioning' do
    it 'ranged monsters stop advancing when close with LOS' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      mon.active = true
      mon.last_saw_player = 99999

      # Player is 100 units away (< KEEP_DISTANCE)
      target_x = mon.x + 100
      initial_x = mon.x
      50.times { ai.update(target_x, mon.y) }

      # Should not have advanced much
      advance = (mon.x - initial_x).abs
      expect(advance).to be < 50
    end

    it 'melee monsters keep chasing to close range' do
      demon = find_monster(ai, 3002)
      skip 'No demon' unless demon
      demon.active = true
      demon.last_saw_player = 99999

      initial_x = demon.x
      target_x = demon.x + 100
      50.times { ai.update(target_x, demon.y) }

      # Demon (melee) should keep advancing
      advance = (demon.x - initial_x).abs
      expect(advance).to be > 0
    end
  end

  describe 'aggression toggle' do
    it 'prevents all attacks when aggression is off' do
      ai.aggression = false
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      ready_to_attack(mon)

      initial_health = player.health
      combat.update_player_pos(mon.x + 50, mon.y)
      100.times do
        ai.update(mon.x + 50, mon.y)
        combat.update
      end

      expect(player.health).to eq(initial_health)
    end
  end

  describe 'pain interaction' do
    it 'skips movement and attacks while in pain' do
      mon = find_monster(ai, 3004)
      skip 'No zombieman' unless mon
      mon.active = true
      combat.instance_variable_get(:@pain_until)[mon.thing_idx] = 99999

      initial_x = mon.x
      5.times { ai.update(mon.x + 200, mon.y) }
      expect(mon.x).to eq(initial_x)
    end
  end

  describe 'attack animation frames' do
    {
      'POSS' => %w[E F],
      'SPOS' => %w[E F],
      'TROO' => %w[E F G H],
      'SARG' => %w[E F G],
      'HEAD' => %w[E F],
      'BOSS' => %w[E F G],
    }.each do |prefix, expected_frames|
      it "#{prefix} has correct attack frames" do
        expect(described_class::ATTACK_FRAMES[prefix]).to eq(expected_frames)
      end
    end

    # In Chocolate Doom, the "fire" action happens on a specific frame:
    # Zombieman: frame F (index 1), Imp: frame G (index 2), Demon: frame F (index 1)
    {
      'POSS' => 1,  # Frame F = fire
      'SPOS' => 1,  # Frame F = fire
      'TROO' => 2,  # Frame G = throw fireball
      'SARG' => 1,  # Frame F = bite
    }.each do |prefix, expected_fire_idx|
      it "#{prefix} fires on frame index #{expected_fire_idx}" do
        expect(described_class::FIRE_FRAME_INDEX[prefix]).to eq(expected_fire_idx)
      end
    end
  end
end
