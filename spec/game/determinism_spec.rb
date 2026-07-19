# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/doom/game/monster_ai'

# Lockstep multiplayer requires that two peers running the same tics reach
# byte-identical state. These specs pin that property at the subsystem level:
# same seed + same inputs must produce the same world.
RSpec.describe 'simulation determinism' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  # Build an independent world from a seed and run it for `tics`, feeding a
  # fixed, scripted player path so the only variable is the RNG.
  #
  # The map is reloaded per run on purpose: SectorEffects mutates
  # sector.light_level in place, so sharing one MapData would let run N+1 start
  # from run N's leftovers and make the comparison meaningless.
  def run_world(seed, tics: 400)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    rng = Doom::Game::Random.new(seed)
    player = Doom::Game::PlayerState.new
    combat = Doom::Game::Combat.new(map, player, @sprites, {}, nil, random: rng)
    ai = Doom::Game::MonsterAI.new(map, combat, player, @sprites, {}, nil, random: rng)
    effects = Doom::Game::SectorEffects.new(map, random: rng)

    # Park the player next to a real monster and wake every monster up, so the
    # run exercises the RNG-driven paths that matter: chase direction, pain,
    # hitscan spread, damage rolls, monster attacks. A quiet world would make
    # this spec pass no matter how nondeterministic the engine is.
    target = map.things.find { |t| Doom::Game::Combat::MONSTER_HP[t.type] && t.type != 2035 }
    px = target.x - 96.0
    py = target.y.to_f

    ai.monsters.each do |mon|
      mon.active = true
      mon.reactiontime = 0
      mon.movecount = 0
      mon.chase_timer = 0
      mon.last_saw_player = 99_999
    end

    tics.times do |t|
      px += Math.cos(t * 0.05) * 2
      py += Math.sin(t * 0.05) * 2
      combat.update_player_pos(px, py, 41.0)
      combat.update
      ai.update(px, py)
      effects.update

      # Keep shooting so damage rolls and pain chances are drawn constantly.
      if (t % 4).zero?
        angle = t * 0.03
        combat.fire(px, py, 41.0, Math.cos(angle), Math.sin(angle),
                    Doom::Game::PlayerState::WEAPON_SHOTGUN)
      end
    end

    {
      health: player.health,
      rng_index: rng.index,
      monster_hp: combat.instance_variable_get(:@monster_hp).sort.to_h,
      dead: combat.dead_things.keys.sort,
      monsters: ai.monsters.map { |m| [m.thing_idx, m.x.round(6), m.y.round(6), m.movedir, m.active] },
      lights: map.sectors.map(&:light_level),
    }
  end

  it 'reaches identical state for two runs with the same seed' do
    expect(run_world(7)).to eq(run_world(7))
  end

  it 'reaches different state for different seeds' do
    # Not a correctness requirement in itself, but if these matched, the
    # same-seed test above would be vacuous.
    expect(run_world(7)).not_to eq(run_world(200))
  end

  it 'keeps the RNG index in lockstep across subsystems sharing one instance' do
    a = run_world(11)
    b = run_world(11)
    expect(a[:rng_index]).to eq(b[:rng_index])
  end

  it 'draws from the RNG during a run' do
    # Guards against the suite passing because nothing consumed randomness.
    expect(run_world(0)[:rng_index]).not_to eq(0)
  end
end
