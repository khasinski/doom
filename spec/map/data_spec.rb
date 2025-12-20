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
end
