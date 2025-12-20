# frozen_string_literal: true

module Doom
  module Map
    Vertex = Struct.new(:x, :y)

    Thing = Struct.new(:x, :y, :angle, :type, :flags)

    Linedef = Struct.new(:v1, :v2, :flags, :special, :tag, :sidedef_right, :sidedef_left) do
      FLAGS = {
        BLOCKING: 0x0001,
        BLOCKMONSTERS: 0x0002,
        TWOSIDED: 0x0004,
        DONTPEGTOP: 0x0008,
        DONTPEGBOTTOM: 0x0010,
        SECRET: 0x0020,
        SOUNDBLOCK: 0x0040,
        DONTDRAW: 0x0080,
        MAPPED: 0x0100
      }.freeze

      def two_sided?
        (flags & FLAGS[:TWOSIDED]) != 0
      end

      def upper_unpegged?
        (flags & FLAGS[:DONTPEGTOP]) != 0
      end

      def lower_unpegged?
        (flags & FLAGS[:DONTPEGBOTTOM]) != 0
      end
    end

    Sidedef = Struct.new(:x_offset, :y_offset, :upper_texture, :lower_texture, :middle_texture, :sector)

    Sector = Struct.new(:floor_height, :ceiling_height, :floor_texture, :ceiling_texture, :light_level, :special, :tag)

    Seg = Struct.new(:v1, :v2, :angle, :linedef, :direction, :offset)

    Subsector = Struct.new(:seg_count, :first_seg)

    class Node
      SUBSECTOR_FLAG = 0x8000

      attr_reader :x, :y, :dx, :dy, :bbox_right, :bbox_left, :child_right, :child_left

      BBox = Struct.new(:top, :bottom, :left, :right)

      def initialize(x, y, dx, dy, bbox_right, bbox_left, child_right, child_left)
        @x = x
        @y = y
        @dx = dx
        @dy = dy
        @bbox_right = bbox_right
        @bbox_left = bbox_left
        @child_right = child_right
        @child_left = child_left
      end

      def right_is_subsector?
        (@child_right & SUBSECTOR_FLAG) != 0
      end

      def left_is_subsector?
        (@child_left & SUBSECTOR_FLAG) != 0
      end

      def right_index
        @child_right & ~SUBSECTOR_FLAG
      end

      def left_index
        @child_left & ~SUBSECTOR_FLAG
      end
    end

    class MapData
      attr_reader :name, :things, :vertices, :linedefs, :sidedefs, :sectors, :segs, :subsectors, :nodes

      def initialize(name)
        @name = name
        @things = []
        @vertices = []
        @linedefs = []
        @sidedefs = []
        @sectors = []
        @segs = []
        @subsectors = []
        @nodes = []
      end

      def self.load(wad, map_name)
        map = new(map_name)

        lump_idx = wad.directory.index { |e| e.name == map_name.upcase }
        raise Error, "Map #{map_name} not found" unless lump_idx

        map.load_things(wad.read_lump_at(wad.directory[lump_idx + 1]))
        map.load_linedefs(wad.read_lump_at(wad.directory[lump_idx + 2]))
        map.load_sidedefs(wad.read_lump_at(wad.directory[lump_idx + 3]))
        map.load_vertices(wad.read_lump_at(wad.directory[lump_idx + 4]))
        map.load_segs(wad.read_lump_at(wad.directory[lump_idx + 5]))
        map.load_subsectors(wad.read_lump_at(wad.directory[lump_idx + 6]))
        map.load_nodes(wad.read_lump_at(wad.directory[lump_idx + 7]))
        map.load_sectors(wad.read_lump_at(wad.directory[lump_idx + 8]))

        map
      end

      def load_things(data)
        count = data.size / 10
        count.times do |i|
          offset = i * 10
          @things << Thing.new(
            data[offset, 2].unpack1('s<'),
            data[offset + 2, 2].unpack1('s<'),
            data[offset + 4, 2].unpack1('v'),
            data[offset + 6, 2].unpack1('v'),
            data[offset + 8, 2].unpack1('v')
          )
        end
      end

      def load_vertices(data)
        count = data.size / 4
        count.times do |i|
          offset = i * 4
          @vertices << Vertex.new(
            data[offset, 2].unpack1('s<'),
            data[offset + 2, 2].unpack1('s<')
          )
        end
      end

      def load_linedefs(data)
        count = data.size / 14
        count.times do |i|
          offset = i * 14
          @linedefs << Linedef.new(
            data[offset, 2].unpack1('v'),
            data[offset + 2, 2].unpack1('v'),
            data[offset + 4, 2].unpack1('v'),
            data[offset + 6, 2].unpack1('v'),
            data[offset + 8, 2].unpack1('v'),
            data[offset + 10, 2].unpack1('s<'),
            data[offset + 12, 2].unpack1('s<')
          )
        end
      end

      def load_sidedefs(data)
        count = data.size / 30
        count.times do |i|
          offset = i * 30
          @sidedefs << Sidedef.new(
            data[offset, 2].unpack1('s<'),
            data[offset + 2, 2].unpack1('s<'),
            data[offset + 4, 8].delete("\x00").strip,
            data[offset + 12, 8].delete("\x00").strip,
            data[offset + 20, 8].delete("\x00").strip,
            data[offset + 28, 2].unpack1('v')
          )
        end
      end

      def load_sectors(data)
        count = data.size / 26
        count.times do |i|
          offset = i * 26
          @sectors << Sector.new(
            data[offset, 2].unpack1('s<'),
            data[offset + 2, 2].unpack1('s<'),
            data[offset + 4, 8].delete("\x00").strip,
            data[offset + 12, 8].delete("\x00").strip,
            data[offset + 20, 2].unpack1('v'),
            data[offset + 22, 2].unpack1('v'),
            data[offset + 24, 2].unpack1('v')
          )
        end
      end

      def load_segs(data)
        count = data.size / 12
        count.times do |i|
          offset = i * 12
          @segs << Seg.new(
            data[offset, 2].unpack1('v'),
            data[offset + 2, 2].unpack1('v'),
            data[offset + 4, 2].unpack1('s<'),
            data[offset + 6, 2].unpack1('v'),
            data[offset + 8, 2].unpack1('v'),
            data[offset + 10, 2].unpack1('s<')
          )
        end
      end

      def load_subsectors(data)
        count = data.size / 4
        count.times do |i|
          offset = i * 4
          @subsectors << Subsector.new(
            data[offset, 2].unpack1('v'),
            data[offset + 2, 2].unpack1('v')
          )
        end
      end

      def load_nodes(data)
        count = data.size / 28
        count.times do |i|
          offset = i * 28
          bbox_right = Node::BBox.new(
            data[offset + 8, 2].unpack1('s<'),
            data[offset + 10, 2].unpack1('s<'),
            data[offset + 12, 2].unpack1('s<'),
            data[offset + 14, 2].unpack1('s<')
          )
          bbox_left = Node::BBox.new(
            data[offset + 16, 2].unpack1('s<'),
            data[offset + 18, 2].unpack1('s<'),
            data[offset + 20, 2].unpack1('s<'),
            data[offset + 22, 2].unpack1('s<')
          )
          @nodes << Node.new(
            data[offset, 2].unpack1('s<'),
            data[offset + 2, 2].unpack1('s<'),
            data[offset + 4, 2].unpack1('s<'),
            data[offset + 6, 2].unpack1('s<'),
            bbox_right,
            bbox_left,
            data[offset + 24, 2].unpack1('v'),
            data[offset + 26, 2].unpack1('v')
          )
        end
      end

      def player_start
        @things.find { |t| t.type == 1 }
      end

      # Find the sector at a given position by traversing the BSP tree
      def sector_at(x, y)
        subsector = subsector_at(x, y)
        return nil unless subsector

        # Get sector from first seg of subsector
        seg = @segs[subsector.first_seg]
        return nil unless seg

        linedef = @linedefs[seg.linedef]
        sidedef_idx = seg.direction == 0 ? linedef.sidedef_right : linedef.sidedef_left
        return nil if sidedef_idx < 0

        @sectors[@sidedefs[sidedef_idx].sector]
      end

      # Find the subsector containing a point
      def subsector_at(x, y)
        node_idx = @nodes.size - 1
        while (node_idx & Node::SUBSECTOR_FLAG) == 0
          node = @nodes[node_idx]
          side = point_on_side(x, y, node)
          node_idx = side == 0 ? node.child_right : node.child_left
        end
        @subsectors[node_idx & ~Node::SUBSECTOR_FLAG]
      end

      private

      def point_on_side(x, y, node)
        dx = x - node.x
        dy = y - node.y
        left = dy * node.dx
        right = dx * node.dy
        right >= left ? 0 : 1
      end
    end
  end
end
