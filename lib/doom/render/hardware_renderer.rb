# frozen_string_literal: true

require 'opengl'

module Doom
  module Render
    # GPU rasterizer hosted inside Gosu's OpenGL context. The initial backend
    # renders real world triangles with perspective projection and depth test.
    class HardwareRenderer < Renderer
      include OpenGL

      ANIMATED_DECORATIONS = %w[TBLU TGRN TRED SMIT COLU CAND CBRA].freeze
      Batch = Struct.new(:material, :light, :surface, :buffer, :vertex_count)
      VERTEX_STRIDE = 8 * 4
      MAX_LIGHTS = 8
      STATIC_LIGHTS = {
        44 => [0.25, 0.35, 1.0], 45 => [0.25, 1.0, 0.35],
        46 => [1.0, 0.22, 0.12], 34 => [1.0, 0.65, 0.22],
        35 => [1.0, 0.65, 0.22], 2028 => [1.0, 0.75, 0.35],
      }.freeze

      attr_reader :mesh

      def initialize(...)
        super
        @mesh = WorldMesh.new(@map)
        @geometry_signature = geometry_signature
        @gl_textures = {}
        @texture_dimensions = {}
        @gpu_batches = nil
      end

      def hardware?
        true
      end

      # Simulation still calls render_frame; hardware drawing must happen from
      # Window#draw, inside Gosu.gl, so only reset the compatibility framebuffer.
      def render_frame
        signature = geometry_signature
        if signature != @geometry_signature
          @mesh = WorldMesh.new(@map)
          @geometry_signature = signature
          @gpu_batches_dirty = true
        end
        @framebuffer.fill(0)
      end

      def draw_hardware(viewport_width, viewport_height)
        Gosu.gl do
          load_opengl_library
          glEnable(GL_DEPTH_TEST)
          glEnable(GL_CULL_FACE)
          glCullFace(GL_BACK)
          glFrontFace(GL_CCW)
          glEnable(GL_TEXTURE_2D)
          glDepthFunc(GL_LEQUAL)
          glClearColor(0.025, 0.025, 0.04, 1.0)
          glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)

          draw_sky

          glMatrixMode(GL_PROJECTION)
          glLoadIdentity
          aspect = viewport_width.to_f / viewport_height
          glFrustum(-1.0, 1.0, -1.0 / aspect, 1.0 / aspect, 1.0, 16_384.0)
          glMatrixMode(GL_MODELVIEW)
          glLoadMatrixf(view_matrix.pack('f16'))

          rebuild_gpu_batches if @gpu_batches.nil? || @gpu_batches_dirty
          setup_lighting

          # Invisible back faces must still occlude rooms when the camera is
          # outside the playable map, matching the classic BSP solid-wall clip.
          draw_occluder_depth_prepass
          glEnable(GL_CULL_FACE)

          draw_gpu_batches
          glDisable(GL_LIGHTING)
          glBindTexture(GL_TEXTURE_2D, 0)
          glDisable(GL_TEXTURE_2D)
          glDisable(GL_CULL_FACE)
          # Sprites should be depth-tested against walls, not sliced by the
          # floor they stand on. Preserve the color buffer, rebuild depth from
          # walls only, then draw billboarded things.
          glClear(GL_DEPTH_BUFFER_BIT)
          draw_occluder_depth_prepass(include_ceilings: true)
          draw_sprites
          capture_frame if ENV['DOOM_GL_CAPTURE'] && !@frame_captured
          glDisable(GL_DEPTH_TEST)
        end
      end

      private

      def load_opengl_library
        return if @opengl_loaded

        if RUBY_PLATFORM.include?('darwin')
          OpenGL.load_lib('OpenGL', '/System/Library/Frameworks/OpenGL.framework')
        else
          OpenGL.load_lib
        end
        @opengl_loaded = true
      end

      def geometry_signature
        @map.sectors.flat_map { |sector| [sector.floor_height, sector.ceiling_height] }
      end

      def view_matrix
        sin = @sin_angle
        cos = @cos_angle
        # Column-major OpenGL matrix: Doom world (x,y,z) -> view
        # (right, up, -forward).
        [
          sin, 0.0, -cos, 0.0,
          -cos, 0.0, -sin, 0.0,
          0.0, 1.0, 0.0, 0.0,
          -sin * @player_x + cos * @player_y,
          -@player_z,
          cos * @player_x + sin * @player_y,
          1.0,
        ]
      end

      def rebuild_gpu_batches
        delete_gpu_batches
        groups = @mesh.triangles.group_by do |triangle|
          surface = if triangle.normal[2].zero?
                      :wall
                    elsif triangle.normal[2].negative?
                      :ceiling
                    else
                      :floor
                    end
          [triangle.material, triangle.light, surface]
        end
        @gpu_batches = groups.map do |(material, light, surface), triangles|
          texture_for(material)
          width, height = @current_texture_dimensions || [1.0, 1.0]
          floats = triangles.flat_map do |triangle|
            triangle.vertices.each_with_index.flat_map do |(x, y, z), index|
              u, v = triangle.uvs[index]
              [x, y, z, u / width, v / height, *triangle.normal]
            end
          end
          data = floats.pack('f*')
          ids = [0].pack('L')
          glGenBuffers(1, ids)
          buffer = ids.unpack1('L')
          glBindBuffer(GL_ARRAY_BUFFER, buffer)
          glBufferData(GL_ARRAY_BUFFER, data.bytesize, data, GL_STATIC_DRAW)
          Batch.new(material, light, surface, buffer, floats.size / 8)
        end
        glBindBuffer(GL_ARRAY_BUFFER, 0)
        @gpu_batches_dirty = false
      end

      def delete_gpu_batches
        return unless @gpu_batches&.any?

        ids = @gpu_batches.map(&:buffer).pack('L*')
        glDeleteBuffers(@gpu_batches.size, ids)
      end

      def draw_gpu_batches
        glEnableClientState(GL_VERTEX_ARRAY)
        glEnableClientState(GL_TEXTURE_COORD_ARRAY)
        glEnableClientState(GL_NORMAL_ARRAY)
        @gpu_batches.each do |batch|
          texture_id = texture_for(batch.material)
          glBindTexture(GL_TEXTURE_2D, texture_id || 0)
          shade = (batch.light.to_f / 255.0).clamp(0.12, 1.0)
          glColor3f(shade, shade, shade)
          bind_batch(batch)
          glDrawArrays(GL_TRIANGLES, 0, batch.vertex_count)
        end
        glDisableClientState(GL_TEXTURE_COORD_ARRAY)
        glDisableClientState(GL_NORMAL_ARRAY)
        glDisableClientState(GL_VERTEX_ARRAY)
        glBindBuffer(GL_ARRAY_BUFFER, 0)
      end

      def bind_batch(batch)
        glBindBuffer(GL_ARRAY_BUFFER, batch.buffer)
        glVertexPointer(3, GL_FLOAT, VERTEX_STRIDE, 0)
        glTexCoordPointer(2, GL_FLOAT, VERTEX_STRIDE, 12)
        glNormalPointer(GL_FLOAT, VERTEX_STRIDE, 20)
      end

      def setup_lighting
        glEnable(GL_LIGHTING)
        glEnable(GL_NORMALIZE)
        glEnable(GL_COLOR_MATERIAL)
        glColorMaterial(GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE)
        glLightModelfv(GL_LIGHT_MODEL_AMBIENT, [0.55, 0.55, 0.55, 1.0].pack('f4'))

        lights = active_lights.first(MAX_LIGHTS)
        MAX_LIGHTS.times do |index|
          slot = GL_LIGHT0 + index
          if (light = lights[index])
            glEnable(slot)
            glLightfv(slot, GL_POSITION, [light[:x], light[:y], light[:z], 1.0].pack('f4'))
            glLightfv(slot, GL_DIFFUSE, [*light[:color], 1.0].pack('f4'))
            glLightf(slot, GL_CONSTANT_ATTENUATION, 0.25)
            glLightf(slot, GL_LINEAR_ATTENUATION, 0.004)
            glLightf(slot, GL_QUADRATIC_ATTENUATION, 0.000018)
          else
            glDisable(slot)
          end
        end
      end

      def active_lights
        lights = @map.things.filter_map do |thing|
          color = STATIC_LIGHTS[thing.type]
          next unless color

          sector = @map.sector_at(thing.x, thing.y)
          { x: thing.x.to_f, y: thing.y.to_f,
            z: (sector&.floor_height || 0) + 40.0, color: color }
        end
        if @combat
          @combat.projectiles.each do |projectile|
            lights << { x: projectile.x, y: projectile.y, z: projectile.z,
                        color: [1.0, 0.45, 0.12] }
          end
          @combat.explosions.each do |explosion|
            lights << { x: explosion[:x], y: explosion[:y], z: explosion[:z] || @player_z,
                        color: [1.0, 0.3, 0.05] }
          end
        end
        if @view_player&.state&.attacking && @view_player.state.attack_frame <= 1
          lights << { x: @view_player.x + @view_player.cos_angle * 24.0,
                      y: @view_player.y + @view_player.sin_angle * 24.0,
                      z: @view_player.z, color: [1.0, 0.72, 0.3] }
        end
        lights.sort_by { |light| (light[:x] - @player_x)**2 + (light[:y] - @player_y)**2 }
      end

      def draw_occluder_depth_prepass(include_ceilings: false)
        glDisable(GL_CULL_FACE)
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE)
        glEnableClientState(GL_VERTEX_ARRAY)
        @gpu_batches.each do |batch|
          next unless batch.surface == :wall || (include_ceilings && batch.surface == :ceiling)

          bind_batch(batch)
          glDrawArrays(GL_TRIANGLES, 0, batch.vertex_count)
        end
        glDisableClientState(GL_VERTEX_ARRAY)
        glBindBuffer(GL_ARRAY_BUFFER, 0)
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE)
      end

      def capture_frame
        require 'chunky_png'
        viewport_data = [0, 0, 0, 0].pack('l4')
        glGetIntegerv(GL_VIEWPORT, viewport_data)
        _x, _y, width, height = viewport_data.unpack('l4')
        pixels = Fiddle::Pointer.malloc(width * height * 4)
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
        bytes = pixels[0, width * height * 4]
        image = ChunkyPNG::Image.new(width, height)
        height.times do |screen_y|
          source_y = height - 1 - screen_y
          width.times do |screen_x|
            offset = (source_y * width + screen_x) * 4
            red, green, blue, alpha = bytes.byteslice(offset, 4).unpack('C4')
            image[screen_x, screen_y] = ChunkyPNG::Color.rgba(red, green, blue, alpha)
          end
        end
        image.save(ENV.fetch('DOOM_GL_CAPTURE'))
        @frame_captured = true
      end

      def material_color(name, shade)
        hash = name.to_s.each_byte.reduce(2_166_136_261) { |value, byte| (value ^ byte) * 16_777_619 }
        base = [0.45 + (hash & 0xff) / 1024.0,
                0.38 + ((hash >> 8) & 0xff) / 1280.0,
                0.30 + ((hash >> 16) & 0xff) / 1536.0]
        base.map { |channel| (channel * shade).clamp(0.0, 1.0) }
      end

      def texture_for(name)
        return nil if name.nil? || name.empty? || name == '-' || name == 'F_SKY1'

        if @flats.key?(name)
          resolved = @animations ? @animations.translate_flat(name) : name
          source = @flats[resolved]
        else
          resolved = @animations ? @animations.translate_texture(name) : name
          source = @textures[resolved]
        end
        unless source
          @current_texture_dimensions = nil
          return nil
        end

        width = source.width
        height = source.height
        @current_texture_dimensions = [width.to_f, height.to_f]
        return @gl_textures[resolved] if @gl_textures.key?(resolved)

        @texture_dimensions[resolved] = @current_texture_dimensions
        indices = if source.respond_to?(:column_pixels)
                    Array.new(width * height) do |offset|
                      x = offset % width
                      y = offset / width
                      source.column_pixels(x)[y] || 0
                    end
                  else
                    source.pixels
                  end
        rgba = indices.map { |index| [*@palette.colors[index], 255].pack('C4') }.join
        ids = [0].pack('L')
        glGenTextures(1, ids)
        id = ids.unpack1('L')
        glBindTexture(GL_TEXTURE_2D, id)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, rgba)
        @gl_textures[resolved] = id
      end

      def draw_sky
        texture_id = texture_for('SKY1')
        return unless texture_id

        glDisable(GL_DEPTH_TEST)
        glDisable(GL_CULL_FACE)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity
        glBindTexture(GL_TEXTURE_2D, texture_id)
        glColor3f(1.0, 1.0, 1.0)
        # Match Renderer::SKY_TEXTUREMID/SKY_YSCALE: Doom projects 200 sky
        # texels over the 240-pixel view, wrapping the 128px SKY1 vertically.
        bottom_v = 200.0 / 128.0
        glBegin(GL_QUAD_STRIP)
        (0..SCREEN_WIDTH).each do |column|
          screen_x = (column.to_f / SCREEN_WIDTH) * 2.0 - 1.0
          column_angle = @player_angle - Math.atan2(column - HALF_WIDTH, @projection)
          u = column_angle * 2.0 / Math::PI
          glTexCoord2f(u, bottom_v); glVertex3f(screen_x, -1.0, 0.0)
          glTexCoord2f(u, 0.0);      glVertex3f(screen_x, 1.0, 0.0)
        end
        glEnd
        glEnable(GL_DEPTH_TEST)
        glEnable(GL_CULL_FACE)
      end

      def draw_sprites
        return unless @sprites

        glEnable(GL_TEXTURE_2D)
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        glEnable(GL_ALPHA_TEST)
        glAlphaFunc(GL_GREATER, 0.01)

        @map.things.each_with_index do |thing, index|
          next if @hidden_things && @hidden_things[index]

          sprite = sprite_for_thing(thing, index)
          next unless sprite

          id = sprite_texture(sprite)
          next unless id

          sector = @map.sector_at(thing.x, thing.y)
          floor = sector ? sector.floor_height : 0
          top = floor + sprite.top_offset
          bottom = top - sprite.height
          right_x = @sin_angle
          right_y = -@cos_angle
          left_x = thing.x - right_x * sprite.left_offset
          left_y = thing.y - right_y * sprite.left_offset
          right_edge_x = left_x + right_x * sprite.width
          right_edge_y = left_y + right_y * sprite.width

          glBindTexture(GL_TEXTURE_2D, id)
          glColor3f(1.0, 1.0, 1.0)
          glBegin(GL_QUADS)
          sprite_vertex(left_x, left_y, bottom, 0.0, 1.0)
          sprite_vertex(right_edge_x, right_edge_y, bottom, 1.0, 1.0)
          sprite_vertex(right_edge_x, right_edge_y, top, 1.0, 0.0)
          sprite_vertex(left_x, left_y, top, 0.0, 0.0)
          glEnd
        end

        glDisable(GL_ALPHA_TEST)
        glDisable(GL_BLEND)
        glDisable(GL_TEXTURE_2D)
      end

      def sprite_vertex(x, y, z, u, v)
        glTexCoord2f(u, v)
        # World coordinates: the same model-view matrix as the static VBOs
        # transforms billboards exactly once.
        glVertex3f(x, y, z)
      end

      def sprite_texture(sprite)
        key = [:sprite, sprite.name]
        return @gl_textures[key] if @gl_textures.key?(key)

        indices = Array.new(sprite.width * sprite.height) do |offset|
          x = offset % sprite.width
          y = offset / sprite.width
          sprite.column_pixels(x)[y]
        end
        rgba = indices.map do |index|
          index.nil? ? "\0\0\0\0" : [*@palette.colors[index], 255].pack('C4')
        end.join
        @gl_textures[key] = upload_texture(sprite.width, sprite.height, rgba)
      end

      def sprite_for_thing(thing, index)
        angle = Math.atan2(thing.y - @player_y, thing.x - @player_x)
        if @combat&.dead?(index)
          @combat.death_sprite(index, thing.type, angle, thing.angle)
        elsif @monster_ai && (monster = @monster_ai.monster_by_thing_idx[index])&.active
          prefix = @sprites.prefix_for(thing.type)
          if monster.attacking
            frames = Game::MonsterAI::ATTACK_FRAMES[prefix]
            frame = frames && frames[(monster.attack_frame_tic / Game::MonsterAI::ATTACK_FRAME_TICS)
                                     .clamp(0, frames.size - 1)]
          else
            frame = %w[A B C D][@leveltime / 4 % 4]
          end
          (frame && @sprites.get_frame(thing.type, frame, angle, thing.angle)) ||
            @sprites.get_rotated(thing.type, angle, thing.angle)
        else
          prefix = @sprites.prefix_for(thing.type)
          if ANIMATED_DECORATIONS.include?(prefix)
            frame = %w[A B C D][@leveltime / 6 % 4]
            @sprites.get_frame(thing.type, frame, angle, thing.angle) ||
              @sprites.get_rotated(thing.type, angle, thing.angle)
          else
            # This path respects THING_DEFAULT_FRAME (e.g. PLAYN/PLAYW for
            # corpses and blood pools) instead of blindly selecting PLAYA-D.
            @sprites.get_rotated(thing.type, angle, thing.angle)
          end
        end
      end

      def upload_texture(width, height, rgba)
        ids = [0].pack('L')
        glGenTextures(1, ids)
        id = ids.unpack1('L')
        glBindTexture(GL_TEXTURE_2D, id)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, rgba)
        id
      end
    end
  end
end
