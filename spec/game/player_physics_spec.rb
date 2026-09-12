# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Game::PlayerPhysics do
  # Build a minimal map with two sectors separated by one two-sided linedef.
  # Sector 0: square (0,0)-(200,200), floor=0, ceiling=128
  # Sector 1: extends past the linedef to the east, floor configurable, ceiling=128
  def build_map(back_floor: 0, back_ceiling: 128, ml_blocking: false, things: [])
    vertices = [
      Doom::Map::Vertex.new(0, 0),
      Doom::Map::Vertex.new(200, 0),
      Doom::Map::Vertex.new(200, 200),
      Doom::Map::Vertex.new(0, 200),
      Doom::Map::Vertex.new(400, 0),
      Doom::Map::Vertex.new(400, 200)
    ]
    sectors = [
      Doom::Map::Sector.new(0, 128, 'FLOOR', 'CEIL', 192, 0, 0),
      Doom::Map::Sector.new(back_floor, back_ceiling, 'FLOOR', 'CEIL', 192, 0, 0)
    ]
    sidedefs = [
      Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 0),
      Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 1),
      Doom::Map::Sidedef.new(0, 0, 'WALL', '-', '-', 0),
      Doom::Map::Sidedef.new(0, 0, 'WALL', '-', '-', 1)
    ]
    flags = ml_blocking ? 0x0001 : 0
    linedefs = [
      # Two-sided linedef separating sector 0 and 1 along x=200
      Doom::Map::Linedef.new(1, 2, flags, 0, 0, 0, 1),
      # One-sided walls bounding the rooms
      Doom::Map::Linedef.new(0, 1, 0, 0, 0, 2, 0xFFFF),
      Doom::Map::Linedef.new(2, 3, 0, 0, 0, 2, 0xFFFF),
      Doom::Map::Linedef.new(3, 0, 0, 0, 0, 2, 0xFFFF),
      Doom::Map::Linedef.new(2, 5, 0, 0, 0, 3, 0xFFFF),
      Doom::Map::Linedef.new(5, 4, 0, 0, 0, 3, 0xFFFF),
      Doom::Map::Linedef.new(4, 1, 0, 0, 0, 3, 0xFFFF)
    ]
    fake_map(vertices, linedefs, sidedefs, sectors, things)
  end

  def fake_map(vertices, linedefs, sidedefs, sectors, things)
    map = Object.new
    map.define_singleton_method(:vertices) { vertices }
    map.define_singleton_method(:linedefs) { linedefs }
    map.define_singleton_method(:sidedefs) { sidedefs }
    map.define_singleton_method(:sectors) { sectors }
    map.define_singleton_method(:things) { things }
    # Cheap sector_at: x in [0,200) -> sector 0, [200,400) -> sector 1
    map.define_singleton_method(:sector_at) do |x, y|
      next nil if y < 0 || y >= 200 || x < 0 || x >= 400

      x < 200 ? sectors[0] : sectors[1]
    end
    map
  end

  let(:player_state) { Doom::Game::PlayerState.new }
  let(:physics) { described_class.new(map, player_state) }

  describe '#valid_move?' do
    let(:map) { build_map }

    it 'allows a small step within the same sector' do
      physics.settle_at(50, 100)
      expect(physics.valid_move?(50, 100, 60, 100)).to be true
    end

    it 'allows step-up of <= 24 units' do
      m = build_map(back_floor: 24)
      physics_24 = described_class.new(m, player_state)
      physics_24.settle_at(50, 100)
      # Cross x=200 boundary into sector 1 with floor 24 above
      expect(physics_24.valid_move?(50, 100, 250, 100)).to be true
    end

    it 'blocks step-up of > 24 units' do
      m = build_map(back_floor: 25)
      physics_25 = described_class.new(m, player_state)
      physics_25.settle_at(50, 100)
      expect(physics_25.valid_move?(50, 100, 250, 100)).to be false
    end

    it 'allows step-down of any size (cliffs)' do
      m = build_map(back_floor: -200)
      physics_drop = described_class.new(m, player_state)
      physics_drop.settle_at(50, 100)
      expect(physics_drop.valid_move?(50, 100, 250, 100)).to be true
    end

    it 'blocks crossing a one-sided linedef (wall)' do
      physics.settle_at(50, 100)
      # Wall at y=0 (linedef 0->1, sidedef_left=0xFFFF)
      expect(physics.valid_move?(50, 50, 50, -10)).to be false
    end

    # Regression: at the base of tall stairs a falling player can slide so its
    # radius overlaps the ledge line, then land wedged -- every direction blocked
    # by the proximity step-up check. A body already overlapping the ledge must
    # be able to move away, while still being unable to climb it.
    context 'when already overlapping the base of a tall step (a landed wedge)' do
      let(:map) { build_map(back_floor: 100) } # 100-unit step, impassable

      before { physics.settle_at(190, 100) } # feet on floor 0, radius grazes x=200

      it 'lets the player move away from the ledge to unstick' do
        # x=190 (10u from the line) -> x=185 (15u away): still overlapping, but
        # farther, so the move is allowed.
        expect(physics.valid_move?(190, 100, 185, 100)).to be true
      end

      it 'still refuses to move further into or onto the step' do
        expect(physics.valid_move?(190, 100, 195, 100)).to be false
      end

      it 'still blocks a normal approach into the ledge from clear ground' do
        expect(physics.valid_move?(170, 100, 190, 100)).to be false
      end
    end

    it 'blocks ML_BLOCKING two-sided linedefs even with passable geometry' do
      m = build_map(ml_blocking: true)
      blocked = described_class.new(m, player_state)
      blocked.settle_at(50, 100)
      expect(blocked.valid_move?(50, 100, 250, 100)).to be false
    end

    it 'blocks moves that bring player within radius of a solid thing' do
      m = build_map(things: [Doom::Map::Thing.new(150, 100, 0, 2035, 0)]) # Barrel
      with_thing = described_class.new(m, player_state)
      with_thing.settle_at(50, 100)
      # Barrel radius 10 + player radius 16 = 26, so x=125 is within 26 of x=150
      expect(with_thing.valid_move?(50, 100, 125, 100)).to be false
      # x=120 is 30 away — outside the combined radius
      expect(with_thing.valid_move?(50, 100, 118, 100)).to be true
    end

    it 'returns false when moving outside any sector' do
      physics.settle_at(50, 100)
      expect(physics.valid_move?(50, 100, -50, 100)).to be false
    end
  end

  describe '#settle_at and step-up smoothing' do
    it 'snaps floor_z up when entering a higher sector and notifies player_state' do
      m = build_map(back_floor: 16)
      p = described_class.new(m, player_state)
      p.settle_at(50, 100)
      expect(p.floor_z).to eq 0
      p.settle_at(250, 100)
      expect(p.floor_z).to eq 16
      expect(player_state.viewheight).to be < Doom::Game::PlayerState::VIEWHEIGHT
    end

    it 'leaves floor_z unchanged when entering a lower sector (gravity will drop)' do
      m = build_map(back_floor: -100)
      p = described_class.new(m, player_state)
      p.settle_at(50, 100)
      expect(p.floor_z).to eq 0
      p.settle_at(250, 100)
      expect(p.floor_z).to eq 0 # Did not snap down
    end
  end

  describe '#step (gravity)' do
    let(:map) { build_map(back_floor: -100) }

    it 'does nothing when feet match the sector floor' do
      physics.settle_at(50, 100)
      physics.step(50, 100)
      expect(physics.floor_z).to eq 0
      expect(physics.momz).to eq 0.0
    end

    it 'kicks momz to -2 on the first tic in the air' do
      physics.settle_at(50, 100)
      physics.settle_at(250, 100) # walked off the cliff
      physics.step(250, 100)
      expect(physics.momz).to eq(-2.0)
      expect(physics.floor_z).to eq(-2.0)
    end

    it 'accelerates by GRAVITY each subsequent tic' do
      physics.settle_at(50, 100)
      physics.settle_at(250, 100)
      physics.step(250, 100)  # momz: -2, z: -2
      physics.step(250, 100)  # momz: -3, z: -5
      physics.step(250, 100)  # momz: -4, z: -9
      expect(physics.momz).to eq(-4.0)
      expect(physics.floor_z).to eq(-9.0)
    end

    it 'clamps to ground and zeroes momz on landing' do
      physics.settle_at(50, 100)
      physics.settle_at(250, 100)
      30.times { physics.step(250, 100) } # plenty of ticks to hit -100
      expect(physics.floor_z).to eq(-100)
      expect(physics.momz).to eq(0.0)
    end

    it 'triggers viewheight squat when impact momz exceeds threshold' do
      physics.settle_at(50, 100)
      physics.settle_at(250, 100)
      30.times { physics.step(250, 100) }
      # apply_fall_impact set deltaviewheight to a negative value
      expect(player_state.deltaviewheight).to be < 0
    end

    it 'does not squat for a tiny drop (momz stays above threshold)' do
      shallow = build_map(back_floor: -3)
      p = described_class.new(shallow, player_state)
      p.settle_at(50, 100)
      p.settle_at(250, 100)
      # Tic 1: momz -2, z -2. Tic 2: momz -3, z -5 -> clamped to -3, momz still -3 > -8
      p.step(250, 100)
      p.step(250, 100)
      expect(p.floor_z).to eq(-3)
      expect(player_state.deltaviewheight).to eq 0.0
    end

    it 'snaps up smoothly when a lift rises beneath the player' do
      lift_map = build_map(back_floor: 0)
      lift_p = described_class.new(lift_map, player_state)
      lift_p.settle_at(250, 100)
      # Simulate the back sector floor rising
      lift_map.sectors[1].floor_height = 16
      lift_p.step(250, 100)
      expect(lift_p.floor_z).to eq 16
      expect(player_state.viewheight).to be < Doom::Game::PlayerState::VIEWHEIGHT
    end
  end

  describe '#eye_z' do
    let(:map) { build_map }

    it 'is nil before any settle' do
      expect(physics.eye_z).to be_nil
    end

    it 'is floor + viewheight + bob after settling' do
      physics.settle_at(50, 100)
      expect(physics.eye_z).to eq(Doom::Game::PlayerState::VIEWHEIGHT)
    end
  end

  describe '#reset' do
    let(:map) { build_map }

    it 'clears floor_z and momz' do
      physics.settle_at(50, 100)
      physics.reset
      expect(physics.floor_z).to be_nil
      expect(physics.momz).to eq 0.0
    end
  end

  describe '#compute_slide' do
    let(:map) { build_map }

    it 'projects movement along the wall when blocked' do
      physics.settle_at(50, 100)
      # Move into the south wall (linedef 0->1 at y=0): dy<0, dx=10
      slide = physics.compute_slide(50, 18, 10, -10)
      expect(slide).not_to be_nil
      sx, sy = slide
      # Slide should keep the x component, kill the y (wall is along x)
      expect(sx).to be_within(0.001).of(10.0)
      expect(sy).to be_within(0.001).of(0.0)
    end

    it 'returns nil when no wall blocks' do
      physics.settle_at(50, 100)
      expect(physics.compute_slide(50, 100, 5, 5)).to be_nil
    end
  end
end
