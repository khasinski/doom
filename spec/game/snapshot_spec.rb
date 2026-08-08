# frozen_string_literal: true

require_relative '../spec_helper'

# The proof that a snapshot is complete is not that it reads back the fields I
# thought of -- it is that a world restored from it goes on simulating exactly
# as the original would. So the core spec restores a snapshot and drives both
# worlds forward with identical ticcmds, failing the instant any field was
# missed. StateHash is the oracle, and it now covers sector heights and door
# state, so "identical fingerprint" really does mean identical.
RSpec.describe Doom::Game::Snapshot do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  def fresh_map
    Doom::Map::MapData.load(@wad, 'E1M1')
  end

  # A world with several players that has actually done things. An earlier
  # version of this scenario just spun the players on the spot: it produced no
  # projectiles, no damaged monsters and no open doors, so the round trip below
  # proved far less than it claimed. This one drives every path deliberately --
  # a point-blank duel for combat and pain and death, an opened door and lift,
  # a rocket left in flight -- and the diagnostic in the spec guards that.
  def busy_world(players: 3, tics: 150, seed: 4)
    map = fresh_map
    world = Doom::Game::World.new(map, sprites: @sprites, mode: :deathmatch,
                                       random: Doom::Game::Random.new(seed))
    players.times { |i| world.add_player(id: i) }
    world.monster_ai.monsters.each { |m| m.active = true; m.reactiontime = 0 }

    # A duel: player 0 stands point-blank in front of player 1 and fires, so
    # bullets connect -- health drops, pain fires, someone dies.
    start = map.player_start
    p0 = world.player(0)
    p1 = world.player(1)
    p0.place(start.x, start.y, Doom::Game::PlayerState::VIEWHEIGHT, 0)
    p1.place(start.x + 48, start.y, Doom::Game::PlayerState::VIEWHEIGHT, 180)

    # Open a manual door through its real use trigger.
    world.sector_actions.use_linedef(map.linedefs[151], 151) # door, special 1

    duel = lambda do |t|
      cmds = build_script(players).call(t)
      cmds[0] = Doom::Game::Ticcmd.new(0.0, 0.0, 0.0, Doom::Game::Ticcmd::BTN_FIRE)
      cmds
    end
    (tics - 3).times { |t| world.run_tic(duel.call(t)) }

    # Start a lift right before the boundary (it is a walk trigger, so drive it
    # through activate_lift) so it is still moving when the snapshot is taken.
    world.sector_actions.send(:activate_lift, map.linedefs[195]) # lift, special 88

    # Leave a rocket in mid-air: give player 2 a launcher and fire on the last
    # tics so a projectile is still in flight at the snapshot boundary.
    p2 = world.player(2)
    if p2
      p2.state.weapon = Doom::Game::PlayerState::WEAPON_ROCKET
      p2.state.has_weapons[Doom::Game::PlayerState::WEAPON_ROCKET] = true
      p2.state.ammo_rockets = 50
    end
    3.times do |t|
      cmds = duel.call(tics - 3 + t)
      cmds[2] = Doom::Game::Ticcmd.new(0.0, 0.0, 0.0, Doom::Game::Ticcmd::BTN_FIRE) if p2
      world.run_tic(cmds)
    end
    world
  end

  # Deterministic per-tic input for each player. Kept as a lambda so a restored
  # world can be driven with the very same sequence.
  def build_script(players)
    lambda do |t|
      (0...players).each_with_object({}) do |id, h|
        buttons = if id.zero?
                    (t % 6).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0
                  else
                    (t % 9).zero? ? Doom::Game::Ticcmd::BTN_USE : 0
                  end
        h[id] = Doom::Game::Ticcmd.new(id.even? ? 1.0 : -1.0, 0.0, (t % 7) - 3.0, buttons)
      end
    end
  end

  def round_trip(world)
    bytes = described_class.dump(world)
    described_class.load(bytes, map: fresh_map, sprites: @sprites)
  end

  # Guards the round-trip tests from silently testing an empty world. If this
  # fails, the fidelity specs below are proving less than they look like they do.
  describe 'the scenario itself exercises the paths under test' do
    subject(:world) { busy_world }

    it 'has damaged and dead monsters or players' do
      hp = world.combat.instance_variable_get(:@monster_hp)
      hurt_players = world.players.any? { |p| p.state.health < 100 }
      expect(hp.size + world.combat.dead_things.size).to be_positive if hurt_players == false
      expect(hurt_players || (hp.size + world.combat.dead_things.size).positive?).to be(true)
    end

    it 'has a rocket in flight' do
      expect(world.combat.projectiles).not_to be_empty
    end

    it 'has an open door and a moving lift' do
      expect(world.sector_actions.instance_variable_get(:@active_doors)).not_to be_empty
      expect(world.sector_actions.instance_variable_get(:@active_lifts)).not_to be_empty
    end

    it 'has crossed linedefs recorded' do
      # trigger-once bookkeeping must survive the snapshot, so it must exist.
      total = world.sector_actions.instance_variable_get(:@crossed_linedefs).size +
              world.item_pickup.picked_up.size
      expect(total).to be_positive
    end
  end

  describe 'immediate fidelity' do
    it 'restores to the same fingerprint' do
      world = busy_world
      expect(round_trip(world).state_hash).to eq(world.state_hash)
    end

    it 'restores each section identically' do
      world = busy_world
      restored = round_trip(world)
      expect(restored.state_hash_sections).to eq(world.state_hash_sections)
    end

    it 'preserves player count, positions and frags' do
      world = busy_world
      restored = round_trip(world)

      expect(restored.players.map(&:id)).to eq(world.players.map(&:id))
      world.players.each do |p|
        rp = restored.player(p.id)
        expect([rp.x, rp.y, rp.angle]).to eq([p.x, p.y, p.angle])
        expect(rp.state.health).to eq(p.state.health)
        expect(rp.frags).to eq(p.frags)
      end
    end

    it 'preserves leveltime, mode and the RNG position' do
      world = busy_world
      restored = round_trip(world)

      expect(restored.leveltime).to eq(world.leveltime)
      expect(restored.mode).to eq(world.mode)
      expect(restored.random.index).to eq(world.random.index)
    end
  end

  describe 'future fidelity -- the real test' do
    it 'simulates identically for a long run after restore' do
      world = busy_world
      restored = round_trip(world)
      script = build_script(world.players.size)

      # Continue both from the snapshot boundary with the same inputs. Any
      # field the snapshot dropped shows up as a diverging fingerprint.
      start = world.leveltime
      300.times do |i|
        cmds = script.call(start + i)
        world.run_tic(cmds)
        restored.run_tic(cmds)
        expect(restored.state_hash).to eq(world.state_hash), "diverged #{i + 1} tics after restore"
      end
    end

    it 'keeps projectiles, monster state and doors consistent as they resolve' do
      world = busy_world(tics: 120)
      restored = round_trip(world)
      script = build_script(world.players.size)

      # Long enough for in-flight rockets to land, pain to wear off and any
      # open door to finish its cycle.
      start = world.leveltime
      200.times do |i|
        cmds = script.call(start + i)
        world.run_tic(cmds)
        restored.run_tic(cmds)
      end
      expect(restored.state_hash_sections).to eq(world.state_hash_sections)
    end
  end

  describe 'skill damage factor' do
    # World.rebuild_actor_subsystems mirrors @damage_multiplier onto the monster
    # AI, but a world built fresh for a load skips that path. If load restores
    # only world.damage_multiplier and forgets monster_ai.damage_multiplier, a
    # snapshot taken on a non-1.0 skill comes back with monsters dealing 1.0x
    # damage. This guards that the AI's factor survives the round trip.
    it 'restores the monster AI damage multiplier, not just the world field' do
      map = fresh_map
      world = Doom::Game::World.new(map, sprites: @sprites,
                                         random: Doom::Game::Random.new(4))
      world.add_player
      world.damage_multiplier = 2.5
      world.monster_ai.damage_multiplier = 2.5

      restored = round_trip(world)

      expect(restored.damage_multiplier).to eq(2.5)
      expect(restored.monster_ai.damage_multiplier).to eq(2.5)
    end
  end

  describe 'the snapshot bytes' do
    it 'is a self-describing binary blob' do
      bytes = described_class.dump(busy_world)
      expect(bytes).to be_a(String)
      expect(bytes.encoding).to eq(Encoding::BINARY)
      expect(bytes.getbyte(0)).to eq(described_class::VERSION)
    end

    it 'rejects a version it does not understand' do
      bytes = described_class.dump(busy_world).dup
      bytes.setbyte(0, 99)
      expect { described_class.load(bytes, map: fresh_map, sprites: @sprites) }
        .to raise_error(/version/)
    end

    it 'stays a reasonable size for a full deathmatch' do
      # Sanity on the wire cost: this has to reach a joiner. Report it so a
      # regression in size is visible, and flag if it needs fragmenting.
      bytes = described_class.dump(busy_world(players: 30, tics: 80))
      expect(bytes.bytesize).to be < 64 * 1024
    end
  end

  describe 'determinism of the format itself' do
    it 'produces identical bytes for the same world twice' do
      world = busy_world
      expect(described_class.dump(world)).to eq(described_class.dump(world))
    end

    it 'produces identical bytes across two equal worlds' do
      a = busy_world(seed: 8)
      b = busy_world(seed: 8)
      expect(described_class.dump(a)).to eq(described_class.dump(b))
    end
  end
end
