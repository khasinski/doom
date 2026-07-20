# frozen_string_literal: true

require_relative '../spec_helper'

# Deathmatch: players shooting each other, and the score that comes out of it.
#
# Everything here goes through run_tic with ticcmds, the same way the netcode
# drives the world, rather than calling into Combat directly -- the point is
# that a trigger pull ends up as a frag, not that some private method exists.
RSpec.describe 'deathmatch' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  FIRE = Doom::Game::Ticcmd.new(0.0, 0.0, 0.0, Doom::Game::Ticcmd::BTN_FIRE)

  # Two players facing each other 48 units apart at the map start, which is
  # open floor with nothing awake in it. A fresh map per world: sector lighting
  # is mutated in place, so a shared MapData would leak between worlds.
  def duel(mode: :deathmatch, frag_limit: nil, seed: 0)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    world = Doom::Game::World.new(map, sprites: @sprites, mode: mode, frag_limit: frag_limit,
                                        random: Doom::Game::Random.new(seed))
    start = map.player_start
    shooter = world.add_player(start, id: 0)
    victim = world.add_player(start, id: 1)
    shooter.place(start.x, start.y, Doom::Game::PlayerState::VIEWHEIGHT, 0)
    victim.place(start.x + 48, start.y, Doom::Game::PlayerState::VIEWHEIGHT, 180)
    [world, shooter, victim]
  end

  # A player backed up to within 30 units of a wall with a loaded rocket
  # launcher. Splash from a rocket that detonates that close reaches back far
  # enough to kill its own shooter in two shots.
  def cornered_rocketeer(frag_limit: nil)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    world = Doom::Game::World.new(map, sprites: @sprites, mode: :deathmatch,
                                        frag_limit: frag_limit,
                                        random: Doom::Game::Random.new(0))
    start = map.player_start
    player = world.add_player(start, id: 0)
    # Player 1 is parked well out of the blast so the score is unambiguous.
    world.add_player(start, id: 1).place(start.x, start.y - 600, 41.0, 0)

    player.place(start.x, start.y, Doom::Game::PlayerState::VIEWHEIGHT, 270)
    wall = world.combat.send(:trace_wall, player.x, player.y, player.cos_angle, player.sin_angle)
    player.move_to(start.x + (player.cos_angle * (wall - 30)),
                   start.y + (player.sin_angle * (wall - 30)))

    state = player.state
    state.weapon = Doom::Game::PlayerState::WEAPON_ROCKET
    state.has_weapons[Doom::Game::PlayerState::WEAPON_ROCKET] = true
    state.ammo_rockets = 10
    [world, player]
  end

  describe 'player versus player damage' do
    it 'lets a bullet hurt another player' do
      world, _shooter, victim = duel
      20.times { world.run_tic(0 => FIRE) }

      expect(victim.state.health).to be < 100
    end

    it 'lets a fist hurt another player' do
      world, shooter, victim = duel
      shooter.state.weapon = Doom::Game::PlayerState::WEAPON_FIST
      20.times { world.run_tic(0 => FIRE) }

      expect(victim.state.health).to be < 100
    end

    it 'does not hurt the player pulling the trigger' do
      world, shooter, = duel
      60.times { world.run_tic(0 => FIRE) }

      expect(shooter.state.health).to eq(100)
    end

    it 'has no friendly fire in co-op' do
      world, _shooter, victim = duel(mode: :coop)
      200.times { world.run_tic(0 => FIRE) }

      expect(victim.state.health).to eq(100)
      expect(victim.state.dead).to be(false)
    end
  end

  describe 'frags' do
    it 'credits a kill to the shooter' do
      world, shooter, victim = duel
      200.times { world.run_tic(0 => FIRE) }

      expect(victim.state.dead).to be(true)
      expect(shooter.frags).to eq(1)
      expect(victim.frags).to eq(0)
    end

    it 'scores the kill once, not once per tic the corpse lies there' do
      world, shooter, = duel
      400.times { world.run_tic(0 => FIRE) }

      expect(shooter.frags).to eq(1)
    end

    it 'costs a frag to kill yourself' do
      world, player = cornered_rocketeer
      60.times { world.run_tic(0 => FIRE) }

      expect(player.state.dead).to be(true)
      expect(player.frags).to eq(-1)
    end

    it 'scores nothing in co-op' do
      world, shooter, victim = duel(mode: :coop)
      200.times { world.run_tic(0 => FIRE) }

      expect([shooter.frags, victim.frags]).to eq([0, 0])
    end

    it 'survives respawning' do
      # Frags belong to the player, not to the life they were scored in.
      world, shooter, victim = duel
      200.times { world.run_tic(0 => FIRE) }
      world.respawn(victim)

      expect(shooter.frags).to eq(1)
      expect(victim.state.dead).to be(false)
      expect(victim.state.health).to eq(100)
    end
  end

  describe 'the frag limit' do
    it 'is open ended when unset' do
      world, shooter, = duel
      200.times { world.run_tic(0 => FIRE) }

      expect(shooter.frags).to eq(1)
      expect(world.frag_limit_reached?).to be(false)
      expect(world.match_winner).to be_nil
    end

    it 'ends the match when a player reaches it' do
      world, shooter, = duel(frag_limit: 1)
      expect(world.match_winner).to be_nil

      200.times { world.run_tic(0 => FIRE) }

      expect(shooter.frags).to eq(1)
      expect(world.frag_limit_reached?).to be(true)
      expect(world.match_winner).to equal(shooter)
    end

    it 'does not end while the leader is still short of it' do
      world, shooter, = duel(frag_limit: 2)
      200.times { world.run_tic(0 => FIRE) }

      expect(shooter.frags).to eq(1)
      expect(world.match_winner).to be_nil
    end

    it 'does not hand a suicide the win' do
      # A negative score must not read as "reached the limit".
      world, player = cornered_rocketeer(frag_limit: 1)
      60.times { world.run_tic(0 => FIRE) }

      expect(player.frags).to eq(-1)
      expect(world.match_winner).to be_nil
    end

    it 'names the leader by lowest id when scores tie, so peers agree' do
      world, shooter, victim = duel(frag_limit: 1)
      shooter.frags = 1
      victim.frags = 1

      expect(world.match_winner).to equal(shooter)
    end

    it 'reports the score per player' do
      world, shooter, = duel
      200.times { world.run_tic(0 => FIRE) }

      expect(world.frags).to eq(0 => shooter.frags, 1 => 0)
    end
  end

  describe 'determinism' do
    # Frags are simulation state: if two peers disagreed on the score they
    # would disagree on who won, and the desync monitor has to see it.
    it 'reaches the same score and the same fingerprint on two peers' do
      a, = duel(seed: 7)
      b, = duel(seed: 7)
      200.times { a.run_tic(0 => FIRE) }
      200.times { b.run_tic(0 => FIRE) }

      expect(a.frags).to eq(b.frags)
      expect(a.state_hash).to eq(b.state_hash)
    end

    it 'notices a frag difference on its own' do
      # The proof that the check above is worth anything: nothing but the score
      # differs here, and the fingerprint still has to move.
      a, shooter_a, = duel(seed: 7)
      b, = duel(seed: 7)
      200.times { a.run_tic(0 => FIRE) }
      200.times { b.run_tic(0 => FIRE) }
      shooter_a.frags += 1

      expect(a.state_hash).not_to eq(b.state_hash)
      expect(a.state_hash_sections[:players]).not_to eq(b.state_hash_sections[:players])
      expect(a.state_hash_sections[:rng]).to eq(b.state_hash_sections[:rng])
    end

    it 'draws its player-versus-player damage from the shared RNG' do
      # Same seed, same shots, same damage. A Kernel#rand slipping into the
      # damage roll would show up here as two different healths.
      a, _sa, va = duel(seed: 11)
      b, _sb, vb = duel(seed: 11)
      40.times { a.run_tic(0 => FIRE) }
      40.times { b.run_tic(0 => FIRE) }

      expect(va.state.health).to eq(vb.state.health)
      expect(va.state.health).to be < 100
    end

    it 'diverges from a different seed' do
      # Compared as a trace rather than a final health: two different tables of
      # damage rolls can happen to add up to the same total.
      a, _sa, va = duel(seed: 3)
      b, _sb, vb = duel(seed: 90)
      trace_a = Array.new(100) { a.run_tic(0 => FIRE); va.state.health }
      trace_b = Array.new(100) { b.run_tic(0 => FIRE); vb.state.health }

      expect(trace_a).not_to eq(trace_b)
    end
  end
end
