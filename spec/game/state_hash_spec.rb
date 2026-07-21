# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::StateHash do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  def new_world(seed = 0)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    w = Doom::Game::World.new(map, sprites: @sprites, random: Doom::Game::Random.new(seed))
    w.add_player
    w
  end

  def busy_world(seed = 0)
    w = new_world(seed)
    target = w.map.things.find do |t|
      Doom::Game::Combat::MONSTER_HP[t.type] && t.type != Doom::Game::Combat::BARREL_TYPE
    end
    w.player(0).place(target.x - 96.0, target.y.to_f, Doom::Game::PlayerState::VIEWHEIGHT, 0)
    w.monster_ai.monsters.each { |m| m.active = true; m.reactiontime = 0; m.chase_timer = 0 }
    w
  end

  def cmds(n = 200)
    Array.new(n) do |i|
      Doom::Game::Ticcmd.new(1.0, 0.0, (i % 7) - 3.0,
                             (i % 4).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)
    end
  end

  describe 'stability' do
    # The whole mechanism rests on this. Ruby randomises String#hash and
    # Array#hash per process, so a fingerprint built on those would differ
    # between peers running identical state and report desync every session.
    it 'is identical in a separate process' do
      w = busy_world(4)
      cmds(50).each { |c| w.run_tic(0 => c) }
      mine = w.state_hash

      script = <<~RUBY
        $LOAD_PATH.unshift #{File.expand_path('../../lib', __dir__).inspect}
        require "doom/wad/reader"; require "doom/map/data"; require "doom/wad/sprite"
        %w[random state_hash player_state player ticcmd player_physics sector_actions
           animations item_pickup combat sector_effects monster_ai world].each { |m| require "doom/game/\#{m}" }
        wad = Doom::Wad::Reader.new(#{wad_path.inspect})
        map = Doom::Map::MapData.load(wad, "E1M1")
        w = Doom::Game::World.new(map, sprites: Doom::Wad::SpriteManager.new(wad),
                                       random: Doom::Game::Random.new(4))
        w.add_player
        target = map.things.find { |t| Doom::Game::Combat::MONSTER_HP[t.type] && t.type != 2035 }
        w.player(0).place(target.x - 96.0, target.y.to_f, Doom::Game::PlayerState::VIEWHEIGHT, 0)
        w.monster_ai.monsters.each { |m| m.active = true; m.reactiontime = 0; m.chase_timer = 0 }
        50.times { |i| w.run_tic(0 => Doom::Game::Ticcmd.new(1.0, 0.0, (i % 7) - 3.0,
                                        (i % 4).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)) }
        print w.state_hash
      RUBY

      other = IO.popen([RbConfig.ruby, '-e', script], &:read).to_i
      expect(other).to eq(mine)
    end

    it 'does not change when asked twice for the same state' do
      w = busy_world(4)
      cmds(20).each { |c| w.run_tic(0 => c) }
      expect(w.state_hash).to eq(w.state_hash)
    end
  end

  describe 'agreement between equal worlds' do
    it 'matches at every checkpoint for the same seed and inputs' do
      a = busy_world(6)
      b = busy_world(6)

      cmds.each_with_index do |c, i|
        a.run_tic(0 => c)
        b.run_tic(0 => c)
        expect(a.state_hash).to eq(b.state_hash), "diverged at tic #{i + 1}"
      end
    end
  end

  describe 'sensitivity' do
    it 'differs for different seeds' do
      a = busy_world(6)
      b = busy_world(99)
      cmds.each { |c| a.run_tic(0 => c) }
      cmds.each { |c| b.run_tic(0 => c) }

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it 'notices a single changed input' do
      a = busy_world(6)
      b = busy_world(6)
      list = cmds(60)
      list.each { |c| a.run_tic(0 => c) }
      altered = list.dup
      altered[30] = Doom::Game::Ticcmd.new(-1.0, 0.0, 0.0, 0)
      altered.each { |c| b.run_tic(0 => c) }

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it 'notices a one-ULP drift in a player position' do
      # In lockstep the smallest float difference compounds, so the check must
      # not round it away.
      a = busy_world(1)
      b = busy_world(1)
      b.player(0).x = a.player(0).x.next_float

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it 'notices a difference in monster state alone' do
      a = busy_world(1)
      b = busy_world(1)
      b.monster_ai.monsters.first.movedir = (a.monster_ai.monsters.first.movedir + 1) % 8

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it 'notices a difference in the RNG index alone' do
      a = busy_world(1)
      b = busy_world(1)
      b.random.index = (a.random.index + 1) % 256

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it 'notices a sector light difference alone' do
      a = busy_world(1)
      b = busy_world(1)
      b.map.sectors.first.light_level += 1

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    # These three were blind spots the fingerprint used to ignore. A door
    # position, a lift, or a monster's map-thing position could diverge between
    # peers and the desync monitor would never see it. Snapshot fidelity work
    # surfaced them; these guard against the coverage regressing.
    it 'notices a sector floor height difference alone' do
      a = busy_world(1)
      b = busy_world(1)
      b.map.sectors.first.floor_height += 1

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it 'notices a moving door alone' do
      a = busy_world(1)
      b = busy_world(1)
      b.sector_actions.instance_variable_get(:@active_doors)[999] =
        { sector: b.map.sectors.first, state: 1, wait_tics: 3 }

      expect(a.state_hash).not_to eq(b.state_hash)
    end

    it "notices a monster's map-thing position alone" do
      # The position hitscan traces against, distinct from mon.x/mon.y.
      a = busy_world(1)
      b = busy_world(1)
      idx = b.monster_ai.monsters.first.thing_idx
      b.map.things[idx].x += 1

      expect(a.state_hash).not_to eq(b.state_hash)
    end
  end

  describe 'sections' do
    it 'reports every section' do
      expect(busy_world.state_hash_sections.keys).to match_array(described_class::SECTIONS)
    end

    it 'pins the divergence to the section that actually differs' do
      # This is what makes a desync report useful rather than just alarming.
      a = busy_world(1)
      b = busy_world(1)
      b.monster_ai.monsters.first.x += 1.0

      differing = described_class::SECTIONS.reject do |s|
        a.state_hash_sections[s] == b.state_hash_sections[s]
      end
      expect(differing).to eq([:monsters])
    end

    it 'reports no differing section for equal worlds' do
      a = busy_world(2)
      b = busy_world(2)
      cmds(40).each { |c| a.run_tic(0 => c); b.run_tic(0 => c) }

      expect(a.state_hash_sections).to eq(b.state_hash_sections)
    end
  end
end
