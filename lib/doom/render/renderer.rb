# frozen_string_literal: true

module Doom
  module Render
    SCREEN_WIDTH = 320
    SCREEN_HEIGHT = 200
    FOV = 90.0
    HALF_FOV = FOV / 2.0

    class Renderer
      attr_reader :framebuffer

      def initialize(wad, map, textures, palette, colormap, flats)
        @wad = wad
        @map = map
        @textures = textures
        @palette = palette
        @colormap = colormap
        @flats = flats.to_h { |f| [f.name, f] }

        @framebuffer = Array.new(SCREEN_WIDTH * SCREEN_HEIGHT, 0)

        @player_x = 0.0
        @player_y = 0.0
        @player_z = 41.0
        @player_angle = 0.0

        # Precompute tables
        @screen_to_angle = Array.new(SCREEN_WIDTH + 1) do |x|
          Math.atan((SCREEN_WIDTH / 2.0 - x) / (SCREEN_WIDTH / 2.0 / Math.tan(HALF_FOV * Math::PI / 180)))
        end

        # Column occlusion
        @upper_clip = Array.new(SCREEN_WIDTH, -1)
        @lower_clip = Array.new(SCREEN_WIDTH, SCREEN_HEIGHT)

        # Floor/ceiling spans
        @floor_clip = Array.new(SCREEN_WIDTH, SCREEN_HEIGHT)
        @ceiling_clip = Array.new(SCREEN_WIDTH, -1)
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

        # Traverse BSP
        render_bsp_node(@map.nodes.size - 1)
      end

      private

      def clear_framebuffer
        @framebuffer.fill(0)
      end

      def reset_clipping
        @upper_clip.fill(-1)
        @lower_clip.fill(SCREEN_HEIGHT)
        @floor_clip.fill(SCREEN_HEIGHT)
        @ceiling_clip.fill(-1)
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
          render_bsp_node(node.child_left) if check_bbox(node.bbox_left)
        else
          render_bsp_node(node.child_left)
          render_bsp_node(node.child_right) if check_bbox(node.bbox_right)
        end
      end

      def point_on_side(x, y, node)
        dx = x - node.x
        dy = y - node.y

        left = dy * node.dx
        right = dx * node.dy

        right >= left ? 0 : 1
      end

      def check_bbox(bbox)
        # Simple check - is any part of bbox in front of player?
        # Could be optimized with angle checks
        true
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

        # Transform to player view space
        x1 = v1.x - @player_x
        y1 = v1.y - @player_y
        x2 = v2.x - @player_x
        y2 = v2.y - @player_y

        # Rotate by player angle
        tx1 = x1 * @cos_angle + y1 * @sin_angle
        ty1 = -x1 * @sin_angle + y1 * @cos_angle
        tx2 = x2 * @cos_angle + y2 * @sin_angle
        ty2 = -x2 * @sin_angle + y2 * @cos_angle

        # Both behind player?
        return if ty1 <= 0 && ty2 <= 0

        # Clip to near plane
        if ty1 <= 0 || ty2 <= 0
          tx1, ty1, tx2, ty2 = clip_seg_to_near(tx1, ty1, tx2, ty2)
          return if ty1 <= 0 && ty2 <= 0
        end

        # Project to screen X
        sx1 = (SCREEN_WIDTH / 2.0) - (tx1 * (SCREEN_WIDTH / 2.0) / ty1)
        sx2 = (SCREEN_WIDTH / 2.0) - (tx2 * (SCREEN_WIDTH / 2.0) / ty2)

        # Backface or off screen?
        return if sx1 >= sx2
        return if sx2 < 0 || sx1 >= SCREEN_WIDTH

        # Clamp to screen
        x1i = [sx1.floor, 0].max
        x2i = [sx2.floor, SCREEN_WIDTH - 1].min
        return if x1i > x2i

        # Get sector info
        linedef = @map.linedefs[seg.linedef]
        sidedef_idx = seg.direction == 0 ? linedef.sidedef_right : linedef.sidedef_left
        return if sidedef_idx < 0

        sidedef = @map.sidedefs[sidedef_idx]
        sector = @map.sectors[sidedef.sector]

        # Get back sector for two-sided lines
        back_sector = nil
        if linedef.two_sided?
          back_sidedef_idx = seg.direction == 0 ? linedef.sidedef_left : linedef.sidedef_right
          if back_sidedef_idx >= 0
            back_sidedef = @map.sidedefs[back_sidedef_idx]
            back_sector = @map.sectors[back_sidedef.sector]
          end
        end

        # Draw columns
        draw_seg_columns(x1i, x2i, sx1, sx2, ty1, ty2, sector, back_sector, sidedef, linedef)
      end

      def clip_seg_to_near(x1, y1, x2, y2)
        near = 0.1
        if y1 < near
          t = (near - y1) / (y2 - y1)
          x1 = x1 + t * (x2 - x1)
          y1 = near
        end
        if y2 < near
          t = (near - y1) / (y2 - y1)
          x2 = x1 + t * (x2 - x1)
          y2 = near
        end
        [x1, y1, x2, y2]
      end

      def draw_seg_columns(x1, x2, sx1, sx2, dist1, dist2, sector, back_sector, sidedef, linedef)
        (x1..x2).each do |x|
          next if @upper_clip[x] >= @lower_clip[x] - 1

          # Interpolate distance
          t = (x - sx1) / (sx2 - sx1)
          t = t.clamp(0.0, 1.0)

          # Perspective-correct interpolation
          inv_dist = (1.0 - t) / dist1 + t / dist2
          dist = 1.0 / inv_dist

          scale = (SCREEN_HEIGHT / dist).clamp(0.1, 10000)

          # Calculate heights
          center_y = SCREEN_HEIGHT / 2

          ceil_h = sector.ceiling_height - @player_z
          floor_h = sector.floor_height - @player_z

          ceil_screen = (center_y - ceil_h * scale / 2.0).to_i
          floor_screen = (center_y - floor_h * scale / 2.0).to_i

          # Clamp to clipping
          ceil_screen = [ceil_screen, @ceiling_clip[x] + 1].max
          floor_screen = [floor_screen, @floor_clip[x] - 1].min

          if back_sector
            # Two-sided line
            back_ceil_h = back_sector.ceiling_height - @player_z
            back_floor_h = back_sector.floor_height - @player_z

            back_ceil_screen = (center_y - back_ceil_h * scale / 2.0).to_i
            back_floor_screen = (center_y - back_floor_h * scale / 2.0).to_i

            # Upper wall
            if sector.ceiling_height > back_sector.ceiling_height
              upper_top = ceil_screen
              upper_bottom = [back_ceil_screen, floor_screen].min
              draw_wall_column(x, upper_top, upper_bottom, sidedef.upper_texture, dist, sector.light_level) if upper_bottom > upper_top
            end

            # Lower wall
            if sector.floor_height < back_sector.floor_height
              lower_top = [back_floor_screen, ceil_screen].max
              lower_bottom = floor_screen
              draw_wall_column(x, lower_top, lower_bottom, sidedef.lower_texture, dist, sector.light_level) if lower_bottom > lower_top
            end

            # Middle (transparent)
            if !sidedef.middle_texture.empty? && sidedef.middle_texture != '-'
              mid_top = [ceil_screen, back_ceil_screen].max
              mid_bottom = [floor_screen, back_floor_screen].min
              draw_wall_column(x, mid_top, mid_bottom, sidedef.middle_texture, dist, sector.light_level) if mid_bottom > mid_top
            end

            # Floor
            draw_floor_column(x, [floor_screen, back_floor_screen].min, @floor_clip[x] - 1, sector, dist)

            # Ceiling
            draw_ceiling_column(x, @ceiling_clip[x] + 1, [ceil_screen, back_ceil_screen].max, sector, dist)

            # Update clipping
            @ceiling_clip[x] = [back_ceil_screen, @ceiling_clip[x]].max
            @floor_clip[x] = [back_floor_screen, @floor_clip[x]].min
          else
            # One-sided (solid) wall
            draw_wall_column(x, ceil_screen, floor_screen, sidedef.middle_texture, dist, sector.light_level)

            # Floor
            draw_floor_column(x, floor_screen, @floor_clip[x] - 1, sector, dist)

            # Ceiling
            draw_ceiling_column(x, @ceiling_clip[x] + 1, ceil_screen, sector, dist)

            # Mark as fully occluded
            @upper_clip[x] = SCREEN_HEIGHT
            @lower_clip[x] = -1
          end
        end
      end

      def draw_wall_column(x, y1, y2, texture_name, dist, light_level)
        return if y1 >= y2
        return if texture_name.nil? || texture_name.empty? || texture_name == '-'

        texture = @textures[texture_name]

        # Calculate light
        light_diminish = (dist / 16.0).to_i
        colormap_idx = (31 - (light_level >> 3) + light_diminish).clamp(0, 31)

        (y1...y2).each do |y|
          next if y < 0 || y >= SCREEN_HEIGHT

          if texture
            tex_y = ((y - y1) * texture.height / (y2 - y1)) % texture.height
            color = texture.column_pixels(x % texture.width)[tex_y] || 0
          else
            color = 96  # Gray fallback
          end

          color = @colormap.maps[colormap_idx][color]
          set_pixel(x, y, color)
        end
      end

      def draw_floor_column(x, y1, y2, sector, dist)
        return if y1 >= y2

        flat = @flats[sector.floor_texture]
        return unless flat

        light_diminish = (dist / 16.0).to_i
        colormap_idx = (31 - (sector.light_level >> 3) + light_diminish).clamp(0, 31)

        (y1...y2).each do |y|
          next if y < 0 || y >= SCREEN_HEIGHT

          # Simple flat color for now (proper perspective later)
          color = flat[(x + y) % 64, (y * 2) % 64]
          color = @colormap.maps[colormap_idx][color]
          set_pixel(x, y, color)
        end
      end

      def draw_ceiling_column(x, y1, y2, sector, dist)
        return if y1 >= y2

        flat = @flats[sector.ceiling_texture]

        light_diminish = (dist / 16.0).to_i
        colormap_idx = (31 - (sector.light_level >> 3) + light_diminish).clamp(0, 31)

        (y1...y2).each do |y|
          next if y < 0 || y >= SCREEN_HEIGHT

          if flat
            color = flat[(x + y) % 64, (y * 2) % 64]
          else
            # Sky
            color = 0
          end
          color = @colormap.maps[colormap_idx][color]
          set_pixel(x, y, color)
        end
      end

      def set_pixel(x, y, color)
        return if x < 0 || x >= SCREEN_WIDTH || y < 0 || y >= SCREEN_HEIGHT

        @framebuffer[y * SCREEN_WIDTH + x] = color
      end
    end
  end
end
