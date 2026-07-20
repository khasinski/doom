# frozen_string_literal: true

require_relative '../spec_helper'

# Game::World is the simulation with no window attached. That property is the
# whole point -- the lockstep netcode will drive run_tic headlessly -- so these
# specs exercise it exactly that way.
RSpec.describe Doom::Game::World do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  # A fresh map per world: SectorEffects mutates sector light levels in place,
  # so a shared MapData would leak state between worlds.
  def new_world(seed = 0)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    world = described_class.new(map, sprites: @sprites, random: Doom::Game::Random.new(seed))
    world.add_player(map.player_start)
    world
  end

  def forward(n = 1.0)
    Doom::Game::Ticcmd.new(n, 0.0, 0.0, 0)
  end

  describe 'construction' do
    it 'builds without a window, renderer or sound' do
      expect { new_world }.not_to raise_error
    end

    it 'owns its subsystems' do
      w = new_world
      expect(w.combat).to be_a(Doom::Game::Combat)
      expect(w.monster_ai).to be_a(Doom::Game::MonsterAI)
      expect(w.item_pickup).to be_a(Doom::Game::ItemPickup)
      expect(w.sector_actions).to be_a(Doom::Game::SectorActions)
      expect(w.sector_effects).to be_a(Doom::Game::SectorEffects)
    end

    it 'spawns the player at the map start, standing on the floor' do
      w = new_world
      start = w.map.player_start
      p = w.player(0)

      expect([p.x, p.y]).to eq([start.x.to_f, start.y.to_f])
      expect(p.z).to be > 0
      expect(w.map.sector_at(p.x, p.y)).not_to be_nil
    end

    it 'gives each player its own physics' do
      w = new_world
      second = w.add_player(w.map.player_start, id: 1)
      expect(w.physics_for(second)).not_to equal(w.physics_for(w.player(0)))
    end
  end

  describe '#run_tic' do
    it 'advances leveltime by one and returns it' do
      w = new_world
      expect(w.run_tic).to eq(1)
      expect(w.run_tic).to eq(2)
      expect(w.leveltime).to eq(2)
    end

    it 'moves the player from a ticcmd' do
      w = new_world
      p = w.player(0)
      start = [p.x, p.y]
      40.times { w.run_tic(0 => forward) }
      expect(Math.hypot(p.x - start[0], p.y - start[1])).to be > 10
    end

    it 'leaves the player still with no command at all' do
      w = new_world
      p = w.player(0)
      start = [p.x, p.y]
      40.times { w.run_tic }
      expect([p.x, p.y]).to eq(start)
    end

    it 'treats a missing command as neutral rather than repeating the last one' do
      # A dropped packet must not read as a stuck key.
      w = new_world
      p = w.player(0)
      40.times { w.run_tic(0 => forward) }
      moving = [p.x, p.y]
      200.times { w.run_tic }

      expect(p.momx).to eq(0.0)
      expect(p.momy).to eq(0.0)
      expect([p.x, p.y]).not_to eq(moving)  # coasted to a stop, did not teleport
    end

    it 'keeps snapshots one tic behind for interpolation' do
      w = new_world
      p = w.player(0)
      20.times { w.run_tic(0 => forward) }
      expect([p.prev_x, p.prev_y]).not_to eq([p.x, p.y])
      expect(p.view_pose(1.0)[0, 2]).to eq([p.x, p.y])
    end
  end

  describe 'determinism' do
    # Park the player next to a monster and wake everything up. Left at the map
    # start the world is nearly inert, and the comparison below would pass no
    # matter how nondeterministic the engine was.
    def new_busy_world(seed)
      w = new_world(seed)
      target = w.map.things.find do |t|
        Doom::Game::Combat::MONSTER_HP[t.type] && t.type != Doom::Game::Combat::BARREL_TYPE
      end
      w.player(0).place(target.x - 96.0, target.y.to_f, Doom::Game::PlayerState::VIEWHEIGHT, 0)
      w.monster_ai.monsters.each do |m|
        m.active = true
        m.reactiontime = 0
        m.movecount = 0
        m.chase_timer = 0
      end
      w
    end

    def digest(world)
      p = world.player(0)
      [
        p.x, p.y, p.z, p.angle, p.momx, p.momy,
        p.state.health, p.state.ammo_bullets,
        world.random.index,
        world.combat.dead_things.keys.sort,
        world.monster_ai.monsters.map { |m| [m.thing_idx, m.x, m.y, m.movedir] },
        world.map.sectors.map(&:light_level),
      ]
    end

    let(:cmds) do
      Array.new(300) do |i|
        Doom::Game::Ticcmd.new(1.0, (i % 5).zero? ? 1.0 : 0.0, (i % 7) - 3.0,
                               (i % 4).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)
      end
    end

    it 'reaches identical state from the same seed and the same ticcmds' do
      a = new_busy_world(9)
      b = new_busy_world(9)
      cmds.each { |c| a.run_tic(0 => c) }
      cmds.each { |c| b.run_tic(0 => c) }

      expect(digest(a)).to eq(digest(b))
    end

    it 'diverges from a different seed' do
      a = new_busy_world(9)
      b = new_busy_world(77)
      cmds.each { |c| a.run_tic(0 => c) }
      cmds.each { |c| b.run_tic(0 => c) }

      expect(digest(a)).not_to eq(digest(b))
    end

    it 'consumes randomness during the run' do
      w = new_busy_world(0)
      cmds.each { |c| w.run_tic(0 => c) }
      expect(w.random.index).not_to eq(0)
    end
  end

  describe 'several players' do
    # Two players in the same world, placed by hand so the geometry of each
    # case is explicit.
    def two_player_world
      w = new_world(3)
      w.add_player(w.map.player_start, id: 1)
      w
    end

    def first_monster(world)
      world.monster_ai.monsters.first
    end

    it 'ticks every player from its own command' do
      w = two_player_world
      a = w.player(0)
      b = w.player(1)
      a_start = [a.x, a.y]
      b_start = [b.x, b.y]

      40.times { w.run_tic(0 => forward) }

      expect([a.x, a.y]).not_to eq(a_start)
      expect([b.x, b.y]).to eq(b_start)
    end

    it 'gives each player independent health and ammo' do
      w = two_player_world
      w.player(0).state.take_damage(30)
      w.player(0).state.ammo_bullets = 7

      expect(w.player(1).state.health).to eq(100)
      expect(w.player(1).state.ammo_bullets).not_to eq(7)
    end

    describe 'monster targeting' do
      it 'picks the nearer player' do
        w = two_player_world
        mon = first_monster(w)

        w.player(0).place(mon.x + 64, mon.y, 41, 0)
        w.player(1).place(mon.x + 900, mon.y, 41, 0)
        w.monster_ai.send(:select_target, mon, w.players)

        expect(mon.target).to equal(w.player(0))
      end

      it 'keeps its target while that player lives, even if another comes closer' do
        # Otherwise a second player walking past would yank monsters off
        # whoever they were already fighting.
        w = two_player_world
        mon = first_monster(w)

        w.player(0).place(mon.x + 64, mon.y, 41, 0)
        w.player(1).place(mon.x + 900, mon.y, 41, 0)
        w.monster_ai.send(:select_target, mon, w.players)

        w.player(1).place(mon.x + 8, mon.y, 41, 0)
        w.monster_ai.send(:select_target, mon, w.players)

        expect(mon.target).to equal(w.player(0))
      end

      it 'switches when its target dies' do
        w = two_player_world
        mon = first_monster(w)

        w.player(0).place(mon.x + 64, mon.y, 41, 0)
        w.player(1).place(mon.x + 900, mon.y, 41, 0)
        w.monster_ai.send(:select_target, mon, w.players)

        w.player(0).state.dead = true
        w.monster_ai.send(:select_target, mon, w.players)

        expect(mon.target).to equal(w.player(1))
      end

      it 'has no target when every player is dead' do
        w = two_player_world
        mon = first_monster(w)
        w.players.each { |p| p.state.dead = true }

        expect(w.monster_ai.send(:select_target, mon, w.players)).to be_nil
      end
    end

    it 'splashes a barrel explosion onto every player in radius' do
      w = two_player_world
      barrel = w.map.things.find { |t| t.type == Doom::Game::Combat::BARREL_TYPE }
      skip 'No barrel in map' unless barrel

      w.players.each { |p| p.place(barrel.x + 8, barrel.y.to_f, 41, 0) }
      w.combat.send(:barrel_explode, barrel.x.to_f, barrel.y.to_f, nil)

      expect(w.player(0).state.health).to be < 100
      expect(w.player(1).state.health).to be < 100
    end

    it 'lets a monster fireball hit a player it was not aimed at' do
      w = two_player_world
      mon = first_monster(w)

      # Spawn at chest height above the actual floor, as MonsterAI does. A
      # fireball that dips below floor_height counts as hitting a wall, so a
      # hardcoded z would make this test explode short of anyone.
      sector = w.map.sector_at(mon.x, mon.y)
      spawn_z = sector.floor_height + 32
      eye_z = sector.floor_height + Doom::Game::PlayerState::VIEWHEIGHT

      aimed_at = w.player(0)
      aimed_at.place(mon.x + 300, mon.y, eye_z, 0)
      w.combat.spawn_monster_projectile(mon.x, mon.y, spawn_z.to_f, 3001, 1.0, aimed_at)
      skip 'Monster type does not throw fireballs' if w.combat.projectiles.empty?

      # Park the other player directly in the fireball's path.
      w.player(1).place(mon.x + 60, mon.y, eye_z, 0)
      20.times { w.combat.update }

      expect(w.player(1).state.health).to be < 100
      expect(aimed_at.state.health).to eq(100)  # stopped before reaching them
    end
  end

  describe '#respawn' do
    it 'restores health and returns the player to the start' do
      w = new_world
      p = w.player(0)
      60.times { w.run_tic(0 => forward) }
      p.state.health = 5

      w.respawn(p)

      start = w.map.player_start
      expect(p.state.health).to eq(100)
      expect([p.x, p.y]).to eq([start.x.to_f, start.y.to_f])
    end

    it 'rebuilds the actor subsystems' do
      w = new_world
      old_combat = w.combat
      w.respawn(w.player(0))
      expect(w.combat).not_to equal(old_combat)
      expect(w.monster_ai).not_to equal(old_combat)
    end

    it 'rebinds physics to the rebuilt subsystems' do
      w = new_world
      w.respawn(w.player(0))
      physics = w.physics_for(w.player(0))
      expect(physics.instance_variable_get(:@combat)).to equal(w.combat)
      expect(physics.instance_variable_get(:@item_pickup)).to equal(w.item_pickup)
    end

    it 'can still be ticked after a respawn' do
      w = new_world
      w.respawn(w.player(0))
      expect { 30.times { w.run_tic(0 => forward) } }.not_to raise_error
    end
  end
end
