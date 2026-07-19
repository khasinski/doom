# frozen_string_literal: true

require_relative '../spec_helper'

# Horizontal movement used to integrate over wall-clock delta_time, which can
# never be reproduced on a second machine. It now runs per tic from a ticcmd.
# These specs pin the properties lockstep depends on.
RSpec.describe 'tic-based player movement' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
  end

  after(:all) { @wad&.close }

  START = [1056.0, -3616.0, 41.0, 90.0].freeze

  def new_player
    p = Doom::Game::Player.new
    p.place(*START)
    p
  end

  def new_physics(player)
    phys = Doom::Game::PlayerPhysics.new(@map, player.state)
    phys.settle_at(player.x, player.y)
    phys
  end

  def forward(n = 1.0)
    Doom::Game::Ticcmd.new(n, 0.0, 0.0, 0)
  end

  def run(player, physics, cmds)
    cmds.each { |c| physics.run_tic(player, c) }
    player
  end

  describe 'determinism' do
    it 'produces identical results for identical ticcmd sequences' do
      cmds = Array.new(120) { |i| Doom::Game::Ticcmd.new(1.0, (i % 7).zero? ? 1.0 : 0.0, (i % 5) - 2.0, 0) }

      a = new_player
      run(a, new_physics(a), cmds)
      b = new_player
      run(b, new_physics(b), cmds)

      expect([a.x, a.y, a.angle, a.momx, a.momy]).to eq([b.x, b.y, b.angle, b.momx, b.momy])
    end

    it 'does not depend on wall-clock time between calls' do
      cmds = Array.new(30) { forward }

      a = new_player
      run(a, new_physics(a), cmds)

      b = new_player
      phys = new_physics(b)
      cmds.each { |c| phys.run_tic(b, c) }

      expect([a.x, a.y]).to eq([b.x, b.y])
    end

    it 'diverges when the ticcmds differ' do
      a = new_player
      run(a, new_physics(a), Array.new(30) { forward })
      b = new_player
      run(b, new_physics(b), Array.new(30) { forward(-1.0) })

      expect([a.x, a.y]).not_to eq([b.x, b.y])
    end
  end

  describe 'movement behaviour' do
    it 'actually moves the player forward' do
      p = new_player
      run(p, new_physics(p), Array.new(20) { forward })
      expect(Math.hypot(p.x - START[0], p.y - START[1])).to be > 10
    end

    it 'builds momentum up to a terminal speed and never past it' do
      # Sampled per tic rather than read at the end: running into a wall zeroes
      # momentum, so the final value says nothing about the speed cap.
      p = new_player
      phys = new_physics(p)
      terminal = Doom::Game::PlayerPhysics::TERMINAL_SPEED

      speeds = Array.new(200) do
        phys.run_tic(p, forward)
        Math.hypot(p.momx, p.momy)
      end

      expect(speeds.max).to be_within(1.0).of(terminal)
      expect(speeds.max).to be <= terminal + 1e-9
    end

    it 'comes to a full stop when input stops' do
      p = new_player
      phys = new_physics(p)
      run(p, phys, Array.new(40) { forward })
      expect(Math.hypot(p.momx, p.momy)).to be > 1.0

      run(p, phys, Array.new(200) { Doom::Game::Ticcmd.none })
      expect(p.momx).to eq(0.0)
      expect(p.momy).to eq(0.0)
    end

    it 'turns by the commanded angle' do
      p = new_player
      before = p.angle
      new_physics(p).run_tic(p, Doom::Game::Ticcmd.new(0, 0, 10.0, 0))
      expect(p.angle - before).to be_within(1e-12).of(10.0 * Math::PI / 180.0)
    end

    it 'strafes perpendicular to facing' do
      p = new_player
      p.angle_degrees = 0    # facing +x
      phys = new_physics(p)
      run(p, phys, Array.new(10) { Doom::Game::Ticcmd.new(0.0, 1.0, 0.0, 0) })

      # Strafing right from +x heading moves toward -y.
      expect(p.y).to be < START[1]
      expect(p.x).to be_within(1.0).of(START[0])
    end

    it 'keeps the player inside the map when walking into a wall' do
      p = new_player
      phys = new_physics(p)
      run(p, phys, Array.new(400) { forward })

      expect(@map.sector_at(p.x, p.y)).not_to be_nil
    end
  end
end
