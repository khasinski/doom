# frozen_string_literal: true

module Doom
  module Render
    # Experimental renderer path. It deliberately reuses the proven BSP
    # visibility and texture sampling code while replacing the visibility
    # target with a full, per-pixel depth buffer. This makes it possible to add
    # mesh rasterisation and ray traced passes without changing game logic.
    class ZBufferRenderer < Renderer
      attr_reader :depth_buffer

      MAX_DYNAMIC_LIGHTS = 8
      LIGHT_LEVELS = 16
      Light = Struct.new(:x, :y, :z, :radius, :energy)

      def initialize(...)
        super
        @depth_buffer = Array.new(SCREEN_WIDTH * SCREEN_HEIGHT, Float::INFINITY)
        @light_lut = build_light_lut
      end

      def render_frame
        @depth_buffer.fill(Float::INFINITY)
        @dynamic_lights = collect_dynamic_lights
        super
      end

      # Opaque walls are the first geometry producer for the new depth target.
      # BSP clipping remains the visibility algorithm for this initial stage;
      # later raster passes can consume the per-pixel depth values written here.
      def draw_wall_column_ex(x, y1, y2, texture_name, dist, light_level,
                              tex_col, tex_y_start, scale, world_top)
        clip_top = @ceiling_clip[x] + 1
        clip_bottom = @floor_clip[x] - 1
        first = [[y1, clip_top, 0].max, SCREEN_HEIGHT].min
        last = [[y2, clip_bottom, SCREEN_HEIGHT - 1].min, -1].max

        super

        return if first > last || texture_name.nil? || texture_name.empty? || texture_name == '-'
        return unless @textures[anim_texture(texture_name)]

        # Reconstruct the world-space wall hit. Each dynamic source casts a
        # visibility ray to it; one-sided linedefs produce hard shadows.
        ray_distance = dist * @column_distscale[x]
        hit_x = @player_x + ray_distance * @column_cos[x]
        hit_y = @player_y - ray_distance * @column_sin[x]
        visible_lights = @dynamic_lights.select do |light|
          dx = light.x - hit_x
          dy = light.y - hit_y
          dx * dx + dy * dy < light.radius * light.radius && light_visible?(hit_x, hit_y, light)
        end

        y = first
        while y <= last
          offset = y * SCREEN_WIDTH + x
          @depth_buffer[offset] = dist if dist < @depth_buffer[offset]
          unless visible_lights.empty?
            world_z = world_top - (y - (HALF_HEIGHT - (world_top - @player_z) * scale)) / scale
            intensity = visible_lights.sum do |light|
              distance = Math.sqrt((light.x - hit_x)**2 + (light.y - hit_y)**2 + (light.z - world_z)**2)
              distance < light.radius ? light.energy * (1.0 - distance / light.radius)**2 : 0.0
            end
            level = (intensity * (LIGHT_LEVELS - 1)).to_i.clamp(0, LIGHT_LEVELS - 1)
            @framebuffer[offset] = @light_lut[level][@framebuffer[offset]] if level.positive?
          end
          y += 1
        end
      end

      private

      def collect_dynamic_lights
        return [] unless @combat

        lights = @combat.projectiles.map do |projectile|
          Light.new(projectile.x, projectile.y, projectile.z, 224.0, 1.0)
        end
        # Hitscan weapons have no projectile object. Their first attack frames
        # still produce a real, short-lived muzzle light at the camera.
        if @view_player&.state&.attacking && @view_player.state.attack_frame <= 1
          lights << Light.new(
            @view_player.x + @view_player.cos_angle * 24.0,
            @view_player.y + @view_player.sin_angle * 24.0,
            @view_player.z,
            448.0,
            1.8
          )
        end
        @combat.puffs.each do |puff|
          age = @leveltime - puff[:tic]
          energy = (1.0 - age / 12.0).clamp(0.0, 1.0)
          lights << Light.new(puff[:x], puff[:y], puff[:z], 192.0, energy * 0.8)
        end
        @combat.explosions.each do |explosion|
          age = @leveltime - explosion[:tic]
          energy = (1.0 - age / 20.0).clamp(0.0, 1.0)
          lights << Light.new(explosion[:x], explosion[:y], explosion[:z] || @player_z,
                              384.0, energy * 1.5)
        end
        lights.sort_by { |light| (light.x - @player_x)**2 + (light.y - @player_y)**2 }
              .first(MAX_DYNAMIC_LIGHTS)
      end

      # A 2D ray query matches Doom's extruded sector geometry. Portal-aware
      # height tests can later replace this conservative one-sided-wall test.
      def light_visible?(from_x, from_y, light)
        @map.linedefs.none? do |line|
          next false if line.two_sided?

          a = @map.vertices[line.v1]
          b = @map.vertices[line.v2]
          segments_intersect?(from_x, from_y, light.x, light.y, a.x, a.y, b.x, b.y)
        end
      end

      def segments_intersect?(ax, ay, bx, by, cx, cy, dx, dy)
        abx = bx - ax
        aby = by - ay
        cdx = dx - cx
        cdy = dy - cy
        denominator = abx * cdy - aby * cdx
        return false if denominator.abs < 1e-9

        acx = cx - ax
        acy = cy - ay
        t = (acx * cdy - acy * cdx) / denominator.to_f
        u = (acx * aby - acy * abx) / denominator.to_f
        t > 1e-4 && t < 0.9999 && u >= 0.0 && u <= 1.0
      end

      # Doom's target is palette-indexed. Precompute nearest palette entries
      # for a warm additive light so the geometry pass remains deterministic.
      def build_light_lut
        colors = @palette.colors
        LIGHT_LEVELS.times.map do |level|
          amount = level.to_f / (LIGHT_LEVELS - 1)
          colors.map do |red, green, blue|
            target = [red + 255 * amount, green + 176 * amount, blue + 72 * amount]
                     .map { |channel| channel.clamp(0, 255) }
            colors.each_index.min_by do |index|
              candidate = colors[index]
              (candidate[0] - target[0])**2 + (candidate[1] - target[1])**2 +
                (candidate[2] - target[2])**2
            end
          end
        end
      end
    end
  end
end
