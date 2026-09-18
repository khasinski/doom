# frozen_string_literal: true

require_relative "spinel_native/kernel"

module Doom
  module Render
    # Runs the classic software renderer's hot path (BSP -> textured walls ->
    # floors/ceilings -> sky) through spinel_native. The pixel-producing code
    # lives in Doom::Render::SpinelNative::Kernel as native methods that mirror
    # lib/doom/render/renderer.rb one-to-one; this class only flattens the map,
    # textures and flats into the plain Integer/Float arrays the kernel boundary
    # accepts, then calls it once per frame and hands back the framebuffer.
    #
    # The same kernel methods run as plain Ruby when SPINEL_NATIVE=off, so the
    # port can be verified against the reference renderer before compiling.
    class SpinelNativeRenderer
      SCREEN_WIDTH = 320
      SCREEN_HEIGHT = 240
      EYE_HEIGHT = 41

      attr_reader :palette

      def initialize(map, palette, colormap, textures, flats)
        @map = map
        @palette = palette
        flatten_all(map, colormap, textures, flats)
        upload
      end

      # Upload the flattened map/textures into the kernel's state once.
      def upload
        SpinelNative::Kernel.load_map(
          @nodes_f, @verts, @segs, @subs, @lines, @sides, @secs,
          @wpx, @wtab, @fpx, @cmap, @node_count, @sky_tex
        )
      end

      # Render one frame from the given eye pose. Returns a 76800-int framebuffer
      # of palette indices (row-major, 320x240).
      def render(px, py, angle_rad)
        pz = floor_height_at(px, py) + EYE_HEIGHT
        SpinelNative::Kernel.render(px.round, py.round, pz, angle_rad)
      end

      # Render with an explicit eye height (the game supplies player_z), for
      # integration into the real Renderer.
      def render_at(px, py, pz, angle_rad)
        SpinelNative::Kernel.render(px.round, py.round, pz.round, angle_rad)
      end

      # Wall-pass outputs from the last render, for the Ruby sprite pass.
      def ceiling_clip = SpinelNative::Kernel.get_cclip
      def floor_clip = SpinelNative::Kernel.get_fclip
      def wall_depth = SpinelNative::Kernel.get_wdepth

      # Eye height follows the floor under the player (classic pz = floorz + 41).
      def floor_height_at(x, y)
        ni = @node_count - 1
        while (ni & 0x8000).zero?
          b = ni * 6
          side = (x.to_f - @nodes_f[b]) * @nodes_f[b + 3] >= (y.to_f - @nodes_f[b + 1]) * @nodes_f[b + 2] ? 0 : 1
          ni = (side.zero? ? @nodes_f[b + 4] : @nodes_f[b + 5]).to_i
        end
        first = @subs[(ni & 0x7FFF) * 2]
        sdi = @lines[@segs[first * 5 + 2] * 3 + (@segs[first * 5 + 3].zero? ? 0 : 1)]
        @secs[@sides[sdi * 6] * 6]
      end

      private

      def flatten_all(map, colormap, textures, flats)
        # --- wall textures (composited, column-major) + name->index ------------
        @wall_index = {}
        @wall_names = []
        map.sidedefs.each do |sd|
          add_wall(sd.upper_texture); add_wall(sd.lower_texture); add_wall(sd.middle_texture)
        end
        @sky_tex = add_wall("SKY1")

        @wpx = []
        @wtab = []
        @wall_names.each do |name|
          comp = textures[name]
          if comp.nil?
            @wtab.push(@wpx.length, 1, 1); @wpx.push(-1); next
          end
          @wtab.push(@wpx.length, comp.width, comp.height)
          tx = 0
          while tx < comp.width
            col = comp.column_pixels(tx)
            ty = 0
            while ty < comp.height
              c = col[ty]
              @wpx.push(c.nil? ? -1 : c) # -1 = transparent texel (skipped)
              ty += 1
            end
            tx += 1
          end
        end

        # --- flats (64x64 row-major) + name->index ----------------------------
        @flat_index = {}
        @fpx = []
        idx = 0
        flats.each do |fl|
          @flat_index[fl.name] = idx
          @fpx.concat(fl.pixels)
          idx += 1
        end

        # --- colormap (flat 34*256) ------------------------------------------
        @cmap = colormap.respond_to?(:maps) ? flatten_colormap(colormap.maps) : colormap

        # --- geometry ---------------------------------------------------------
        @nodes_f = []
        map.nodes.each { |n| @nodes_f.push(n.x.to_f, n.y.to_f, n.dx.to_f, n.dy.to_f, n.child_right.to_f, n.child_left.to_f) }
        @verts = []
        map.vertices.each { |v| @verts.push(v.x, v.y) }
        @segs = []
        map.segs.each { |s| @segs.push(s.v1, s.v2, s.linedef, s.direction, s.offset) }
        @subs = []
        map.subsectors.each { |s| @subs.push(s.first_seg, s.seg_count) }
        @lines = []
        map.linedefs.each { |l| @lines.push(l.sidedef_right, l.sidedef_left, l.flags) }
        @sides = []
        map.sidedefs.each do |sd|
          @sides.push(sd.sector, wall_idx(sd.upper_texture), wall_idx(sd.lower_texture),
                      wall_idx(sd.middle_texture), sd.x_offset, sd.y_offset)
        end
        @secs = []
        map.sectors.each do |s|
          @secs.push(s.floor_height, s.ceiling_height, s.light_level,
                     flat_idx(s.floor_texture), flat_idx(s.ceiling_texture),
                     s.ceiling_texture == "F_SKY1" ? 1 : 0,
                     s.floor_texture == "F_SKY1" ? 1 : 0)
        end
        @node_count = map.nodes.length
      end

      def flatten_colormap(maps)
        return maps if maps.first.is_a?(Integer) # already flat

        maps.flatten
      end

      def add_wall(name)
        return -1 if name.nil? || name.empty? || name == "-"

        key = name.upcase
        @wall_index[key] ||= begin
          @wall_names << key
          @wall_names.length - 1
        end
      end
      alias wall_idx add_wall

      def flat_idx(name)
        @flat_index[name] || @flat_index[name.to_s.upcase] || 0
      end
    end
  end
end
