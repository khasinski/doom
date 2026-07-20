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

        # BLOCKMAP is at lump +10 (REJECT is +9). Optional -- parse defensively.
        blockmap_entry = wad.directory[lump_idx + 10]
        if blockmap_entry && blockmap_entry.name == 'BLOCKMAP'
          map.load_blockmap(wad.read_lump_at(blockmap_entry))
        end

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

      # Thing types 1-4 are the co-op starts for players 1-4; type 11 is a
      # deathmatch spawn point. Every stock WAD carries all of them -- until
      # now only type 1 was ever read.
      COOP_START_TYPES = (1..4).to_a.freeze
      DEATHMATCH_START_TYPE = 11

      def player_start
        @things.find { |t| t.type == 1 }
      end

      # Co-op starts indexed by player number, so player N spawns at start N.
      # Sparse on maps that only define some: index 2 may be nil while 0 is not.
      def player_starts
        COOP_START_TYPES.map { |type| @things.find { |t| t.type == type } }
      end

      # Start for player `id` (0-based), falling back to player 1's start so a
      # map without enough co-op starts is still playable.
      def player_start_for(id)
        player_starts[id] || player_start
      end

      def deathmatch_starts
        @things.select { |t| t.type == DEATHMATCH_START_TYPE }
      end

      # BLOCKMAP: 128-unit grid index into linedefs. Each block lists the
      # linedefs that touch it. Used for fast collision lookup.
      BLOCKMAP_BLOCK_SIZE = 128

      def load_blockmap(data)
        return if data.nil? || data.size < 8

        @blockmap_origin_x = data[0, 2].unpack1('s<')
        @blockmap_origin_y = data[2, 2].unpack1('s<')
        @blockmap_cols = data[4, 2].unpack1('s<')
        @blockmap_rows = data[6, 2].unpack1('s<')
        return if @blockmap_cols <= 0 || @blockmap_rows <= 0

        block_count = @blockmap_cols * @blockmap_rows
        @blockmap_blocks = Array.new(block_count)

        block_count.times do |i|
          offset_words = data[8 + i * 2, 2].unpack1('v')
          byte_offset = offset_words * 2
          linedefs_in_block = []
          ptr = byte_offset
          # Skip the leading 0x0000 sentinel that some blockmaps include.
          ptr += 2 if ptr + 2 <= data.size && data[ptr, 2].unpack1('s<') == 0
          while ptr + 2 <= data.size
            idx = data[ptr, 2].unpack1('s<')
            break if idx == -1  # 0xFFFF terminator
            linedefs_in_block << idx
            ptr += 2
          end
          @blockmap_blocks[i] = linedefs_in_block
        end
      end

      # Yield each linedef whose block overlaps the bounding box (min_x, min_y,
      # max_x, max_y). Yields each linedef at most once per call. Falls back
      # to iterating all linedefs if no blockmap is loaded.
      def each_linedef_near(min_x, min_y, max_x, max_y)
        unless @blockmap_blocks
          @linedefs.each { |ld| yield ld }
          return
        end

        bx0 = ((min_x - @blockmap_origin_x) / BLOCKMAP_BLOCK_SIZE).floor.clamp(0, @blockmap_cols - 1)
        bx1 = ((max_x - @blockmap_origin_x) / BLOCKMAP_BLOCK_SIZE).floor.clamp(0, @blockmap_cols - 1)
        by0 = ((min_y - @blockmap_origin_y) / BLOCKMAP_BLOCK_SIZE).floor.clamp(0, @blockmap_rows - 1)
        by1 = ((max_y - @blockmap_origin_y) / BLOCKMAP_BLOCK_SIZE).floor.clamp(0, @blockmap_rows - 1)

        seen = {}
        by0.upto(by1) do |by|
          row_base = by * @blockmap_cols
          bx0.upto(bx1) do |bx|
            indices = @blockmap_blocks[row_base + bx]
            next unless indices
            indices.each do |idx|
              next if seen[idx]
              seen[idx] = true
              yield @linedefs[idx]
            end
          end
        end
      end

      def blockmap_loaded?
        !@blockmap_blocks.nil?
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
