# frozen_string_literal: true

module Doom
  module Render
    SCREEN_WIDTH = 320
    SCREEN_HEIGHT = 240
    HALF_WIDTH = SCREEN_WIDTH / 2
    HALF_HEIGHT = SCREEN_HEIGHT / 2
    FOV = 90.0

    # Silhouette types for sprite clipping (matches Chocolate Doom r_defs.h)
    SIL_NONE = 0
    SIL_BOTTOM = 1
    SIL_TOP = 2
    SIL_BOTH = 3

    # Drawseg stores wall segment info for sprite clipping
    # Matches Chocolate Doom's drawseg_t structure
    Drawseg = Struct.new(:x1, :x2, :scale1, :scale2,
                         :silhouette, :bsilheight, :tsilheight,
                         :sprtopclip, :sprbottomclip)

    # Visplane stores floor/ceiling rendering info for a sector
    # Matches Chocolate Doom's visplane_t structure from r_plane.c
    Visplane = Struct.new(:sector, :height, :texture, :light_level, :is_ceiling,
                          :top, :bottom, :minx, :maxx) do
      def initialize(sector, height, texture, light_level, is_ceiling)
        super(sector, height, texture, light_level, is_ceiling,
              Array.new(SCREEN_WIDTH, SCREEN_HEIGHT),  # top (initially invalid)
              Array.new(SCREEN_WIDTH, -1),             # bottom (initially invalid)
              SCREEN_WIDTH,                            # minx (no columns marked yet)
              -1)                                      # maxx (no columns marked yet)
      end

      def mark(x, y1, y2)
        return if y1 > y2
        top[x] = [top[x], y1].min
        bottom[x] = [bottom[x], y2].max
        self.minx = [minx, x].min
        self.maxx = [maxx, x].max
      end

      def valid?
        minx <= maxx
      end
    end

    class Renderer
      attr_reader :framebuffer

      def initialize(wad, map, textures, palette, colormap, flats, sprites = nil)
        @wad = wad
        @map = map
        @textures = textures
        @palette = palette
        @colormap = colormap
        @flats = flats.to_h { |f| [f.name, f] }
        @sprites = sprites

        @framebuffer = Array.new(SCREEN_WIDTH * SCREEN_HEIGHT, 0)

        @player_x = 0.0
        @player_y = 0.0
        @player_z = 41.0
        @player_angle = 0.0

        # Projection constant - distance to projection plane
        @projection = HALF_WIDTH / Math.tan(FOV * Math::PI / 360.0)

        # Clipping arrays
        @ceiling_clip = Array.new(SCREEN_WIDTH, -1)
        @floor_clip = Array.new(SCREEN_WIDTH, SCREEN_HEIGHT)

        # Sprite clip arrays (copy of wall clips for sprite clipping)
        @sprite_ceiling_clip = Array.new(SCREEN_WIDTH, -1)
        @sprite_floor_clip = Array.new(SCREEN_WIDTH, SCREEN_HEIGHT)

        # Wall depth array - tracks distance to nearest wall at each column
        @wall_depth = Array.new(SCREEN_WIDTH, Float::INFINITY)
      end

      attr_reader :player_x, :player_y, :player_z, :sin_angle, :cos_angle

      def set_player(x, y, z, angle)
        @player_x = x.to_f
        @player_y = y.to_f
        @player_z = z.to_f
        @player_angle = angle * Math::PI / 180.0
      end

      def move_to(x, y)
        @player_x = x.to_f
        @player_y = y.to_f
      end

      def set_z(z)
        @player_z = z.to_f
      end

      def turn(degrees)
        @player_angle += degrees * Math::PI / 180.0
      end

      def render_frame
        clear_framebuffer
        reset_clipping

        @sin_angle = Math.sin(@player_angle)
        @cos_angle = Math.cos(@player_angle)

        # Precompute column angles for floor/ceiling rendering
        precompute_column_data

        # Draw floor/ceiling background first (will be partially overwritten by walls)
        draw_floor_ceiling_background

        # Initialize visplanes for tracking visible floor/ceiling spans
        @visplanes = []

        # Initialize drawsegs for sprite clipping
        @drawsegs = []

        # Render walls via BSP traversal
        render_bsp_node(@map.nodes.size - 1)

        # Draw visplanes for sectors different from background
        draw_all_visplanes

        # Save wall clip arrays for sprite clipping
        @sprite_ceiling_clip = @ceiling_clip.dup
        @sprite_floor_clip = @floor_clip.dup
        @sprite_wall_depth = @wall_depth.dup

        # Render sprites
        render_sprites if @sprites
      end

      # Precompute column-based data for floor/ceiling rendering (R_InitLightTables-like)
      def precompute_column_data
        @column_cos ||= Array.new(SCREEN_WIDTH)
        @column_sin ||= Array.new(SCREEN_WIDTH)
        @column_distscale ||= Array.new(SCREEN_WIDTH)

        SCREEN_WIDTH.times do |x|
          dx = x - HALF_WIDTH
          column_angle = @player_angle - Math.atan2(dx, @projection)
          @column_cos[x] = Math.cos(column_angle)
          @column_sin[x] = Math.sin(column_angle)
          @column_distscale[x] = Math.sqrt(dx * dx + @projection * @projection) / @projection
        end
      end

      def draw_floor_ceiling_background
        player_sector = @map.sector_at(@player_x, @player_y)
        return unless player_sector

        fill_uncovered_with_sector(player_sector)
      end

      # Render all visplanes after BSP traversal (R_DrawPlanes in Chocolate Doom)
      def draw_all_visplanes
        @visplanes.each do |plane|
          next unless plane.valid?

          if plane.texture == 'F_SKY1'
            draw_sky_plane(plane)
          else
            render_visplane_spans(plane)
          end
        end
      end

      # Render visplane using horizontal spans (R_MakeSpans in Chocolate Doom)
      # This processes columns left-to-right, building spans and rendering them
      def render_visplane_spans(plane)
        return if plane.minx > plane.maxx

        spanstart = Array.new(SCREEN_HEIGHT)  # Track where each row's span started

        # Process columns left to right
        ((plane.minx)..(plane.maxx + 1)).each do |x|
          # Get current column bounds
          if x <= plane.maxx
            t2 = plane.top[x]
            b2 = plane.bottom[x]
            t2 = SCREEN_HEIGHT if t2 > b2  # Invalid = empty
          else
            t2, b2 = SCREEN_HEIGHT, -1  # Sentinel for final column
          end

          # Get previous column bounds
          if x > plane.minx
            t1 = plane.top[x - 1]
            b1 = plane.bottom[x - 1]
            t1 = SCREEN_HEIGHT if t1 > b1
          else
            t1, b1 = SCREEN_HEIGHT, -1
          end

          # Close spans that ended (visible in prev column, not in current)
          if t1 < SCREEN_HEIGHT
            # Rows visible in previous but not current (above current or below current)
            (t1..[b1, t2 - 1].min).each do |y|
              draw_span(plane, y, spanstart[y], x - 1) if spanstart[y]
              spanstart[y] = nil
            end
            ([t1, b2 + 1].max..b1).each do |y|
              draw_span(plane, y, spanstart[y], x - 1) if spanstart[y]
              spanstart[y] = nil
            end
          end

          # Open new spans (visible in current, not started yet)
          if t2 < SCREEN_HEIGHT
            (t2..b2).each do |y|
              spanstart[y] ||= x
            end
          end
        end
      end

      # Render one horizontal span with texture mapping (R_MapPlane in Chocolate Doom)
      def draw_span(plane, y, x1, x2)
        return if x1.nil? || x1 > x2 || y < 0 || y >= SCREEN_HEIGHT

        flat = @flats[plane.texture]
        return unless flat

        # Distance from horizon (y=100 for 200-high screen)
        dy = y - HALF_HEIGHT
        return if dy == 0

        # Plane height relative to player eye level
        plane_height = (plane.height - @player_z).abs
        return if plane_height == 0

        # Perpendicular distance to this row: distance = height * projection / dy
        perp_dist = plane_height * @projection / dy.abs

        # Calculate lighting for this distance
        light = calculate_flat_light(plane.light_level, perp_dist)
        cmap = @colormap.maps[light]

        # Cache locals for inner loop
        framebuffer = @framebuffer
        column_distscale = @column_distscale
        column_cos = @column_cos
        column_sin = @column_sin
        player_x = @player_x
        neg_player_y = -@player_y
        row_offset = y * SCREEN_WIDTH

        # Clamp to screen bounds
        x1 = 0 if x1 < 0
        x2 = SCREEN_WIDTH - 1 if x2 >= SCREEN_WIDTH

        # Draw each pixel in the span using while loop
        x = x1
        while x <= x2
          ray_dist = perp_dist * column_distscale[x]
          tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
          tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
          color = flat[tex_x, tex_y] || 0
          framebuffer[row_offset + x] = cmap[color]
          x += 1
        end
      end

      # Render sky ceiling as columns (column-based like walls, not spans)
      def draw_sky_plane(plane)
        sky_texture = @textures['SKY1']
        return unless sky_texture

        framebuffer = @framebuffer
        player_angle = @player_angle
        projection = @projection
        sky_width = sky_texture.width
        sky_height = sky_texture.height

        # Clamp to screen bounds
        minx = [plane.minx, 0].max
        maxx = [plane.maxx, SCREEN_WIDTH - 1].min

        (minx..maxx).each do |x|
          y1 = plane.top[x]
          y2 = plane.bottom[x]
          next if y1 > y2

          # Clamp y bounds
          y1 = 0 if y1 < 0
          y2 = SCREEN_HEIGHT - 1 if y2 >= SCREEN_HEIGHT

          # Sky X based on view angle (wraps around 256 degrees)
          column_angle = player_angle - Math.atan2(x - HALF_WIDTH, projection)
          sky_x = ((column_angle * 256 / Math::PI).to_i & 255) % sky_width
          column = sky_texture.column_pixels(sky_x)
          next unless column

          (y1..y2).each do |y|
            color = column[y % sky_height] || 0
            framebuffer[y * SCREEN_WIDTH + x] = color
          end
        end
      end

      def find_or_create_visplane(sector, height, texture, light_level, is_ceiling)
        # Find existing visplane with matching properties
        plane = @visplanes.find do |vp|
          vp.height == height &&
          vp.texture == texture &&
          vp.light_level == light_level &&
          vp.is_ceiling == is_ceiling
        end

        unless plane
          plane = Visplane.new(sector, height, texture, light_level, is_ceiling)
          @visplanes << plane
        end

        plane
      end

      # R_CheckPlane equivalent - check if columns in range are already marked
      # If overlap exists, create a new visplane; otherwise update minx/maxx
      def check_plane(plane, start_x, stop_x)
        return plane unless plane

        # Calculate intersection and union of column ranges
        if start_x < plane.minx
          intrl = plane.minx
          unionl = start_x
        else
          unionl = plane.minx
          intrl = start_x
        end

        if stop_x > plane.maxx
          intrh = plane.maxx
          unionh = stop_x
        else
          unionh = plane.maxx
          intrh = stop_x
        end

        # Check if any column in intersection range is already marked
        # A column is marked if top[x] <= bottom[x] (valid range)
        overlap = false
        (intrl..intrh).each do |x|
          next if x < 0 || x >= SCREEN_WIDTH
          if plane.top[x] <= plane.bottom[x]
            overlap = true
            break
          end
        end

        if !overlap
          # No overlap - reuse same visplane with expanded range
          plane.minx = unionl if unionl < plane.minx
          plane.maxx = unionh if unionh > plane.maxx
          return plane
        end

        # Overlap detected - create new visplane with same properties
        new_plane = Visplane.new(
          plane.sector,
          plane.height,
          plane.texture,
          plane.light_level,
          plane.is_ceiling
        )
        new_plane.minx = start_x
        new_plane.maxx = stop_x
        @visplanes << new_plane
        new_plane
      end

      def fill_uncovered_with_sector(default_sector)
        # Cache all instance variables as locals for faster access
        framebuffer = @framebuffer
        column_cos = @column_cos
        column_sin = @column_sin
        column_distscale = @column_distscale
        projection = @projection
        player_angle = @player_angle
        player_x = @player_x
        neg_player_y = -@player_y

        ceil_height = (default_sector.ceiling_height - @player_z).abs
        floor_height = (default_sector.floor_height - @player_z).abs
        ceil_flat = @flats[default_sector.ceiling_texture]
        floor_flat = @flats[default_sector.floor_texture]
        is_sky = default_sector.ceiling_texture == 'F_SKY1'
        sky_texture = is_sky ? @textures['SKY1'] : nil
        light_level = default_sector.light_level
        colormap_maps = @colormap.maps

        # Precompute y_slope for each row (perpendicular distance)
        y_slope_ceil = Array.new(HALF_HEIGHT + 1, 0.0)
        y_slope_floor = Array.new(HALF_HEIGHT + 1, 0.0)
        (1..HALF_HEIGHT).each do |dy|
          y_slope_ceil[dy] = ceil_height * projection / dy.to_f
          y_slope_floor[dy] = floor_height * projection / dy.to_f
        end

        # Draw ceiling (rows 0 to HALF_HEIGHT-1) using while loops for speed
        y = 0
        while y < HALF_HEIGHT
          dy = HALF_HEIGHT - y
          if dy > 0
            perp_dist = y_slope_ceil[dy]
            if perp_dist > 0
              light = calculate_flat_light(light_level, perp_dist)
              cmap = colormap_maps[light]
              row_offset = y * SCREEN_WIDTH

              if is_sky && sky_texture
                sky_height = sky_texture.height
                sky_width = sky_texture.width
                sky_y = y % sky_height
                x = 0
                while x < SCREEN_WIDTH
                  column_angle = player_angle - Math.atan2(x - HALF_WIDTH, projection)
                  sky_x = ((column_angle * 256 / Math::PI).to_i & 255) % sky_width
                  color = sky_texture.column_pixels(sky_x)[sky_y] || 0
                  framebuffer[row_offset + x] = color
                  x += 1
                end
              elsif ceil_flat
                x = 0
                while x < SCREEN_WIDTH
                  ray_dist = perp_dist * column_distscale[x]
                  tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
                  tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
                  color = ceil_flat[tex_x, tex_y] || 0
                  framebuffer[row_offset + x] = cmap[color]
                  x += 1
                end
              end
            end
          end
          y += 1
        end

        # Draw floor (rows HALF_HEIGHT to SCREEN_HEIGHT-1)
        y = HALF_HEIGHT
        while y < SCREEN_HEIGHT
          dy = y - HALF_HEIGHT
          if dy > 0
            perp_dist = y_slope_floor[dy]
            if perp_dist > 0
              light = calculate_flat_light(light_level, perp_dist)
              cmap = colormap_maps[light]
              row_offset = y * SCREEN_WIDTH

              if floor_flat
                x = 0
                while x < SCREEN_WIDTH
                  ray_dist = perp_dist * column_distscale[x]
                  tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
                  tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
                  color = floor_flat[tex_x, tex_y] || 0
                  framebuffer[row_offset + x] = cmap[color]
                  x += 1
                end
              end
            end
          end
          y += 1
        end
      end

      private

      def clear_framebuffer
        @framebuffer.fill(0)
      end

      def reset_clipping
        @ceiling_clip.fill(-1)
        @floor_clip.fill(SCREEN_HEIGHT)
        @wall_depth.fill(Float::INFINITY)
      end

      def render_bsp_node(node_index)
        if node_index & Map::Node::SUBSECTOR_FLAG != 0
          render_subsector(node_index & ~Map::Node::SUBSECTOR_FLAG)
          return
        end

        node = @map.nodes[node_index]
        side = point_on_side(@player_x, @player_y, node)

        if side == 0
          render_bsp_node(node.child_right)
          render_bsp_node(node.child_left)
        else
          render_bsp_node(node.child_left)
          render_bsp_node(node.child_right)
        end
      end

      def point_on_side(x, y, node)
        dx = x - node.x
        dy = y - node.y
        left = dy * node.dx
        right = dx * node.dy
        right >= left ? 0 : 1
      end

      def render_subsector(index)
        subsector = @map.subsectors[index]
        return unless subsector

        # Get the sector for this subsector (from first seg's linedef)
        first_seg = @map.segs[subsector.first_seg]
        linedef = @map.linedefs[first_seg.linedef]
        sidedef_idx = first_seg.direction == 0 ? linedef.sidedef_right : linedef.sidedef_left
        return if sidedef_idx < 0

        sidedef = @map.sidedefs[sidedef_idx]
        @current_sector = @map.sectors[sidedef.sector]

        # Create floor visplane if floor is visible (below eye level)
        # Matches Chocolate Doom: if (frontsector->floorheight < viewz)
        if @current_sector.floor_height < @player_z
          @current_floor_plane = find_or_create_visplane(
            @current_sector,
            @current_sector.floor_height,
            @current_sector.floor_texture,
            @current_sector.light_level,
            false
          )
        else
          @current_floor_plane = nil
        end

        # Create ceiling visplane if ceiling is visible (above eye level or sky)
        # Matches Chocolate Doom: if (frontsector->ceilingheight > viewz || frontsector->ceilingpic == skyflatnum)
        is_sky = @current_sector.ceiling_texture == 'F_SKY1'
        if @current_sector.ceiling_height > @player_z || is_sky
          @current_ceiling_plane = find_or_create_visplane(
            @current_sector,
            @current_sector.ceiling_height,
            @current_sector.ceiling_texture,
            @current_sector.light_level,
            true
          )
        else
          @current_ceiling_plane = nil
        end

        # Process all segs in this subsector
        subsector.seg_count.times do |i|
          seg = @map.segs[subsector.first_seg + i]
          render_seg(seg)
        end
      end

      def render_seg(seg)
        v1 = @map.vertices[seg.v1]
        v2 = @map.vertices[seg.v2]

        # Transform vertices to view space
        # View space: +Y is forward, +X is right
        x1, y1 = transform_point(v1.x, v1.y)
        x2, y2 = transform_point(v2.x, v2.y)

        # Both behind player?
        return if y1 <= 0 && y2 <= 0

        # Clip to near plane
        near = 1.0
        if y1 < near || y2 < near
          if y1 < near && y2 < near
            return
          elsif y1 < near
            t = (near - y1) / (y2 - y1)
            x1 = x1 + t * (x2 - x1)
            y1 = near
          elsif y2 < near
            t = (near - y1) / (y2 - y1)
            x2 = x1 + t * (x2 - x1)
            y2 = near
          end
        end

        # Project to screen X using Doom's tangent-based approach
        # screenX = centerX + viewX * projection / viewY
        # This is equivalent to Doom's: centerX - tan(angle) * focalLength
        # because tan(angle) = -viewX / viewY in our coordinate convention
        sx1 = HALF_WIDTH + (x1 * @projection / y1)
        sx2 = HALF_WIDTH + (x2 * @projection / y2)

        # Backface: seg spanning from right to left means we see the back
        return if sx1 >= sx2

        # Off screen?
        return if sx2 < 0 || sx1 >= SCREEN_WIDTH

        # Clamp to screen
        x1i = [sx1.to_i, 0].max
        x2i = [sx2.to_i, SCREEN_WIDTH - 1].min
        return if x1i > x2i

        # Get sector info
        linedef = @map.linedefs[seg.linedef]
        sidedef_idx = seg.direction == 0 ? linedef.sidedef_right : linedef.sidedef_left
        return if sidedef_idx < 0

        sidedef = @map.sidedefs[sidedef_idx]
        sector = @map.sectors[sidedef.sector]

        # Back sector for two-sided lines
        back_sector = nil
        if linedef.two_sided?
          back_sidedef_idx = seg.direction == 0 ? linedef.sidedef_left : linedef.sidedef_right
          if back_sidedef_idx >= 0
            back_sidedef = @map.sidedefs[back_sidedef_idx]
            back_sector = @map.sectors[back_sidedef.sector]
          end
        end

        # Calculate seg length for texture mapping
        seg_v1 = @map.vertices[seg.v1]
        seg_v2 = @map.vertices[seg.v2]
        seg_length = Math.sqrt((seg_v2.x - seg_v1.x)**2 + (seg_v2.y - seg_v1.y)**2)

        draw_seg_range(x1i, x2i, sx1, sx2, y1, y2, sector, back_sector, sidedef, linedef, seg, seg_length)
      end

      def transform_point(wx, wy)
        # Translate
        dx = wx - @player_x
        dy = wy - @player_y

        # Rotate - transform world to view space
        # View space: +Y forward (in direction of angle), +X is right
        x = dx * @sin_angle - dy * @cos_angle
        y = dx * @cos_angle + dy * @sin_angle

        [x, y]
      end

      def draw_seg_range(x1, x2, sx1, sx2, dist1, dist2, sector, back_sector, sidedef, linedef, seg, seg_length)
        # Get seg vertices in world space for texture coordinate calculation
        seg_v1 = @map.vertices[seg.v1]
        seg_v2 = @map.vertices[seg.v2]

        # Calculate scales for drawseg (scale = projection / distance)
        scale1 = dist1 > 0 ? @projection / dist1 : Float::INFINITY
        scale2 = dist2 > 0 ? @projection / dist2 : Float::INFINITY

        # Determine silhouette type for sprite clipping
        silhouette = SIL_NONE
        bsilheight = 0  # bottom silhouette world height
        tsilheight = 0  # top silhouette world height

        if back_sector
          # Two-sided line - check for silhouettes
          if sector.floor_height > back_sector.floor_height
            silhouette |= SIL_BOTTOM
            bsilheight = sector.floor_height
          elsif back_sector.floor_height > @player_z
            silhouette |= SIL_BOTTOM
            bsilheight = Float::INFINITY
          end

          if sector.ceiling_height < back_sector.ceiling_height
            silhouette |= SIL_TOP
            tsilheight = sector.ceiling_height
          elsif back_sector.ceiling_height < @player_z
            silhouette |= SIL_TOP
            tsilheight = -Float::INFINITY
          end
        else
          # Solid wall - full silhouette
          silhouette = SIL_BOTH
          bsilheight = Float::INFINITY
          tsilheight = -Float::INFINITY
        end

        # Check planes for this seg range (R_CheckPlane equivalent)
        # This may create new visplanes if column ranges would overlap
        if @current_floor_plane
          @current_floor_plane = check_plane(@current_floor_plane, x1, x2)
        end
        if @current_ceiling_plane
          @current_ceiling_plane = check_plane(@current_ceiling_plane, x1, x2)
        end

        (x1..x2).each do |x|
          next if @ceiling_clip[x] >= @floor_clip[x] - 1

          # Screen-space interpolation factor for distance only
          t = sx2 != sx1 ? (x - sx1) / (sx2 - sx1) : 0
          t = t.clamp(0.0, 1.0)

          # Perspective-correct interpolation for distance
          if dist1 > 0 && dist2 > 0
            inv_dist = (1.0 - t) / dist1 + t / dist2
            dist = 1.0 / inv_dist
          else
            dist = dist1 > 0 ? dist1 : dist2
          end

          # Texture column using perspective-correct interpolation
          # tex_col_1 is texture coordinate at seg v1, tex_col_2 at v2
          tex_col_1 = seg.offset + sidedef.x_offset
          tex_col_2 = seg.offset + seg_length + sidedef.x_offset

          # Perspective-correct interpolation: interpolate tex/z, then multiply by z
          if dist1 > 0 && dist2 > 0
            tex_col = ((tex_col_1 / dist1) * (1.0 - t) + (tex_col_2 / dist2) * t) / inv_dist
          else
            tex_col = tex_col_1 * (1.0 - t) + tex_col_2 * t
          end
          tex_col = tex_col.to_i

          # Skip if too close
          next if dist < 1

          # Scale factor for this column
          scale = @projection / dist

          # World heights relative to player eye level
          front_floor = sector.floor_height - @player_z
          front_ceil = sector.ceiling_height - @player_z

          # Project to screen Y (Y increases downward on screen)
          front_ceil_y = (HALF_HEIGHT - front_ceil * scale).to_i
          front_floor_y = (HALF_HEIGHT - front_floor * scale).to_i

          # Clamp to current clip bounds
          ceil_y = [front_ceil_y, @ceiling_clip[x] + 1].max
          floor_y = [front_floor_y, @floor_clip[x] - 1].min

          if back_sector
            # Two-sided line
            back_floor = back_sector.floor_height - @player_z
            back_ceil = back_sector.ceiling_height - @player_z

            back_ceil_y = (HALF_HEIGHT - back_ceil * scale).to_i
            back_floor_y = (HALF_HEIGHT - back_floor * scale).to_i

            # Determine visible ceiling/floor boundaries (the opening between sectors)
            # high_ceil = top of the opening on screen (max Y = lower world ceiling)
            # low_floor = bottom of the opening on screen (min Y = higher world floor)
            high_ceil = [ceil_y, back_ceil_y].max
            low_floor = [floor_y, back_floor_y].min

            # Mark ceiling visplane - mark front sector's ceiling for two-sided lines
            # Matches Chocolate Doom: mark from ceilingclip+1 to yl-1 (front ceiling)
            # (yl is clamped to ceilingclip+1, so we use ceil_y which is already clamped)
            should_mark_ceiling = sector.ceiling_height != back_sector.ceiling_height ||
                                  sector.ceiling_texture != back_sector.ceiling_texture ||
                                  sector.light_level != back_sector.light_level
            if @current_ceiling_plane && should_mark_ceiling
              mark_top = @ceiling_clip[x] + 1
              mark_bottom = ceil_y - 1
              mark_bottom = [@floor_clip[x] - 1, mark_bottom].min
              if mark_top <= mark_bottom
                @current_ceiling_plane.mark(x, mark_top, mark_bottom)
              end
            end

            # Mark floor visplane - mark front sector's floor for two-sided lines
            # Matches Chocolate Doom: mark from yh+1 (front floor) to floorclip-1
            # (yh is clamped to floorclip-1, so we use floor_y which is already clamped)
            should_mark_floor = sector.floor_height != back_sector.floor_height ||
                                sector.floor_texture != back_sector.floor_texture ||
                                sector.light_level != back_sector.light_level
            if @current_floor_plane && should_mark_floor
              mark_top = floor_y + 1
              mark_bottom = @floor_clip[x] - 1
              mark_top = [@ceiling_clip[x] + 1, mark_top].max
              if mark_top <= mark_bottom
                @current_floor_plane.mark(x, mark_top, mark_bottom)
              end
            end

            # Upper wall (ceiling step down)
            if sector.ceiling_height > back_sector.ceiling_height
              # Upper texture Y offset depends on DONTPEGTOP flag
              # With DONTPEGTOP: texture top aligns with front ceiling
              # Without: texture bottom aligns with back ceiling (for doors opening)
              if linedef.upper_unpegged?
                upper_tex_y = sidedef.y_offset
              else
                texture = @textures[sidedef.upper_texture]
                tex_height = texture ? texture.height : 128
                upper_tex_y = sidedef.y_offset + back_sector.ceiling_height - sector.ceiling_height + tex_height
              end
              draw_wall_column_ex(x, ceil_y, back_ceil_y - 1, sidedef.upper_texture, dist,
                                  sector.light_level, tex_col, upper_tex_y, scale, sector.ceiling_height, back_sector.ceiling_height)
              # Note: Upper walls don't fully occlude - sprites can be visible through openings
            end

            # Lower wall (floor step up)
            if sector.floor_height < back_sector.floor_height
              # Lower texture Y offset depends on DONTPEGBOTTOM flag
              # With DONTPEGBOTTOM: texture bottom aligns with lower floor
              # Without: texture top aligns with higher floor
              if linedef.lower_unpegged?
                lower_tex_y = sidedef.y_offset + sector.ceiling_height - back_sector.floor_height
              else
                lower_tex_y = sidedef.y_offset
              end
              draw_wall_column_ex(x, back_floor_y + 1, floor_y, sidedef.lower_texture, dist,
                                  sector.light_level, tex_col, lower_tex_y, scale, back_sector.floor_height, sector.floor_height)
              # Note: Lower walls don't fully occlude - sprites can be visible through openings
            end

            # Update clip bounds after marking
            # Ceiling clip increases (moves down) as ceiling is marked
            if sector.ceiling_height > back_sector.ceiling_height
              # Upper wall drawn - clip ceiling to back ceiling
              @ceiling_clip[x] = [back_ceil_y, @ceiling_clip[x]].max
            elsif sector.ceiling_height < back_sector.ceiling_height
              # Ceiling step up - clip to front ceiling
              @ceiling_clip[x] = [ceil_y, @ceiling_clip[x]].max
            elsif should_mark_ceiling
              # Same height but different texture/light - still update clip
              # Matches Chocolate Doom: if (markceiling) ceilingclip[rw_x] = yl-1;
              @ceiling_clip[x] = [ceil_y - 1, @ceiling_clip[x]].max
            end

            # Floor clip decreases (moves up) as floor is marked
            if sector.floor_height < back_sector.floor_height
              # Lower wall drawn - clip floor to back floor
              @floor_clip[x] = [back_floor_y, @floor_clip[x]].min
            elsif sector.floor_height > back_sector.floor_height
              # Floor step down - clip to front floor to allow back sector to mark later
              @floor_clip[x] = [floor_y, @floor_clip[x]].min
            elsif should_mark_floor
              # Same height but different texture/light - still update clip
              # Matches Chocolate Doom: if (markfloor) floorclip[rw_x] = yh+1;
              @floor_clip[x] = [floor_y + 1, @floor_clip[x]].min
            end
          else
            # One-sided (solid) wall
            # Mark ceiling visplane (from previous clip to wall's ceiling)
            if @current_ceiling_plane && @ceiling_clip[x] + 1 <= ceil_y - 1
              @current_ceiling_plane.mark(x, @ceiling_clip[x] + 1, ceil_y - 1)
            end

            # Mark floor visplane (from wall's floor to previous floor clip)
            # Floor is visible BELOW the wall (from floor_y+1 to floor_clip-1)
            if @current_floor_plane && floor_y + 1 <= @floor_clip[x] - 1
              @current_floor_plane.mark(x, floor_y + 1, @floor_clip[x] - 1)
            end

            # Draw wall (from clipped ceiling to clipped floor)
            # Middle texture Y offset depends on DONTPEGBOTTOM flag
            # With DONTPEGBOTTOM: texture bottom aligns with floor
            # Without: texture top aligns with ceiling
            if linedef.lower_unpegged?
              texture = @textures[sidedef.middle_texture]
              tex_height = texture ? texture.height : 128
              mid_tex_y = sidedef.y_offset + tex_height - (sector.ceiling_height - sector.floor_height)
            else
              mid_tex_y = sidedef.y_offset
            end
            draw_wall_column_ex(x, ceil_y, floor_y, sidedef.middle_texture, dist,
                                sector.light_level, tex_col, mid_tex_y, scale, sector.ceiling_height, sector.floor_height)

            # Track wall depth for sprite clipping (solid wall occludes this column)
            @wall_depth[x] = [@wall_depth[x], dist].min

            # Fully occluded
            @ceiling_clip[x] = SCREEN_HEIGHT
            @floor_clip[x] = -1
          end
        end

        # Save drawseg for sprite clipping (after columns are rendered)
        # Copy the clip arrays for the segment's screen range
        if silhouette != SIL_NONE
          sprtopclip = @ceiling_clip[x1..x2].dup
          sprbottomclip = @floor_clip[x1..x2].dup

          drawseg = Drawseg.new(
            x1, x2,
            scale1, scale2,
            silhouette,
            bsilheight, tsilheight,
            sprtopclip, sprbottomclip
          )
          @drawsegs << drawseg
        end
      end

      # Wall column drawing with proper texture mapping
      # tex_col: texture column (X coordinate in texture)
      # tex_y_start: starting Y coordinate in texture (accounts for pegging)
      # scale: projection scale for this column (projection / distance)
      # world_top, world_bottom: world heights of this wall section
      def draw_wall_column_ex(x, y1, y2, texture_name, dist, light_level, tex_col, tex_y_start, scale, world_top, world_bottom)
        return if y1 > y2
        return if texture_name.nil? || texture_name.empty? || texture_name == '-'

        # Clip to visible range (ceiling_clip/floor_clip)
        clip_top = @ceiling_clip[x] + 1
        clip_bottom = @floor_clip[x] - 1
        y1 = [y1, clip_top].max
        y2 = [y2, clip_bottom].min
        return if y1 > y2

        texture = @textures[texture_name]
        return unless texture

        light = calculate_light(light_level, dist)
        cmap = @colormap.maps[light]
        framebuffer = @framebuffer
        tex_width = texture.width
        tex_height = texture.height

        # Texture X coordinate (wrap around texture width)
        tex_x = tex_col.to_i % tex_width
        tex_x += tex_width if tex_x < 0

        # Get the column of pixels
        column = texture.column_pixels(tex_x)
        return unless column

        # Texture step per screen pixel
        tex_step = 1.0 / scale

        # Calculate where the unclipped wall top would be on screen
        unclipped_y1 = HALF_HEIGHT - (world_top - @player_z) * scale

        # Adjust tex_y_start for any clipping at the top
        tex_y_at_y1 = tex_y_start + (y1 - unclipped_y1) * tex_step

        # Clamp to screen bounds
        y1 = 0 if y1 < 0
        y2 = SCREEN_HEIGHT - 1 if y2 >= SCREEN_HEIGHT

        # Draw wall column using while loop
        y = y1
        while y <= y2
          screen_offset = y - y1
          tex_y = (tex_y_at_y1 + screen_offset * tex_step).to_i % tex_height
          tex_y += tex_height if tex_y < 0

          color = column[tex_y] || 0
          framebuffer[y * SCREEN_WIDTH + x] = cmap[color]
          y += 1
        end
      end

      # Calculate colormap index for lighting
      # Doom uses: walllights[scale >> LIGHTSCALESHIFT] where scale = projection/distance
      # LIGHTSCALESHIFT = 12, MAXLIGHTSCALE = 48, NUMCOLORMAPS = 32
      # Doom lighting constants from r_main.h
      LIGHTLEVELS = 16
      LIGHTSEGSHIFT = 4
      MAXLIGHTSCALE = 48
      LIGHTSCALESHIFT = 12
      MAXLIGHTZ = 128
      LIGHTZSHIFT = 20
      NUMCOLORMAPS = 32
      DISTMAP = 2

      # Calculate light for walls using Doom's scalelight formula
      # In Doom: scalelight[lightnum][scale_index] where:
      #   lightnum = sector_light >> LIGHTSEGSHIFT (0-15)
      #   startmap = (LIGHTLEVELS-1-lightnum) * 2 * NUMCOLORMAPS / LIGHTLEVELS
      #   level = startmap - scale_index * SCREENWIDTH / (viewwidth * DISTMAP)
      #   scale_index = rw_scale >> LIGHTSCALESHIFT (0-47)
      def calculate_light(light_level, dist)
        # lightnum from sector light level (0-15)
        lightnum = (light_level >> LIGHTSEGSHIFT).clamp(0, LIGHTLEVELS - 1)

        # startmap = (15 - lightnum) * 4 for LIGHTLEVELS=16, NUMCOLORMAPS=32
        startmap = ((LIGHTLEVELS - 1 - lightnum) * 2 * NUMCOLORMAPS) / LIGHTLEVELS

        # scale_index from projection scale
        # rw_scale (fixed point) = projection * FRACUNIT / distance
        # scale_index = rw_scale >> LIGHTSCALESHIFT = projection * 16 / distance
        # With projection = 160: scale_index = 2560 / distance
        scale_index = dist > 0 ? (2560.0 / dist).to_i : MAXLIGHTSCALE
        scale_index = scale_index.clamp(0, MAXLIGHTSCALE - 1)

        # level = startmap - scale_index * 320 / (320 * 2) = startmap - scale_index / 2
        level = startmap - (scale_index * SCREEN_WIDTH / (SCREEN_WIDTH * DISTMAP))

        level.clamp(0, NUMCOLORMAPS - 1)
      end

      # Calculate light for floor/ceiling using Doom's zlight formula
      # In Doom: zlight[lightnum][z_index] where:
      #   z_index = distance >> LIGHTZSHIFT (0-127)
      #   For each z_index, a scale is computed and used to find the level
      def calculate_flat_light(light_level, distance)
        # lightnum from sector light level (0-15)
        lightnum = (light_level >> LIGHTSEGSHIFT).clamp(0, LIGHTLEVELS - 1)

        # startmap = (LIGHTLEVELS-1-lightnum)*2*NUMCOLORMAPS/LIGHTLEVELS
        startmap = ((LIGHTLEVELS - 1 - lightnum) * 2 * NUMCOLORMAPS) / LIGHTLEVELS

        # z_index = distance (in fixed point) >> LIGHTZSHIFT
        # Our float distance * FRACUNIT >> LIGHTZSHIFT = distance * 65536 / 1048576 = distance / 16
        z_index = (distance / 16.0).to_i.clamp(0, MAXLIGHTZ - 1)

        # From R_InitLightTables: scale = FixedDiv(160*FRACUNIT, (j+1)<<LIGHTZSHIFT)
        #   = (160*65536*65536) / ((j+1)*1048576) = 655360 / (j+1)
        # level = startmap - scale/FRACUNIT = startmap - 655360/65536/(j+1) = startmap - 10/(j+1)
        diminish = 10.0 / (z_index + 1)

        level = startmap - diminish
        level.to_i.clamp(0, NUMCOLORMAPS - 1)
      end

      def render_sprites
        return unless @sprites

        # Collect visible sprites with their distances
        visible_sprites = []

        @map.things.each do |thing|
          # Check if we have a sprite for this thing type
          next unless @sprites.prefix_for(thing.type)

          # Transform to view space
          view_x, view_y = transform_point(thing.x, thing.y)

          # Skip if behind player
          next if view_y <= 0

          # Calculate distance for sorting and scaling
          dist = view_y

          # Calculate angle from player to thing (for rotation selection)
          dx = thing.x - @player_x
          dy = thing.y - @player_y
          angle_to_thing = Math.atan2(dy, dx)

          # Get the correct rotated sprite
          sprite = @sprites.get_rotated(thing.type, angle_to_thing, thing.angle)
          next unless sprite

          # Project to screen X
          screen_x = HALF_WIDTH + (view_x * @projection / view_y)

          # Skip if completely off screen (with margin for sprite width)
          sprite_half_width = (sprite.width * @projection / dist / 2).to_i
          next if screen_x + sprite_half_width < 0
          next if screen_x - sprite_half_width >= SCREEN_WIDTH

          visible_sprites << {
            thing: thing,
            sprite: sprite,
            view_x: view_x,
            view_y: view_y,
            dist: dist,
            screen_x: screen_x
          }
        end

        # Sort by distance (back to front for proper overdraw)
        visible_sprites.sort_by! { |s| -s[:dist] }

        # Draw each sprite
        visible_sprites.each do |vs|
          draw_sprite(vs)
        end
      end

      def draw_sprite(vs)
        sprite = vs[:sprite]
        dist = vs[:dist]
        screen_x = vs[:screen_x]
        thing = vs[:thing]

        # Calculate scale (inverse of distance, used for depth comparison)
        sprite_scale = @projection / dist

        # Sprite dimensions on screen
        sprite_screen_width = (sprite.width * sprite_scale).to_i
        sprite_screen_height = (sprite.height * sprite_scale).to_i

        return if sprite_screen_width <= 0 || sprite_screen_height <= 0

        # Get sector for lighting and Z position
        sector = @map.sector_at(thing.x, thing.y)
        light_level = sector ? sector.light_level : 160
        light = calculate_light(light_level, dist)

        # Sprite screen bounds
        sprite_left = (screen_x - sprite.left_offset * sprite_scale).to_i
        sprite_right = sprite_left + sprite_screen_width - 1

        # Clamp to screen
        x1 = [sprite_left, 0].max
        x2 = [sprite_right, SCREEN_WIDTH - 1].min
        return if x1 > x2

        # Calculate sprite world Z positions
        thing_floor = sector ? sector.floor_height : 0
        sprite_gz = thing_floor  # bottom of sprite in world Z
        sprite_gzt = thing_floor + sprite.top_offset  # top of sprite in world Z

        # Initialize per-column clip arrays (-2 = not yet clipped)
        clipbot = Array.new(SCREEN_WIDTH, -2)
        cliptop = Array.new(SCREEN_WIDTH, -2)

        # Scan drawsegs from back to front for obscuring segs
        @drawsegs.reverse_each do |ds|
          # Skip if drawseg doesn't overlap sprite horizontally
          next if ds.x1 > x2 || ds.x2 < x1

          # Skip if drawseg has no silhouette
          next if ds.silhouette == SIL_NONE

          # Determine overlap range
          r1 = [ds.x1, x1].max
          r2 = [ds.x2, x2].min

          # Get drawseg's scale range for depth comparison
          lowscale = [ds.scale1, ds.scale2].min
          highscale = [ds.scale1, ds.scale2].max

          # If drawseg is behind sprite, skip (seg must be closer to clip)
          if highscale < sprite_scale
            next
          elsif lowscale < sprite_scale
            # Seg partially overlaps in depth - would need point-on-seg test
            # For simplicity, we'll clip if any part of seg is closer
          end

          # Determine which silhouettes apply based on sprite Z
          silhouette = ds.silhouette

          # If sprite bottom is at or above the bottom silhouette height, don't clip bottom
          if sprite_gz >= ds.bsilheight
            silhouette &= ~SIL_BOTTOM
          end

          # If sprite top is at or below the top silhouette height, don't clip top
          if sprite_gzt <= ds.tsilheight
            silhouette &= ~SIL_TOP
          end

          # Apply clipping for each column in the overlap
          (r1..r2).each do |x|
            # Index into drawseg's clip arrays (0-based from ds.x1)
            ds_idx = x - ds.x1

            if (silhouette & SIL_BOTTOM) != 0 && clipbot[x] == -2
              clipbot[x] = ds.sprbottomclip[ds_idx] if ds.sprbottomclip && ds_idx < ds.sprbottomclip.length
            end

            if (silhouette & SIL_TOP) != 0 && cliptop[x] == -2
              cliptop[x] = ds.sprtopclip[ds_idx] if ds.sprtopclip && ds_idx < ds.sprtopclip.length
            end
          end
        end

        # Fill in default values for unclipped columns
        (x1..x2).each do |x|
          clipbot[x] = SCREEN_HEIGHT if clipbot[x] == -2
          cliptop[x] = -1 if cliptop[x] == -2
        end

        # Calculate sprite screen Y positions
        sprite_top_world = sprite_gzt - @player_z
        sprite_bottom_world = sprite_gz - @player_z
        sprite_top_screen = (HALF_HEIGHT - sprite_top_world * sprite_scale).to_i
        sprite_bottom_screen = (HALF_HEIGHT - sprite_bottom_world * sprite_scale).to_i

        # Cache for inner loop
        framebuffer = @framebuffer
        cmap = @colormap.maps[light]
        sprite_width = sprite.width
        sprite_height = sprite.height

        # Draw each column of the sprite
        (x1..x2).each do |x|
          # Get clip bounds for this column
          top_clip = cliptop[x] + 1
          bottom_clip = clipbot[x] - 1

          next if top_clip > bottom_clip

          # Calculate which texture column to use
          tex_x = ((x - sprite_left) * sprite_width / sprite_screen_width).to_i
          tex_x = tex_x.clamp(0, sprite_width - 1)

          # Get column pixels
          column = sprite.column_pixels(tex_x)
          next unless column

          # Draw visible portion of this column
          y_start = [sprite_top_screen, top_clip].max
          y_end = [sprite_bottom_screen, bottom_clip].min

          (y_start..y_end).each do |y|
            # Calculate texture Y
            tex_y = ((y - sprite_top_screen) * sprite_height / sprite_screen_height).to_i
            tex_y = tex_y.clamp(0, sprite_height - 1)

            # Get pixel (nil = transparent)
            color = column[tex_y]
            next unless color

            # Apply lighting and write directly to framebuffer
            framebuffer[y * SCREEN_WIDTH + x] = cmap[color]
          end
        end
      end
    end
  end
end
