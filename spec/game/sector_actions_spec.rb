# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/doom/game/sector_actions'

RSpec.describe Doom::Game::SectorActions do
  # Build a minimal map: two sectors connected by one two-sided linedef.
  # Sector 0 (room): floor 0, ceiling 128.
  # Sector 1 (door): floor 0, ceiling 0 (closed). tag=1, can become a door.
  def build_map(door_special: 0, door_tag: 0, door_floor: 0, door_ceiling: 0,
                room_special: 0, things: [])
    vertices = [
      Doom::Map::Vertex.new(0, 0),
      Doom::Map::Vertex.new(64, 0),
      Doom::Map::Vertex.new(64, 64),
      Doom::Map::Vertex.new(0, 64),
      Doom::Map::Vertex.new(128, 0),
      Doom::Map::Vertex.new(128, 64),
    ]
    sectors = [
      Doom::Map::Sector.new(0, 128, 'F', 'C', 192, room_special, 0),
      Doom::Map::Sector.new(door_floor, door_ceiling, 'F', 'C', 192, 0, door_tag),
    ]
    sidedefs = [
      Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 0),  # room side of door linedef
      Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 1),  # door side of door linedef
      Doom::Map::Sidedef.new(0, 0, 'W', '-', '-', 0),  # one-sided walls of room
      Doom::Map::Sidedef.new(0, 0, 'W', '-', '-', 1),  # one-sided walls of door sector
    ]
    flags = 0x0004  # TWOSIDED
    linedefs = [
      Doom::Map::Linedef.new(1, 2, flags, door_special, door_tag, 0, 1),  # door linedef (room->door)
      Doom::Map::Linedef.new(0, 1, 0, 0, 0, 2, 0xFFFF),
      Doom::Map::Linedef.new(2, 3, 0, 0, 0, 2, 0xFFFF),
      Doom::Map::Linedef.new(3, 0, 0, 0, 0, 2, 0xFFFF),
      Doom::Map::Linedef.new(2, 5, 0, 0, 0, 3, 0xFFFF),
      Doom::Map::Linedef.new(5, 4, 0, 0, 0, 3, 0xFFFF),
      Doom::Map::Linedef.new(4, 1, 0, 0, 0, 3, 0xFFFF),
    ]
    fake_map(vertices, linedefs, sidedefs, sectors, things: things)
  end

  def fake_map(vertices, linedefs, sidedefs, sectors, things: [])
    map = Object.new
    map.define_singleton_method(:vertices) { vertices }
    map.define_singleton_method(:linedefs) { linedefs }
    map.define_singleton_method(:sidedefs) { sidedefs }
    map.define_singleton_method(:sectors) { sectors }
    map.define_singleton_method(:things) { things }
    map.define_singleton_method(:sector_at) do |x, _y|
      x < 64 ? sectors[0] : (x < 128 ? sectors[1] : nil)
    end
    # subsector_at is used by check_secrets; return a stub when player is in sector 0.
    map.define_singleton_method(:subsector_at) do |_x, _y|
      Struct.new(:first_seg).new(0)
    end
    map.define_singleton_method(:segs) do
      [Struct.new(:linedef, :direction).new(1, 0)]  # references linedef 1 (room wall)
    end
    map
  end

  let(:actions) { described_class.new(map) }

  describe 'use door (special 1)' do
    let(:map) { build_map(door_special: 1) }
    let(:linedef) { map.linedefs[0] }
    let(:door_sector) { map.sectors[1] }

    it 'opens the door when used' do
      actions.use_linedef(linedef, 0)
      # Walk a few tics; ceiling rises by DOOR_SPEED (2) per tic
      6.times { actions.update }
      expect(door_sector.ceiling_height).to eq(12)
    end

    it 'reaches lowest-adjacent-ceiling minus 4 and waits' do
      actions.use_linedef(linedef, 0)
      # Adjacent room ceiling is 128, so target = 124. 124/2 = 62 tics to open.
      62.times { actions.update }
      expect(door_sector.ceiling_height).to eq(124)
      # Should now be in DOOR_OPEN state (waiting)
      expect(actions.instance_variable_get(:@active_doors)[1][:state])
        .to eq(Doom::Game::SectorActions::DOOR_OPEN)
    end

    it 'closes after waiting and removes itself when fully closed' do
      actions.use_linedef(linedef, 0)
      62.times { actions.update }   # opening complete, in DOOR_OPEN
      150.times { actions.update }  # DOOR_WAIT tics
      62.times { actions.update }   # closing complete
      expect(door_sector.ceiling_height).to eq(0)
      expect(actions.instance_variable_get(:@active_doors)).to be_empty
    end

    it 'reopens when the player stands under it while closing' do
      actions.use_linedef(linedef, 0)
      62.times { actions.update }   # opened
      150.times { actions.update }  # waited
      actions.update                # one closing tic; ceiling at 122
      actions.update_player_position(96, 32)  # in door sector
      actions.update                # checks player sector, reopens
      door = actions.instance_variable_get(:@active_doors)[1]
      expect(door[:state]).to eq(Doom::Game::SectorActions::DOOR_OPENING)
    end
  end

  describe 'D1 stay-open door (special 31)' do
    let(:map) { build_map(door_special: 31) }

    it 'opens and stays open without closing' do
      actions.use_linedef(map.linedefs[0], 0)
      62.times { actions.update }
      # active door is removed when stay_open completes
      expect(actions.instance_variable_get(:@active_doors)).to be_empty
      expect(map.sectors[1].ceiling_height).to eq(124)
    end
  end

  describe 'tagged door (S1, special 103)' do
    let(:map) { build_map(door_special: 103, door_tag: 5) }

    it 'opens sectors matching the linedef tag' do
      actions.use_linedef(map.linedefs[0], 0)
      6.times { actions.update }
      expect(map.sectors[1].ceiling_height).to be > 0
    end

    it 'does nothing when tag is 0' do
      no_tag_map = build_map(door_special: 103, door_tag: 0)
      a = described_class.new(no_tag_map)
      a.use_linedef(no_tag_map.linedefs[0], 0)
      6.times { a.update }
      expect(no_tag_map.sectors[1].ceiling_height).to eq(0)
    end
  end

  describe 'lift (special 62)' do
    # Sector 0 floor=64, ceiling=128. Sector 1 floor=64 (lift), ceiling=128. Tag 7.
    def lift_map
      m = build_map(door_special: 62, door_tag: 7, door_floor: 64, door_ceiling: 128)
      m.sectors[0].floor_height = 0  # adjacent floor lower than lift
      m
    end

    it 'lowers the floor to the lowest adjacent then waits then raises' do
      m = lift_map
      a = described_class.new(m)
      a.use_linedef(m.linedefs[0], 0)
      # Lift starts at 64, lowers to 0 (lowest adjacent) at LIFT_SPEED=4 per tic
      16.times { a.update }
      expect(m.sectors[1].floor_height).to eq(0)
      # Wait phase
      105.times { a.update }
      # Raising back to 64
      16.times { a.update }
      expect(m.sectors[1].floor_height).to eq(64)
      expect(a.instance_variable_get(:@active_lifts)).to be_empty
    end
  end

  describe 'use exit (special 11)' do
    let(:map) { build_map(door_special: 11) }

    it 'sets exit_triggered to :normal' do
      actions.use_linedef(map.linedefs[0], 0)
      expect(actions.exit_triggered).to eq(:normal)
    end
  end

  describe 'use secret exit (special 51)' do
    let(:map) { build_map(door_special: 51) }

    it 'sets exit_triggered to :secret' do
      actions.use_linedef(map.linedefs[0], 0)
      expect(actions.exit_triggered).to eq(:secret)
    end
  end

  describe 'walk-trigger W1 exit (special 52)' do
    # The walk-trigger detection requires the linedef to be near the player
    # AND for the player to cross sides. Place player on the room side, move
    # them across the linedef boundary at x=64.
    let(:map) { build_map(door_special: 52, door_tag: 1) }

    it 'fires once when the player crosses the line' do
      actions.update_player_position(50, 32)  # near, room side
      actions.update                          # records prev_side
      actions.update_player_position(80, 32)  # near, door side -- crossed
      actions.update
      expect(actions.exit_triggered).to eq(:normal)
    end

    it 'does not retrigger after the first crossing' do
      actions.update_player_position(50, 32)
      actions.update
      actions.update_player_position(80, 32)
      actions.update
      actions.exit_triggered = nil if actions.respond_to?(:exit_triggered=)
      # Cross back
      actions.update_player_position(50, 32)
      actions.update
      # W1 only fires once -- @crossed_linedefs blocks further triggers
      crossed = actions.instance_variable_get(:@crossed_linedefs)
      expect(crossed[0]).to be true
    end
  end

  describe 'secret sector discovery' do
    let(:map) { build_map(room_special: 9) }  # Sector 0 is a secret

    it 'records the secret when the player enters and clears the special' do
      actions.update_player_position(32, 32)
      actions.update
      expect(actions.secrets_found).to include(0 => true)
      expect(map.sectors[0].special).to eq(0)
    end

    it 'does not retrigger on subsequent updates' do
      actions.update_player_position(32, 32)
      actions.update
      first_count = actions.secrets_found.size
      actions.update
      expect(actions.secrets_found.size).to eq(first_count)
    end
  end

  describe 'walk-trigger raise floor to lowest ceiling (special 5)' do
    # Sector 1 (tagged) floor starts at 0; its only neighbour, sector 0, has
    # ceiling 128, so the raiseFloor mover should target 128.
    let(:map) { build_map(door_special: 5, door_tag: 1, door_floor: 0, door_ceiling: 128) }

    it 'raises the tagged floor to the lowest surrounding ceiling, animated' do
      actions.update_player_position(50, 32)  # room side
      actions.update
      actions.update_player_position(80, 32)  # door side -- crosses the line
      actions.update                          # crossing registers the mover

      actions.update                          # one movement tic
      expect(map.sectors[1].floor_height).to eq(Doom::Game::SectorActions::LIFT_SPEED)

      100.times { actions.update }
      expect(map.sectors[1].floor_height).to eq(128)
    end
  end

  describe 'lower floor to lowest (special 23)' do
    # Sector 1 (tagged) floor starts at 64; adjacent sector 0 floor is 0.
    let(:map) { build_map(door_special: 23, door_tag: 1, door_floor: 64, door_ceiling: 128) }

    it 'animates the floor down to the lowest adjacent floor instead of snapping' do
      actions.use_linedef(map.linedefs[0], 0)

      actions.update
      expect(map.sectors[1].floor_height).to eq(64 - Doom::Game::SectorActions::LIFT_SPEED)

      100.times { actions.update }
      expect(map.sectors[1].floor_height).to eq(0)
    end
  end

  describe '#pop_teleport' do
    it 'returns nil when no teleport is queued' do
      m = build_map
      a = described_class.new(m)
      expect(a.pop_teleport).to be_nil
    end

    it 'returns the destination once and clears it' do
      teleport_thing = Doom::Map::Thing.new(96, 32, 90, 14, 0)
      m = build_map(door_special: 97, door_tag: 9, things: [teleport_thing])
      m.sectors[1].tag = 9

      a = described_class.new(m)
      a.update_player_position(50, 32)
      a.update
      a.update_player_position(80, 32)
      a.update

      dest = a.pop_teleport
      expect(dest).to eq(x: 96, y: 32, angle: 90)
      expect(a.pop_teleport).to be_nil
    end
  end
end
