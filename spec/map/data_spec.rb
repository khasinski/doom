# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Map::MapData do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
  end

  after(:all) do
    @wad&.close
  end

  describe '.load' do
    it 'loads map successfully' do
      expect(@map).not_to be_nil
      expect(@map.name).to eq('E1M1')
    end

    it 'raises error for invalid map' do
      expect { Doom::Map::MapData.load(@wad, 'E9M9') }.to raise_error(Doom::Error)
    end
  end

  describe '#things' do
    it 'loads things' do
      expect(@map.things).not_to be_empty
    end

    it 'has player 1 start (type 1)' do
      player_start = @map.things.find { |t| t.type == 1 }
      expect(player_start).not_to be_nil
    end

    it 'things have correct structure' do
      thing = @map.things.first
      expect(thing).to respond_to(:x, :y, :angle, :type, :flags)
    end
  end

  describe '#vertices' do
    it 'loads vertices' do
      expect(@map.vertices).not_to be_empty
    end

    it 'vertices have x and y' do
      vertex = @map.vertices.first
      expect(vertex).to respond_to(:x, :y)
      expect(vertex.x).to be_a(Integer)
      expect(vertex.y).to be_a(Integer)
    end
  end

  describe '#linedefs' do
    it 'loads linedefs' do
      expect(@map.linedefs).not_to be_empty
    end

    it 'linedefs reference valid vertices' do
      @map.linedefs.each do |linedef|
        expect(linedef.v1).to be < @map.vertices.size
        expect(linedef.v2).to be < @map.vertices.size
      end
    end

    it 'linedefs have correct flags' do
      two_sided = @map.linedefs.select(&:two_sided?)
      one_sided = @map.linedefs.reject(&:two_sided?)
      expect(two_sided).not_to be_empty
      expect(one_sided).not_to be_empty
    end
  end

  describe '#sidedefs' do
    it 'loads sidedefs' do
      expect(@map.sidedefs).not_to be_empty
    end

    it 'sidedefs have texture names' do
      sidedef = @map.sidedefs.first
      expect(sidedef).to respond_to(:upper_texture, :lower_texture, :middle_texture)
    end

    it 'sidedefs reference valid sectors' do
      @map.sidedefs.each do |sidedef|
        expect(sidedef.sector).to be < @map.sectors.size
      end
    end
  end

  describe '#sectors' do
    it 'loads sectors' do
      expect(@map.sectors).not_to be_empty
    end

    it 'sectors have floor and ceiling heights' do
      sector = @map.sectors.first
      expect(sector.floor_height).to be_a(Integer)
      expect(sector.ceiling_height).to be_a(Integer)
      expect(sector.ceiling_height).to be >= sector.floor_height
    end

    it 'sectors have texture names' do
      sector = @map.sectors.first
      expect(sector.floor_texture).to be_a(String)
      expect(sector.ceiling_texture).to be_a(String)
    end

    it 'sectors have light levels' do
      @map.sectors.each do |sector|
        expect(sector.light_level).to be_between(0, 255)
      end
    end
  end

  describe '#segs' do
    it 'loads segs' do
      expect(@map.segs).not_to be_empty
    end

    it 'segs reference valid vertices' do
      @map.segs.each do |seg|
        expect(seg.v1).to be < @map.vertices.size
        expect(seg.v2).to be < @map.vertices.size
      end
    end

    it 'segs reference valid linedefs' do
      @map.segs.each do |seg|
        expect(seg.linedef).to be < @map.linedefs.size
      end
    end
  end

  describe '#subsectors' do
    it 'loads subsectors' do
      expect(@map.subsectors).not_to be_empty
    end

    it 'subsectors have valid seg references' do
      @map.subsectors.each do |ss|
        expect(ss.first_seg).to be < @map.segs.size
        expect(ss.first_seg + ss.seg_count).to be <= @map.segs.size
      end
    end
  end

  describe '#nodes' do
    it 'loads BSP nodes' do
      expect(@map.nodes).not_to be_empty
    end

    it 'nodes have partition line' do
      node = @map.nodes.first
      expect(node).to respond_to(:x, :y, :dx, :dy)
    end

    it 'nodes have bounding boxes' do
      node = @map.nodes.first
      expect(node.bbox_right).to respond_to(:top, :bottom, :left, :right)
      expect(node.bbox_left).to respond_to(:top, :bottom, :left, :right)
    end
  end

  describe '#player_start' do
    it 'returns player 1 start position' do
      start = @map.player_start
      expect(start).not_to be_nil
      expect(start.type).to eq(1)
    end

    # E1M1 player start is at (1056, -3616)
    it 'has correct coordinates for E1M1' do
      start = @map.player_start
      expect(start.x).to eq(1056)
      expect(start.y).to eq(-3616)
      expect(start.angle).to eq(90)
    end
  end

  describe 'multiplayer starts' do
    it 'reads all four co-op starts, in player order' do
      starts = @map.player_starts
      expect(starts.size).to eq(4)
      expect(starts.compact.map(&:type)).to eq([1, 2, 3, 4])
    end

    it 'places the co-op starts at distinct positions' do
      positions = @map.player_starts.compact.map { |t| [t.x, t.y] }
      expect(positions.uniq.size).to eq(positions.size)
    end

    it 'reads deathmatch starts' do
      dm = @map.deathmatch_starts
      expect(dm).not_to be_empty
      expect(dm.map(&:type).uniq).to eq([11])
    end

    it 'keeps deathmatch starts out of the co-op list' do
      expect(@map.player_starts.compact).not_to include(*@map.deathmatch_starts)
    end

    describe '#player_start_for' do
      it 'returns that player\'s own start' do
        expect(@map.player_start_for(0)).to equal(@map.player_starts[0])
        expect(@map.player_start_for(2)).to equal(@map.player_starts[2])
      end

      it 'falls back to player 1 for an id the map has no start for' do
        expect(@map.player_start_for(9)).to equal(@map.player_start)
      end
    end
  end

  describe '#sector_at' do
    it 'finds sector at player start' do
      start = @map.player_start
      sector = @map.sector_at(start.x, start.y)
      expect(sector).not_to be_nil
      expect(sector).to be_a(Doom::Map::Sector)
    end

    it 'returns consistent results' do
      sector1 = @map.sector_at(1056, -3616)
      sector2 = @map.sector_at(1056, -3616)
      expect(sector1).to eq(sector2)
    end
  end

  describe '#subsector_at' do
    it 'finds subsector at player start' do
      start = @map.player_start
      subsector = @map.subsector_at(start.x, start.y)
      expect(subsector).not_to be_nil
      expect(subsector).to be_a(Doom::Map::Subsector)
    end
  end

  # In-memory BSP traversal tests that don't require a WAD. Builds a tiny
  # tree by hand to exercise sector_at and subsector_at directly.
  describe 'BSP traversal (synthetic)' do
    # Two-leaf tree split by a vertical line at x=100.
    # Right child  (x >= 100) -> subsector 0 -> sector 0 (floor 0)
    # Left child   (x <  100) -> subsector 1 -> sector 1 (floor 64)
    let(:map) do
      m = Doom::Map::MapData.new('TEST')

      # Two sectors so we can tell which side we landed on.
      m.sectors << Doom::Map::Sector.new(0, 128, 'F', 'C', 192, 0, 0)
      m.sectors << Doom::Map::Sector.new(64, 128, 'F', 'C', 192, 0, 0)

      # Two sidedefs, one per sector.
      m.sidedefs << Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 0)
      m.sidedefs << Doom::Map::Sidedef.new(0, 0, '-', '-', '-', 1)

      # One linedef per side; segs reference these.
      m.linedefs << Doom::Map::Linedef.new(0, 0, 0, 0, 0, 0, 0xFFFF)  # for sector 0
      m.linedefs << Doom::Map::Linedef.new(0, 0, 0, 0, 0, 1, 0xFFFF)  # for sector 1

      # Segs: direction 0 -> use sidedef_right.
      m.segs << Doom::Map::Seg.new(0, 0, 0, 0, 0, 0)  # subsector 0's first seg
      m.segs << Doom::Map::Seg.new(0, 0, 0, 1, 0, 0)  # subsector 1's first seg

      # Subsectors point to their first seg.
      m.subsectors << Doom::Map::Subsector.new(1, 0)
      m.subsectors << Doom::Map::Subsector.new(1, 1)

      # One BSP node: vertical partition at x=100, dx=0, dy=1
      # point_on_side: right = (px - 100) * 1; left = (py - 0) * 0 = 0
      # right >= left when px >= 100 -> side 0 (right child)
      flag = Doom::Map::Node::SUBSECTOR_FLAG
      m.nodes << Doom::Map::Node.new(
        100, 0,        # partition origin (x=100, y=0)
        0, 1,          # partition direction (vertical, pointing +y)
        nil, nil,      # bboxes unused for traversal
        0 | flag,      # right child = subsector 0
        1 | flag       # left child = subsector 1
      )
      m
    end

    it 'returns the right-side subsector when x is east of the partition' do
      expect(map.subsector_at(150, 50)).to eq(map.subsectors[0])
    end

    it 'returns the left-side subsector when x is west of the partition' do
      expect(map.subsector_at(50, 50)).to eq(map.subsectors[1])
    end

    it 'sector_at follows the same partition' do
      expect(map.sector_at(150, 50).floor_height).to eq(0)
      expect(map.sector_at(50, 50).floor_height).to eq(64)
    end

    it 'classifies points exactly on the partition line as right (front)' do
      # right >= left, with both 0, picks side 0 (right child)
      expect(map.subsector_at(100, 50)).to eq(map.subsectors[0])
    end

    it 'still returns a subsector for points far outside any bbox' do
      # No bounds check in subsector_at -- it just walks the tree
      expect(map.subsector_at(1_000_000, 1_000_000)).to eq(map.subsectors[0])
      expect(map.subsector_at(-1_000_000, -1_000_000)).to eq(map.subsectors[1])
    end
  end

  describe '#each_linedef_near (blockmap)' do
    it 'falls back to scanning all linedefs when no blockmap is loaded' do
      m = Doom::Map::MapData.new('TEST')
      m.linedefs << Doom::Map::Linedef.new(0, 0, 0, 0, 0, 0, 0xFFFF)
      m.linedefs << Doom::Map::Linedef.new(0, 0, 0, 0, 0, 0, 0xFFFF)
      yielded = []
      m.each_linedef_near(0, 0, 100, 100) { |ld| yielded << ld }
      expect(yielded.size).to eq(2)
      expect(m.blockmap_loaded?).to be false
    end

    it 'parses a blockmap header and reports loaded' do
      # Header: origin (-100, -100), 2 cols, 2 rows. 4 block offsets, all
      # pointing to a single sentinel-then-terminator block.
      data = [
        -100, -100, 2, 2,                  # header
        12, 12, 12, 12,                    # 4 block offsets (in words)
        0, -1                              # block: 0x0000 prefix, 0xFFFF terminator
      ].pack('s<*')
      m = Doom::Map::MapData.new('TEST')
      m.load_blockmap(data)
      expect(m.blockmap_loaded?).to be true
      yielded = []
      m.each_linedef_near(0, 0, 0, 0) { |ld| yielded << ld }
      expect(yielded).to be_empty  # block is empty
    end
  end
end
