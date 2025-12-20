# frozen_string_literal: true

module Doom
  module Render
    SCREEN_WIDTH = 320
    SCREEN_HEIGHT = 200
    HALF_WIDTH = SCREEN_WIDTH / 2
    HALF_HEIGHT = SCREEN_HEIGHT / 2
    FOV = 90.0

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
      end

      def set_player(x, y, z, angle)
        @player_x = x.to_f
        @player_y = y.to_f
        @player_z = z.to_f
        @player_angle = angle * Math::PI / 180.0
      end

      def render_frame
        clear_framebuffer
        reset_clipping

        @sin_angle = Math.sin(@player_angle)
        @cos_angle = Math.cos(@player_angle)

        # Pre-fill with sky and default floor to handle open areas
        draw_background

        # Render walls via BSP traversal
        render_bsp_node(@map.nodes.size - 1)

        # Save wall clip arrays for sprite clipping
        @sprite_ceiling_clip = @ceiling_clip.dup
        @sprite_floor_clip = @floor_clip.dup

        # Render sprites
        render_sprites if @sprites
      end

      def draw_background
        # Get player's sector for correct textures
        player_sector = @map.sector_at(@player_x, @player_y)

        if player_sector
          floor_tex = player_sector.floor_texture
          ceil_tex = player_sector.ceiling_texture
          floor_height = player_sector.floor_height
          ceil_height = player_sector.ceiling_height
          light_level = player_sector.light_level
        else
          floor_tex = 'FLOOR4_8'
          ceil_tex = 'CEIL3_5'
          floor_height = 0
          ceil_height = 72
          light_level = 160
        end

        floor_flat = @flats[floor_tex]
        ceil_flat = @flats[ceil_tex]
        is_sky = ceil_tex == 'F_SKY1'

        # Load sky texture if needed
        sky_texture = is_sky ? @textures['SKY1'] : nil

        SCREEN_WIDTH.times do |x|
          column_angle = @player_angle + Math.atan2(x - HALF_WIDTH, @projection)

          # Ceiling (top half)
          (0...HALF_HEIGHT).each do |y|
            if is_sky && sky_texture
              # Sky texture - use view angle for horizontal, fixed for vertical
              sky_angle = (column_angle * 256 / Math::PI).to_i & 255
              sky_x = sky_angle % sky_texture.width
              sky_y = y % sky_texture.height
              color = sky_texture.column_pixels(sky_x)[sky_y] || 0
              set_pixel(x, y, color)
            else
              dy = HALF_HEIGHT - y
              next if dy == 0

              ceil_rel = ceil_height - @player_z
              row_distance = (ceil_rel.abs * @projection / dy.to_f).abs

              if ceil_flat && row_distance > 0
                world_x = @player_x + row_distance * Math.cos(column_angle)
                world_y = @player_y + row_distance * Math.sin(column_angle)
                tex_x = world_x.to_i & 63
                tex_y = world_y.to_i & 63
                color = ceil_flat[tex_x, tex_y] || 100
              else
                color = 100
              end

              light = calculate_light(light_level, row_distance)
              color = @colormap.maps[light][color]
              set_pixel(x, y, color)
            end
          end

          # Floor (bottom half)
          (HALF_HEIGHT...SCREEN_HEIGHT).each do |y|
            dy = y - HALF_HEIGHT
            next if dy == 0

            floor_rel = floor_height - @player_z
            row_distance = (floor_rel.abs * @projection / dy.to_f).abs

            if floor_flat && row_distance > 0
              world_x = @player_x + row_distance * Math.cos(column_angle)
              world_y = @player_y + row_distance * Math.sin(column_angle)
              tex_x = world_x.to_i & 63
              tex_y = world_y.to_i & 63
              color = floor_flat[tex_x, tex_y] || 96
            else
              color = 96
            end

            light = calculate_light(light_level, row_distance)
            color = @colormap.maps[light][color]
            set_pixel(x, y, color)
          end
        end
      end

      private

      def clear_framebuffer
        @framebuffer.fill(0)
      end

      def reset_clipping
        @ceiling_clip.fill(-1)
        @floor_clip.fill(SCREEN_HEIGHT)
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

        draw_seg_range(x1i, x2i, sx1, sx2, y1, y2, sector, back_sector, sidedef, linedef)
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

      def draw_seg_range(x1, x2, sx1, sx2, dist1, dist2, sector, back_sector, sidedef, linedef)
        (x1..x2).each do |x|
          next if @ceiling_clip[x] >= @floor_clip[x] - 1

          # Interpolate distance
          t = sx2 != sx1 ? (x - sx1) / (sx2 - sx1) : 0
          t = t.clamp(0.0, 1.0)

          # Perspective-correct interpolation
          if dist1 > 0 && dist2 > 0
            inv_dist = (1.0 - t) / dist1 + t / dist2
            dist = 1.0 / inv_dist
          else
            dist = dist1 > 0 ? dist1 : dist2
          end

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

            # Draw ceiling flat (from clipped ceiling to the higher of front/back ceiling)
            high_ceil = [ceil_y, back_ceil_y].max
            draw_flat_column(x, ceil_y, high_ceil - 1, sector.ceiling_texture, sector.light_level, true, front_ceil)

            # Draw floor flat (from the lower of front/back floor to clipped floor)
            low_floor = [floor_y, back_floor_y].min
            draw_flat_column(x, low_floor + 1, floor_y, sector.floor_texture, sector.light_level, false, front_floor)

            # Upper wall (ceiling step down)
            if sector.ceiling_height > back_sector.ceiling_height
              upper_height = sector.ceiling_height - back_sector.ceiling_height
              draw_wall_column(x, ceil_y, back_ceil_y - 1, sidedef.upper_texture, dist, sector.light_level,
                               sidedef.x_offset, sidedef.y_offset, upper_height)
            end

            # Lower wall (floor step up)
            if sector.floor_height < back_sector.floor_height
              lower_height = back_sector.floor_height - sector.floor_height
              draw_wall_column(x, back_floor_y + 1, floor_y, sidedef.lower_texture, dist, sector.light_level,
                               sidedef.x_offset, sidedef.y_offset, lower_height)
            end

            # Update clip bounds
            @ceiling_clip[x] = [[back_ceil_y, ceil_y].max, @ceiling_clip[x]].max
            @floor_clip[x] = [[back_floor_y, floor_y].min, @floor_clip[x]].min
          else
            # One-sided (solid) wall
            # Draw ceiling (from previous clip to wall's ceiling)
            draw_flat_column(x, @ceiling_clip[x] + 1, ceil_y - 1, sector.ceiling_texture, sector.light_level, true, front_ceil)

            # Draw floor (from wall's floor to previous clip)
            draw_flat_column(x, floor_y + 1, @floor_clip[x] - 1, sector.floor_texture, sector.light_level, false, front_floor)

            # Draw wall (from clipped ceiling to clipped floor)
            wall_height = sector.ceiling_height - sector.floor_height
            draw_wall_column(x, ceil_y, floor_y, sidedef.middle_texture, dist, sector.light_level,
                             sidedef.x_offset, sidedef.y_offset, wall_height)

            # Fully occluded
            @ceiling_clip[x] = SCREEN_HEIGHT
            @floor_clip[x] = -1
          end
        end
      end

      def draw_wall_column(x, y1, y2, texture_name, dist, light_level, tex_x_offset = 0, tex_y_offset = 0, wall_height = nil)
        return if y1 > y2
        return if texture_name.nil? || texture_name.empty? || texture_name == '-'

        texture = @textures[texture_name]
        light = calculate_light(light_level, dist)

        (y1..y2).each do |y|
          next if y < 0 || y >= SCREEN_HEIGHT

          if texture
            # Apply texture offsets
            tex_x = (x + tex_x_offset) % texture.width

            # Calculate texture Y with proper scaling and offset
            column_height = y2 - y1 + 1
            if wall_height && wall_height > 0
              # Use wall height for proper texture scaling
              tex_y = ((y - y1) * texture.height / column_height + tex_y_offset) % texture.height
            else
              tex_y = ((y - y1) * texture.height / column_height + tex_y_offset) % texture.height
            end

            color = texture.column_pixels(tex_x)[tex_y] || 0
          else
            color = 96
          end

          color = @colormap.maps[light][color]
          set_pixel(x, y, color)
        end
      end

      def draw_flat_column(x, y1, y2, texture_name, light_level, is_ceiling, plane_height = nil)
        return if y1 > y2

        flat = @flats[texture_name]

        # Calculate angle for this screen column
        # tan(angle) = (x - HALF_WIDTH) / projection
        column_angle = @player_angle + Math.atan2(x - HALF_WIDTH, @projection)

        (y1..y2).each do |y|
          next if y < 0 || y >= SCREEN_HEIGHT

          # Calculate distance to this floor/ceiling pixel
          # For floor: y > HALF_HEIGHT, plane is below eye (negative height)
          # For ceiling: y < HALF_HEIGHT, plane is above eye (positive height)
          dy = y - HALF_HEIGHT
          next if dy == 0  # At horizon

          # Use provided plane_height or estimate from y position
          height = plane_height || (is_ceiling ? 31.0 : -41.0)

          # distance = |height| * projection / |dy|
          row_distance = (height.abs * @projection / dy.abs).to_f

          if flat && row_distance > 0
            # Calculate world coordinates for this pixel
            world_x = @player_x + row_distance * Math.cos(column_angle)
            world_y = @player_y + row_distance * Math.sin(column_angle)

            # Get texture coordinates (flats are 64x64, world units)
            tex_x = world_x.to_i & 63
            tex_y = world_y.to_i & 63
            color = flat[tex_x, tex_y] || 0
          elsif is_ceiling
            color = 0  # Sky/black
          else
            color = 96  # Gray floor
          end

          light = calculate_light(light_level, row_distance)
          color = @colormap.maps[light][color]
          set_pixel(x, y, color)
        end
      end

      def calculate_light(light_level, dist)
        diminish = (dist / 32.0).to_i
        (31 - (light_level >> 3) + diminish).clamp(0, 31)
      end

      def render_sprites
        return unless @sprites

        # Collect visible sprites with their distances
        visible_sprites = []

        @map.things.each do |thing|
          sprite = @sprites[thing.type]
          next unless sprite

          # Transform to view space
          view_x, view_y = transform_point(thing.x, thing.y)

          # Skip if behind player
          next if view_y <= 0

          # Calculate distance for sorting and scaling
          dist = view_y

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

        # Calculate scale
        scale = @projection / dist

        # Sprite dimensions on screen
        sprite_screen_width = (sprite.width * scale).to_i
        sprite_screen_height = (sprite.height * scale).to_i

        return if sprite_screen_width <= 0 || sprite_screen_height <= 0

        # Get sector for lighting
        sector = @map.sector_at(thing.x, thing.y)
        light_level = sector ? sector.light_level : 160
        light = calculate_light(light_level, dist)

        # Sprite screen bounds using offset (sprites are anchored at bottom center + offsets)
        # left_offset = pixels from left edge to center
        # top_offset = pixels from top to bottom (ground line)
        sprite_left = (screen_x - sprite.left_offset * scale).to_i
        sprite_right = sprite_left + sprite_screen_width - 1

        # Calculate vertical position
        # Thing's Z is at floor level, sprite bottom should be at floor
        thing_floor = sector ? sector.floor_height : 0
        thing_z = thing_floor

        # Top of sprite in world space is thing_z + top_offset
        sprite_top_world = thing_z + sprite.top_offset - @player_z
        sprite_bottom_world = sprite_top_world - sprite.height

        # Project to screen Y
        sprite_top_screen = (HALF_HEIGHT - sprite_top_world * scale).to_i
        sprite_bottom_screen = (HALF_HEIGHT - sprite_bottom_world * scale).to_i

        # Draw each column of the sprite
        (sprite_left..sprite_right).each do |x|
          next if x < 0 || x >= SCREEN_WIDTH

          # Clip against walls
          top_clip = @sprite_ceiling_clip[x] + 1
          bottom_clip = @sprite_floor_clip[x] - 1

          # Skip if fully clipped
          next if top_clip > bottom_clip

          # Calculate which texture column to use
          tex_x = ((x - sprite_left) * sprite.width / sprite_screen_width).to_i
          tex_x = tex_x.clamp(0, sprite.width - 1)

          # Get column pixels
          column = sprite.column_pixels(tex_x)
          next unless column

          # Draw visible portion of this column
          y_start = [sprite_top_screen, top_clip].max
          y_end = [sprite_bottom_screen, bottom_clip].min

          (y_start..y_end).each do |y|
            # Calculate texture Y
            tex_y = ((y - sprite_top_screen) * sprite.height / sprite_screen_height).to_i
            tex_y = tex_y.clamp(0, sprite.height - 1)

            # Get pixel (nil = transparent)
            color = column[tex_y]
            next unless color

            # Apply lighting
            color = @colormap.maps[light][color]
            set_pixel(x, y, color)
          end
        end
      end

      def set_pixel(x, y, color)
        return if x < 0 || x >= SCREEN_WIDTH || y < 0 || y >= SCREEN_HEIGHT
        @framebuffer[y * SCREEN_WIDTH + x] = color
      end
    end
  end
end
