# frozen_string_literal: true

module Doom
  module Render
    # GPU ray tracer hosted in Gosu's OpenGL context. World triangles are kept
    # in a floating-point data texture and intersected by a fragment shader;
    # the old hardware renderer is inherited only for texture/sprite/UI glue.
    class RayTracingRenderer < HardwareRenderer
      DATA_WIDTH = 1024
      NODE_DATA_WIDTH = 1024
      TEXELS_PER_TRIANGLE = 7
      TEXELS_PER_NODE = 3
      BVH_LEAF_SIZE = 8
      MAX_RAY_LIGHTS = 8
      RAY_WIDTH = 640
      RAY_HEIGHT = 480
      MAX_TRIANGLES = 4096
      ATLAS_SIZE = 2048

      VERTEX_SHADER = <<~GLSL
        #version 120
        varying vec2 screen_uv;
        void main() {
          screen_uv = gl_MultiTexCoord0.xy;
          gl_Position = gl_Vertex;
        }
      GLSL

      FRAGMENT_SHADER = <<~GLSL
        #version 120
        varying vec2 screen_uv;
        uniform sampler2D triangle_data;
        uniform sampler2D bvh_data;
        uniform sampler2D material_atlas;
        uniform sampler2D sky_texture;
        uniform float data_height;
        uniform float bvh_height;
        uniform int node_count;
        uniform vec3 camera_position;
        uniform vec3 camera_forward;
        uniform vec3 camera_right;
        uniform vec3 camera_up;
        uniform float aspect_ratio;
        uniform int light_count;
        uniform vec4 light_positions[#{MAX_RAY_LIGHTS}];
        uniform vec4 light_colors[#{MAX_RAY_LIGHTS}];
        uniform int fog_enabled;
        uniform int flashlight_enabled;

        vec4 datum(float index) {
          float x = mod(index, #{DATA_WIDTH}.0);
          float y = floor(index / #{DATA_WIDTH}.0);
          return texture2D(triangle_data,
            vec2((x + 0.5) / #{DATA_WIDTH}.0, (y + 0.5) / data_height));
        }

        vec4 node_datum(float index) {
          float x = mod(index, #{NODE_DATA_WIDTH}.0);
          float y = floor(index / #{NODE_DATA_WIDTH}.0);
          return texture2D(bvh_data,
            vec2((x + 0.5) / #{NODE_DATA_WIDTH}.0, (y + 0.5) / bvh_height));
        }

        bool intersect_box(vec3 origin, vec3 inverse_direction, vec3 minimum,
                           vec3 maximum, float distance_limit) {
          vec3 near_values = (minimum - origin) * inverse_direction;
          vec3 far_values = (maximum - origin) * inverse_direction;
          vec3 low = min(near_values, far_values);
          vec3 high = max(near_values, far_values);
          float near_distance = max(max(low.x, low.y), max(low.z, 0.0));
          float far_distance = min(min(high.x, high.y), high.z);
          return near_distance <= far_distance && near_distance < distance_limit;
        }

        bool intersect_triangle(vec3 origin, vec3 direction, float base,
                                out float distance, out vec2 barycentric) {
          vec3 a = datum(base).xyz;
          vec3 b = datum(base + 1.0).xyz;
          vec3 c = datum(base + 2.0).xyz;
          vec3 edge1 = b - a;
          vec3 edge2 = c - a;
          vec3 p = cross(direction, edge2);
          float determinant = dot(edge1, p);
          if (abs(determinant) < 0.00001) return false;
          float inverse = 1.0 / determinant;
          vec3 t = origin - a;
          float u = dot(t, p) * inverse;
          if (u < 0.0 || u > 1.0) return false;
          vec3 q = cross(t, edge1);
          float v = dot(direction, q) * inverse;
          if (v < 0.0 || u + v > 1.0) return false;
          distance = dot(edge2, q) * inverse;
          barycentric = vec2(u, v);
          return distance > 0.01;
        }

        bool accepts_surface(float base, vec2 barycentric) {
          float flags = datum(base + 3.0).w;
          if (flags < 2048.0) return true;
          vec4 uv0_uv1 = datum(base + 4.0);
          vec4 uv2_rect = datum(base + 5.0);
          vec4 rect_size = datum(base + 6.0);
          float w = 1.0 - barycentric.x - barycentric.y;
          vec2 uv = uv0_uv1.xy * w + uv0_uv1.zw * barycentric.x +
                    uv2_rect.xy * barycentric.y;
          vec2 wrapped = fract(uv / rect_size.zw);
          vec2 atlas_uv = rect_size.xy + wrapped * uv2_rect.zw;
          return texture2D(material_atlas, atlas_uv).a > 0.5;
        }

        bool shadowed(vec3 origin, vec3 direction, float maximum) {
          vec3 inverse_direction = 1.0 / direction;
          int node_index = 0;
          while (node_index < node_count) {
            float node_base = float(node_index * #{TEXELS_PER_NODE});
            vec4 minimum_escape = node_datum(node_base);
            vec4 maximum_start = node_datum(node_base + 1.0);
            int escape = int(minimum_escape.w + 0.5);
            if (!intersect_box(origin, inverse_direction, minimum_escape.xyz,
                               maximum_start.xyz, maximum)) {
              node_index = escape;
              continue;
            }
            if (maximum_start.w >= 0.0) {
              int start = int(maximum_start.w + 0.5);
              int count = int(node_datum(node_base + 2.0).x + 0.5);
              for (int offset = 0; offset < #{BVH_LEAF_SIZE}; ++offset) {
                if (offset >= count) break;
                float distance;
                vec2 barycentric;
                float triangle_base = float((start + offset) * #{TEXELS_PER_TRIANGLE});
                if (intersect_triangle(origin, direction, triangle_base,
                                       distance, barycentric) && distance < maximum &&
                    accepts_surface(triangle_base, barycentric)) return true;
              }
              node_index = escape;
            } else {
              node_index += 1;
            }
          }
          return false;
        }

        void main() {
          vec2 plane = screen_uv * 2.0 - 1.0;
          plane.y /= aspect_ratio;
          vec3 direction = normalize(camera_forward + camera_right * plane.x + camera_up * plane.y);
          float nearest = 1.0e20;
          int hit = -1;
          vec2 hit_barycentric = vec2(0.0);
          vec3 inverse_direction = 1.0 / direction;
          int node_index = 0;
          while (node_index < node_count) {
            float node_base = float(node_index * #{TEXELS_PER_NODE});
            vec4 minimum_escape = node_datum(node_base);
            vec4 maximum_start = node_datum(node_base + 1.0);
            int escape = int(minimum_escape.w + 0.5);
            if (!intersect_box(camera_position, inverse_direction, minimum_escape.xyz,
                               maximum_start.xyz, nearest)) {
              node_index = escape;
              continue;
            }
            if (maximum_start.w >= 0.0) {
              int start = int(maximum_start.w + 0.5);
              int count = int(node_datum(node_base + 2.0).x + 0.5);
              for (int offset = 0; offset < #{BVH_LEAF_SIZE}; ++offset) {
                if (offset >= count) break;
                int triangle_index = start + offset;
                float distance;
                vec2 barycentric;
                float triangle_base = float(triangle_index * #{TEXELS_PER_TRIANGLE});
                if (intersect_triangle(camera_position, direction, triangle_base,
                                       distance, barycentric) && distance < nearest &&
                    accepts_surface(triangle_base, barycentric)) {
                  nearest = distance;
                  hit = triangle_index;
                  hit_barycentric = barycentric;
                }
              }
              node_index = escape;
            } else {
              node_index += 1;
            }
          }
          if (hit < 0) {
            // Match HardwareRenderer::draw_sky and Doom's SKY1 density:
            // repeat the 256px panorama four times around the player and map
            // 200 sky texels over the full view height.
            float sky_u = atan(direction.y, direction.x) * 2.0 / 3.14159265;
            float sky_v = (1.0 - screen_uv.y) * (200.0 / 128.0);
            vec3 sky = texture2D(sky_texture, vec2(sky_u, sky_v)).rgb;
            gl_FragColor = vec4(sky * 0.45, 1.0);
            return;
          }
          float base = float(hit * #{TEXELS_PER_TRIANGLE});
          vec4 normal_light = datum(base + 3.0);
          vec4 uv0_uv1 = datum(base + 4.0);
          vec4 uv2_rect = datum(base + 5.0);
          vec4 rect_size = datum(base + 6.0);
          float w = 1.0 - hit_barycentric.x - hit_barycentric.y;
          vec2 uv = uv0_uv1.xy * w + uv0_uv1.zw * hit_barycentric.x + uv2_rect.xy * hit_barycentric.y;
          vec2 wrapped = fract(uv / rect_size.zw);
          vec2 atlas_uv = rect_size.xy + wrapped * uv2_rect.zw;
          vec3 albedo = texture2D(material_atlas, atlas_uv).rgb;
          vec3 normal = normalize(normal_light.xyz);
          if (dot(normal, direction) > 0.0) normal = -normal;
          vec3 point = camera_position + direction * nearest;
          float emission = floor(mod(normal_light.w, 2048.0) / 1024.0);
          float sector = clamp(mod(normal_light.w, 1024.0) / 255.0, 0.10, 1.0);
          vec3 ambient = albedo * sector * 0.32;
          vec3 direct = vec3(0.0);
          float strongest_score = 0.0;
          float second_score = 0.0;
          vec3 strongest_direct = vec3(0.0);
          vec3 second_direct = vec3(0.0);
          vec3 strongest_direction = vec3(0.0);
          vec3 second_direction = vec3(0.0);
          float strongest_distance = 0.0;
          float second_distance = 0.0;
          for (int light_index = 0; light_index < #{MAX_RAY_LIGHTS}; ++light_index) {
            if (light_index >= light_count) break;
            vec3 to_light = light_positions[light_index].xyz - point;
            float light_distance = length(to_light);
            vec3 light_direction = to_light / max(light_distance, 0.001);
            float diffuse = max(dot(normal, light_direction), 0.0);
            // A gentler physically-shaped falloff keeps distant visible lamps
            // contributing instead of crossing an apparent hard threshold.
            float attenuation = 1.0 / (1.0 + light_distance * 0.0015 +
                                       light_distance * light_distance * 0.000004);
            float contribution = diffuse * attenuation;
            if (contribution < 0.003) continue;
            vec3 light_direct = albedo * light_colors[light_index].rgb * contribution * 1.8;
            direct += light_direct;
            float score = contribution * dot(light_colors[light_index].rgb, vec3(0.30, 0.59, 0.11));
            if (score > strongest_score) {
              second_score = strongest_score;
              second_direct = strongest_direct;
              second_direction = strongest_direction;
              second_distance = strongest_distance;
              strongest_score = score;
              strongest_direct = light_direct;
              strongest_direction = light_direction;
              strongest_distance = light_distance;
            } else if (score > second_score) {
              second_score = score;
              second_direct = light_direct;
              second_direction = light_direction;
              second_distance = light_distance;
            }
          }
          // All lights illuminate, but only the two dominant contributors
          // launch expensive BVH shadow rays for this particular surface.
          if (strongest_score > 0.003 && shadowed(point + normal * 0.08,
              strongest_direction, strongest_distance - 0.1))
            direct -= strongest_direct * 0.92;
          if (second_score > 0.003 && shadowed(point + normal * 0.08,
              second_direction, second_distance - 0.1))
            direct -= second_direct * 0.92;

          if (flashlight_enabled != 0) {
            vec3 camera_to_point = normalize(point - camera_position);
            float cone = smoothstep(0.80, 0.96, dot(camera_to_point, camera_forward));
            vec3 point_to_camera = -camera_to_point;
            float facing = max(dot(normal, point_to_camera), 0.0);
            float flashlight_attenuation = 1.0 / (1.0 + nearest * 0.0015 +
                                                  nearest * nearest * 0.000002);
            float flashlight_strength = cone * facing * flashlight_attenuation;
            if (flashlight_strength > 0.004) {
              float flashlight_visible = shadowed(point + normal * 0.08,
                point_to_camera, nearest - 0.15) ? 0.06 : 1.0;
              direct += albedo * vec3(1.0, 0.88, 0.68) * flashlight_strength *
                        flashlight_visible * 2.2;
            }
          }

          vec3 shaded = ambient + direct;
          if (emission > 0.5)
            shaded += albedo * vec3(0.18, 0.62, 0.12);
          if (fog_enabled != 0) {
            float fog = clamp(1.0 - exp(-nearest * 0.00075), 0.0, 0.82);
            shaded = mix(shaded, vec3(0.035, 0.045, 0.060), fog);
          }
          gl_FragColor = vec4(shaded, 1.0);
        }
      GLSL

      SPRITE_VERTEX_SHADER = <<~GLSL
        #version 120
        varying vec2 sprite_uv;
        varying vec3 world_position;
        void main() {
          sprite_uv = gl_MultiTexCoord0.xy;
          world_position = gl_Vertex.xyz;
          gl_Position = ftransform();
        }
      GLSL

      SPRITE_FRAGMENT_SHADER = <<~GLSL
        #version 120
        varying vec2 sprite_uv;
        varying vec3 world_position;
        uniform sampler2D sprite_texture;
        uniform float sector_light;
        uniform int light_count;
        uniform vec4 light_positions[#{MAX_RAY_LIGHTS}];
        uniform vec4 light_colors[#{MAX_RAY_LIGHTS}];
        uniform vec3 camera_position;
        uniform vec3 camera_forward;
        uniform int fog_enabled;
        uniform int flashlight_enabled;

        void main() {
          vec4 texel = texture2D(sprite_texture, sprite_uv);
          if (texel.a < 0.01) discard;
          vec3 shaded = texel.rgb * clamp(sector_light, 0.10, 1.0) * 0.32;
          for (int light_index = 0; light_index < #{MAX_RAY_LIGHTS}; ++light_index) {
            if (light_index >= light_count) break;
            float distance_to_light = length(light_positions[light_index].xyz - world_position);
            float attenuation = 1.0 / (1.0 + distance_to_light * 0.0015 +
                                       distance_to_light * distance_to_light * 0.000004);
            shaded += texel.rgb * light_colors[light_index].rgb * attenuation * 0.75;
          }
          vec3 camera_to_point = world_position - camera_position;
          float distance_to_camera = length(camera_to_point);
          if (flashlight_enabled != 0 && distance_to_camera > 0.001) {
            float cone = smoothstep(0.80, 0.96,
              dot(camera_to_point / distance_to_camera, camera_forward));
            float attenuation = 1.0 / (1.0 + distance_to_camera * 0.0015 +
                                       distance_to_camera * distance_to_camera * 0.000002);
            shaded += texel.rgb * vec3(1.0, 0.88, 0.68) * cone * attenuation * 1.5;
          }
          if (fog_enabled != 0) {
            float fog = clamp(1.0 - exp(-distance_to_camera * 0.00075), 0.0, 0.82);
            shaded = mix(shaded, vec3(0.035, 0.045, 0.060), fog);
          }
          gl_FragColor = vec4(shaded, texel.a);
        }
      GLSL

      def ray_tracing?
        true
      end

      attr_accessor :fog_enabled, :flashlight_enabled

      def initialize(...)
        super
        @ray_materials = RayTracing::MaterialState.new(@flats, @animations)
        @fog_enabled = true
        @flashlight_enabled = true
      end

      def render_frame
        signature = geometry_signature
        if signature != @geometry_signature
          @mesh = WorldMesh.new(@map, @textures)
          @geometry_signature = signature
          @ray_scene_dirty = true
          @gpu_batches_dirty = true
        end
        @framebuffer.fill(0)
      end

      def draw_hardware(viewport_width, viewport_height)
        Gosu.gl do
          load_opengl_library
          current_animation = @ray_materials.animation_signature
          if @ray_animation_signature != current_animation
            @ray_animation_signature = current_animation
            @ray_materials_dirty = true if @ray_data_texture
          end
          build_ray_scene if @ray_program.nil? || @ray_scene_dirty
          if @ray_materials_dirty
            upload_triangle_data
            @ray_materials_dirty = false
          end
          ensure_ray_target
          viewport = [0, 0, 0, 0].pack('l4')
          glGetIntegerv(GL_VIEWPORT, viewport)
          viewport_x, viewport_y, physical_width, physical_height = viewport.unpack('l4')
          glDisable(GL_DEPTH_TEST)
          glDisable(GL_CULL_FACE)
          glDisable(GL_LIGHTING)
          glClearColor(0.0, 0.0, 0.0, 1.0)
          glBindFramebuffer(GL_FRAMEBUFFER, @ray_framebuffer)
          glViewport(0, 0, RAY_WIDTH, RAY_HEIGHT)
          glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
          draw_ray_pass(RAY_WIDTH, RAY_HEIGHT)
          glBindFramebuffer(GL_FRAMEBUFFER, 0)
          glViewport(viewport_x, viewport_y, physical_width, physical_height)
          glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
          draw_ray_target
          setup_camera(viewport_width, viewport_height)
          rebuild_gpu_batches if @gpu_batches.nil? || @gpu_batches_dirty
          glClear(GL_DEPTH_BUFFER_BIT)
          draw_occluder_depth_prepass(include_ceilings: true)
          draw_sprites
          capture_frame if ENV['DOOM_GL_CAPTURE'] && !@frame_captured
          # Gosu draws the weapon, HUD and pause menu immediately after this
          # block. Do not leak sprite-shader or modulation state into its 2D
          # pipeline, otherwise menu text inherits scene lighting.
          glUseProgram(0)
          glActiveTexture(GL_TEXTURE0)
          glBindTexture(GL_TEXTURE_2D, 0)
          glColor4f(1.0, 1.0, 1.0, 1.0)
          glDisable(GL_LIGHTING)
          glDisable(GL_ALPHA_TEST)
          glDisable(GL_BLEND)
          glDisable(GL_TEXTURE_2D)
          glDisable(GL_DEPTH_TEST)
        end
      end

      private

      def draw_sprites
        @sprite_program ||= create_program(SPRITE_VERTEX_SHADER, SPRITE_FRAGMENT_SHADER)
        glUseProgram(@sprite_program)
        uniform1i('sprite_texture', 0, program: @sprite_program)
        uniform1i('fog_enabled', @fog_enabled ? 1 : 0, program: @sprite_program)
        uniform1i('flashlight_enabled', @flashlight_enabled ? 1 : 0, program: @sprite_program)
        uniform3f('camera_position', @player_x, @player_y, @player_z, program: @sprite_program)
        uniform3f('camera_forward', @cos_angle, @sin_angle, 0.0, program: @sprite_program)
        lights = ray_lights.first(MAX_RAY_LIGHTS)
        uniform1i('light_count', lights.size, program: @sprite_program)
        positions = lights.flat_map { |light| [light[:x].to_f, light[:y].to_f, light[:z].to_f, 1.0] }
        colors = lights.flat_map { |light| [*light[:color].map(&:to_f), 1.0] }
        positions.concat(Array.new((MAX_RAY_LIGHTS - lights.size) * 4, 0.0))
        colors.concat(Array.new((MAX_RAY_LIGHTS - lights.size) * 4, 0.0))
        uniform4fv('light_positions', MAX_RAY_LIGHTS, positions, program: @sprite_program)
        uniform4fv('light_colors', MAX_RAY_LIGHTS, colors, program: @sprite_program)
        super
      ensure
        glUseProgram(0) if @sprite_program
      end

      def before_sprite_draw(_thing, _sprite, sector)
        uniform1f('sector_light', (sector&.light_level || 128).to_f / 255.0,
                  program: @sprite_program)
      end

      def ensure_ray_target
        return if @ray_framebuffer

        @ray_target_texture = replace_texture(nil, RAY_WIDTH, RAY_HEIGHT,
                                              GL_RGBA, GL_UNSIGNED_BYTE, nil)
        ids = [0].pack('L')
        glGenFramebuffers(1, ids)
        @ray_framebuffer = ids.unpack1('L')
        glBindFramebuffer(GL_FRAMEBUFFER, @ray_framebuffer)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, @ray_target_texture, 0)
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
        raise "ray framebuffer incomplete: 0x#{status.to_s(16)}" unless status == GL_FRAMEBUFFER_COMPLETE
        glBindFramebuffer(GL_FRAMEBUFFER, 0)
      end

      def draw_ray_target
        glUseProgram(0)
        glActiveTexture(GL_TEXTURE0)
        glEnable(GL_TEXTURE_2D)
        glBindTexture(GL_TEXTURE_2D, @ray_target_texture)
        glColor3f(1.0, 1.0, 1.0)
        glMatrixMode(GL_PROJECTION); glLoadIdentity
        glMatrixMode(GL_MODELVIEW); glLoadIdentity
        glBegin(GL_QUADS)
        glTexCoord2f(0.0, 0.0); glVertex2f(-1.0, -1.0)
        glTexCoord2f(1.0, 0.0); glVertex2f(1.0, -1.0)
        glTexCoord2f(1.0, 1.0); glVertex2f(1.0, 1.0)
        glTexCoord2f(0.0, 1.0); glVertex2f(-1.0, 1.0)
        glEnd
      end

      def setup_camera(width, height)
        glEnable(GL_DEPTH_TEST)
        glDepthFunc(GL_LEQUAL)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity
        aspect = width.to_f / height
        glFrustum(-1.0, 1.0, -1.0 / aspect, 1.0 / aspect, 1.0, 16_384.0)
        glMatrixMode(GL_MODELVIEW)
        glLoadMatrixf(view_matrix.pack('f16'))
      end

      def draw_ray_pass(width, height)
        # texture_for binds as a side effect. Resolve the sky before assigning
        # fixed sampler units so it cannot replace the material atlas.
        glActiveTexture(GL_TEXTURE0)
        sky_texture = texture_for('SKY1')
        glUseProgram(@ray_program)
        bind_ray_texture(GL_TEXTURE0, @ray_data_texture, 'triangle_data', 0)
        bind_ray_texture(GL_TEXTURE1, @ray_bvh_texture, 'bvh_data', 1)
        bind_ray_texture(GL_TEXTURE2, @ray_atlas_texture, 'material_atlas', 2)
        bind_ray_texture(GL_TEXTURE3, sky_texture, 'sky_texture', 3)
        uniform1f('data_height', @ray_data_height)
        uniform1f('bvh_height', @ray_bvh_height)
        uniform1i('node_count', @ray_bvh.nodes.size)
        uniform1i('fog_enabled', @fog_enabled ? 1 : 0)
        uniform1i('flashlight_enabled', @flashlight_enabled ? 1 : 0)
        uniform3f('camera_position', @player_x, @player_y, @player_z)
        uniform3f('camera_forward', @cos_angle, @sin_angle, 0.0)
        uniform3f('camera_right', @sin_angle, -@cos_angle, 0.0)
        uniform3f('camera_up', 0.0, 0.0, 1.0)
        uniform1f('aspect_ratio', width.to_f / height)
        lights = ray_lights.first(MAX_RAY_LIGHTS)
        uniform1i('light_count', lights.size)
        positions = lights.flat_map { |light| [light[:x].to_f, light[:y].to_f, light[:z].to_f, 1.0] }
        colors = lights.flat_map { |light| [*light[:color].map(&:to_f), 1.0] }
        positions.concat(Array.new((MAX_RAY_LIGHTS - lights.size) * 4, 0.0))
        colors.concat(Array.new((MAX_RAY_LIGHTS - lights.size) * 4, 0.0))
        uniform4fv('light_positions', MAX_RAY_LIGHTS, positions)
        uniform4fv('light_colors', MAX_RAY_LIGHTS, colors)
        glMatrixMode(GL_PROJECTION); glLoadIdentity
        glMatrixMode(GL_MODELVIEW); glLoadIdentity
        glBegin(GL_QUADS)
        glTexCoord2f(0.0, 0.0); glVertex2f(-1.0, -1.0)
        glTexCoord2f(1.0, 0.0); glVertex2f(1.0, -1.0)
        glTexCoord2f(1.0, 1.0); glVertex2f(1.0, 1.0)
        glTexCoord2f(0.0, 1.0); glVertex2f(-1.0, 1.0)
        glEnd
        glUseProgram(0)
        glActiveTexture(GL_TEXTURE0)
      end

      def build_ray_scene
        unless @ray_program
          @ray_program = create_program(VERTEX_SHADER, FRAGMENT_SHADER)
        end
        unless @ray_atlas_texture
          materials = @mesh.triangles.map(&:material).compact
          if @animations
            materials.concat(@ray_materials.animation_names)
          end
          atlas_builder = RayTracing::TextureAtlas.new(
            size: ATLAS_SIZE, textures: @textures, flats: @flats, palette: @palette
          )
          atlas, @ray_material_rectangles = atlas_builder.build(materials)
          @ray_atlas_texture = replace_texture(nil, ATLAS_SIZE, ATLAS_SIZE,
                                               GL_RGBA, GL_UNSIGNED_BYTE, atlas)
        end
        source_triangles = @mesh.triangles.first(MAX_TRIANGLES)
        if @ray_bvh&.compatible?(source_triangles)
          @ray_bvh.refit(source_triangles)
        else
          @ray_bvh = RayTracing::Bvh.new(source_triangles, leaf_size: BVH_LEAF_SIZE)
        end
        upload_triangle_data
        upload_bvh
        @ray_scene_dirty = false
        @ray_materials_dirty = false
      end

      def upload_triangle_data
        rectangles = @ray_material_rectangles
        floats = []
        @ray_bvh.triangles.each do |triangle|
          triangle.vertices.each { |vertex| floats.concat([*vertex, 0.0]) }
          floats.concat([*triangle.normal, @ray_materials.encoded_light(triangle)])
          floats.concat([*triangle.uvs[0], *triangle.uvs[1]])
          material = @ray_materials.resolve(triangle.material)
          rect = rectangles.fetch(material, [0.0, 0.0, 1.0 / ATLAS_SIZE, 1.0 / ATLAS_SIZE, 1.0, 1.0])
          floats.concat([*triangle.uvs[2], rect[2], rect[3]])
          floats.concat([rect[0], rect[1], rect[4], rect[5]])
        end
        texel_count = floats.size / 4
        @ray_data_height = [(texel_count.to_f / DATA_WIDTH).ceil, 1].max
        floats.concat(Array.new(DATA_WIDTH * @ray_data_height * 4 - floats.size, 0.0))
        @ray_data_texture = replace_texture(@ray_data_texture, DATA_WIDTH, @ray_data_height, GL_RGBA32F, GL_FLOAT, floats.pack('f*'))
      end

      def upload_bvh
        floats = @ray_bvh.packed_floats
        texels = floats.size / 4
        @ray_bvh_height = [(texels.to_f / NODE_DATA_WIDTH).ceil, 1].max
        floats.concat(Array.new(NODE_DATA_WIDTH * @ray_bvh_height * 4 - floats.size, 0.0))
        @ray_bvh_texture = replace_texture(@ray_bvh_texture, NODE_DATA_WIDTH, @ray_bvh_height,
                                           GL_RGBA32F, GL_FLOAT, floats.pack('f*'))
      end

      def ray_lights
        lights = active_lights + acid_lights
        lights.sort_by { |light| (light[:x] - @player_x)**2 + (light[:y] - @player_y)**2 }
      end

      def acid_lights
        @acid_lights ||= @map.sectors.each_with_index.filter_map do |sector, sector_index|
          next unless @ray_materials.emissive?(sector.floor_texture)

          points = @map.linedefs.flat_map do |line|
            touches = [line.sidedef_right, line.sidedef_left].compact.any? do |side_index|
              side_index >= 0 && @map.sidedefs[side_index]&.sector == sector_index
            end
            touches ? [@map.vertices[line.v1], @map.vertices[line.v2]] : []
          end.uniq { |point| [point.x, point.y] }
          next if points.empty?

          { x: points.sum(&:x).to_f / points.size,
            y: points.sum(&:y).to_f / points.size,
            z: sector.floor_height.to_f + 18.0,
            color: [0.22, 1.0, 0.18] }
        end
      end

      def replace_texture(old_id, width, height, internal, type, data)
        glDeleteTextures(1, [old_id].pack('L')) if old_id
        ids = [0].pack('L')
        glGenTextures(1, ids)
        id = ids.unpack1('L')
        glBindTexture(GL_TEXTURE_2D, id)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        glTexImage2D(GL_TEXTURE_2D, 0, internal, width, height, 0, GL_RGBA, type, data)
        id
      end

      def create_program(vertex_source, fragment_source)
        vertex = compile_shader(GL_VERTEX_SHADER, vertex_source)
        fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source)
        program = glCreateProgram
        glAttachShader(program, vertex)
        glAttachShader(program, fragment)
        glLinkProgram(program)
        status = [0].pack('L')
        glGetProgramiv(program, GL_LINK_STATUS, status)
        raise "ray shader link failed: #{program_log(program)}" if status.unpack1('L').zero?
        glDeleteShader(vertex); glDeleteShader(fragment)
        program
      end

      def compile_shader(type, source)
        shader = glCreateShader(type)
        source_pointer = Fiddle::Pointer[source]
        pointer_pointer = Fiddle::Pointer[[source_pointer.to_i].pack('J')]
        length_pointer = Fiddle::Pointer[[source.bytesize].pack('l')]
        glShaderSource(shader, 1, pointer_pointer, length_pointer)
        glCompileShader(shader)
        status = [0].pack('L')
        glGetShaderiv(shader, GL_COMPILE_STATUS, status)
        raise "ray shader compile failed: #{shader_log(shader)}" if status.unpack1('L').zero?
        shader
      end

      def shader_log(shader)
        buffer = Fiddle::Pointer.malloc(4096)
        length = Fiddle::Pointer.malloc(4)
        glGetShaderInfoLog(shader, 4096, length, buffer)
        buffer[0, length[0, 4].unpack1('l')]
      end

      def program_log(program)
        buffer = Fiddle::Pointer.malloc(4096)
        length = Fiddle::Pointer.malloc(4)
        glGetProgramInfoLog(program, 4096, length, buffer)
        buffer[0, length[0, 4].unpack1('l')]
      end

      def bind_ray_texture(unit, texture, uniform, index)
        glActiveTexture(unit); glBindTexture(GL_TEXTURE_2D, texture || 0); uniform1i(uniform, index)
      end

      def uniform1i(name, value, program: @ray_program) = glUniform1i(glGetUniformLocation(program, name), value)
      def uniform1f(name, value, program: @ray_program) = glUniform1f(glGetUniformLocation(program, name), value.to_f)
      def uniform3f(name, x, y, z, program: @ray_program)
        glUniform3f(glGetUniformLocation(program, name), x.to_f, y.to_f, z.to_f)
      end

      def uniform4fv(name, count, values, program: @ray_program)
        glUniform4fv(glGetUniformLocation(program, name), count, values.pack('f*'))
      end
    end
  end
end
