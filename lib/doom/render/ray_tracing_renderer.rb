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
        uniform int triangle_count;
        uniform int node_count;
        uniform vec3 camera_position;
        uniform vec3 camera_forward;
        uniform vec3 camera_right;
        uniform vec3 camera_up;
        uniform float aspect_ratio;
        uniform int light_count;
        uniform vec4 light_positions[#{MAX_RAY_LIGHTS}];
        uniform vec4 light_colors[#{MAX_RAY_LIGHTS}];

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
                if (intersect_triangle(origin, direction,
                                       float((start + offset) * #{TEXELS_PER_TRIANGLE}),
                                       distance, barycentric) && distance < maximum)
                  return true;
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
                if (intersect_triangle(camera_position, direction,
                                       float(triangle_index * #{TEXELS_PER_TRIANGLE}),
                                       distance, barycentric) && distance < nearest) {
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
            float longitude = atan(direction.y, direction.x) / 6.2831853 + 0.5;
            float latitude = clamp(0.5 - direction.z * 0.65, 0.0, 1.0);
            gl_FragColor = texture2D(sky_texture, vec2(longitude, latitude));
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
          float sector = clamp(normal_light.w / 255.0, 0.10, 1.0);
          vec3 ambient = albedo * sector * 0.48;
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
          gl_FragColor = vec4(ambient + direct, 1.0);
        }
      GLSL

      def ray_tracing?
        true
      end

      def render_frame
        signature = geometry_signature
        if signature != @geometry_signature
          @mesh = WorldMesh.new(@map)
          @geometry_signature = signature
          @ray_scene_dirty = true
          @gpu_batches_dirty = true
        end
        @framebuffer.fill(0)
      end

      def draw_hardware(viewport_width, viewport_height)
        Gosu.gl do
          load_opengl_library
          build_ray_scene if @ray_program.nil? || @ray_scene_dirty
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
          glDisable(GL_DEPTH_TEST)
        end
      end

      private

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
        uniform1i('triangle_count', @ray_triangles.size)
        uniform1i('node_count', @ray_bvh_nodes.size)
        uniform3f('camera_position', @player_x, @player_y, @player_z)
        uniform3f('camera_forward', @cos_angle, @sin_angle, 0.0)
        uniform3f('camera_right', @sin_angle, -@cos_angle, 0.0)
        uniform3f('camera_up', 0.0, 0.0, 1.0)
        uniform1f('aspect_ratio', width.to_f / height)
        lights = active_lights.first(MAX_RAY_LIGHTS)
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
        warn 'Ray tracing: compiling GPU program...'
        @ray_program ||= create_program(VERTEX_SHADER, FRAGMENT_SHADER)
        warn 'Ray tracing: building material atlas...'
        atlas, rectangles = build_material_atlas(@mesh.triangles.map(&:material).compact.uniq)
        warn 'Ray tracing: uploading material atlas...'
        @ray_atlas_texture = replace_texture(@ray_atlas_texture, ATLAS_SIZE, ATLAS_SIZE, GL_RGBA, GL_UNSIGNED_BYTE, atlas)
        @ray_bvh_nodes = []
        @ray_triangles = []
        build_bvh(@mesh.triangles.first(MAX_TRIANGLES))
        floats = []
        @ray_triangles.each do |triangle|
          triangle.vertices.each { |vertex| floats.concat([*vertex, 0.0]) }
          floats.concat([*triangle.normal, triangle.light.to_f])
          floats.concat([*triangle.uvs[0], *triangle.uvs[1]])
          rect = rectangles.fetch(triangle.material, [0.0, 0.0, 1.0 / ATLAS_SIZE, 1.0 / ATLAS_SIZE, 1.0, 1.0])
          floats.concat([*triangle.uvs[2], rect[2], rect[3]])
          floats.concat([rect[0], rect[1], rect[4], rect[5]])
        end
        texel_count = floats.size / 4
        @ray_data_height = [(texel_count.to_f / DATA_WIDTH).ceil, 1].max
        floats.concat(Array.new(DATA_WIDTH * @ray_data_height * 4 - floats.size, 0.0))
        warn "Ray tracing: uploading #{@ray_triangles.size} triangles and #{@ray_bvh_nodes.size} BVH nodes..."
        @ray_data_texture = replace_texture(@ray_data_texture, DATA_WIDTH, @ray_data_height, GL_RGBA32F, GL_FLOAT, floats.pack('f*'))
        upload_bvh
        @ray_scene_dirty = false
        warn 'Ray tracing: scene ready.'
      end

      def build_bvh(triangles)
        node_index = @ray_bvh_nodes.size
        @ray_bvh_nodes << nil
        minimum, maximum = triangle_bounds(triangles)
        if triangles.size <= BVH_LEAF_SIZE
          start = @ray_triangles.size
          @ray_triangles.concat(triangles)
          @ray_bvh_nodes[node_index] = { minimum: minimum, maximum: maximum,
                                         start: start, count: triangles.size,
                                         escape: node_index + 1 }
          return node_index
        end

        centroids = triangles.map do |triangle|
          3.times.map { |axis| triangle.vertices.sum { |vertex| vertex[axis] } / 3.0 }
        end
        extents = 3.times.map { |axis| centroids.map { |center| center[axis] }.minmax.then { |a, b| b - a } }
        axis = extents.each_with_index.max_by(&:first).last
        sorted = triangles.zip(centroids).sort_by { |_triangle, center| center[axis] }.map(&:first)
        middle = sorted.size / 2
        build_bvh(sorted[0...middle])
        build_bvh(sorted[middle..])
        @ray_bvh_nodes[node_index] = { minimum: minimum, maximum: maximum,
                                       start: -1, count: 0, escape: @ray_bvh_nodes.size }
        node_index
      end

      def triangle_bounds(triangles)
        points = triangles.flat_map(&:vertices)
        minimum = 3.times.map { |axis| points.min_by { |point| point[axis] }[axis] - 0.01 }
        maximum = 3.times.map { |axis| points.max_by { |point| point[axis] }[axis] + 0.01 }
        [minimum, maximum]
      end

      def upload_bvh
        floats = []
        @ray_bvh_nodes.each do |node|
          floats.concat([*node[:minimum], node[:escape].to_f])
          floats.concat([*node[:maximum], node[:start].to_f])
          floats.concat([node[:count].to_f, 0.0, 0.0, 0.0])
        end
        texels = floats.size / 4
        @ray_bvh_height = [(texels.to_f / NODE_DATA_WIDTH).ceil, 1].max
        floats.concat(Array.new(NODE_DATA_WIDTH * @ray_bvh_height * 4 - floats.size, 0.0))
        @ray_bvh_texture = replace_texture(@ray_bvh_texture, NODE_DATA_WIDTH, @ray_bvh_height,
                                           GL_RGBA32F, GL_FLOAT, floats.pack('f*'))
      end

      def build_material_atlas(materials)
        pixels = "\0" * (ATLAS_SIZE * ATLAS_SIZE * 4)
        rectangles = {}
        x = y = row_height = 0
        materials.each do |name|
          source = material_source(name)
          next unless source
          width, height, rgba = source
          if x + width > ATLAS_SIZE
            x = 0
            y += row_height
            row_height = 0
          end
          raise 'ray texture atlas overflow' if y + height > ATLAS_SIZE
          height.times do |row|
            destination = ((y + row) * ATLAS_SIZE + x) * 4
            pixels[destination, width * 4] = rgba.byteslice(row * width * 4, width * 4)
          end
          rectangles[name] = [x.to_f / ATLAS_SIZE, y.to_f / ATLAS_SIZE, width.to_f / ATLAS_SIZE,
                              height.to_f / ATLAS_SIZE, width.to_f, height.to_f]
          x += width
          row_height = [row_height, height].max
        end
        [pixels, rectangles]
      end

      def material_source(name)
        source = @flats[name] || @textures[name]
        return unless source
        width = source.width
        height = source.height
        indices = if source.respond_to?(:column_pixels)
                    pixels = Array.new(width * height, 0)
                    width.times do |column|
                      source.column_pixels(column).each_with_index do |value, row|
                        pixels[row * width + column] = value || 0 if row < height
                      end
                    end
                    pixels
                  else
                    source.pixels
                  end
        [width, height, indices.map { |index| [*@palette.colors[index], 255].pack('C4') }.join]
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

      def uniform1i(name, value) = glUniform1i(glGetUniformLocation(@ray_program, name), value)
      def uniform1f(name, value) = glUniform1f(glGetUniformLocation(@ray_program, name), value.to_f)
      def uniform3f(name, x, y, z) = glUniform3f(glGetUniformLocation(@ray_program, name), x.to_f, y.to_f, z.to_f)

      def uniform4fv(name, count, values)
        glUniform4fv(glGetUniformLocation(@ray_program, name), count, values.pack('f*'))
      end
    end
  end
end
