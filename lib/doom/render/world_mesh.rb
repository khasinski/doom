# frozen_string_literal: true

module Doom
  module Render
    # Converts Doom's sector/subsector representation into ordinary triangles.
    # Subsector polygons are convex by construction, so a fan is sufficient.
    class WorldMesh
      Triangle = Struct.new(:vertices, :uvs, :normal, :light, :material)

      attr_reader :triangles

      def initialize(map)
        @map = map
        @triangles = []
        build_planes
        build_walls
      end

      private

      def build_planes
        bsp_leaf_polygons.each do |subsector_index, points|
          subsector = @map.subsectors[subsector_index]
          segs = @map.segs[subsector.first_seg, subsector.seg_count]
          next if segs.nil? || segs.empty?

          # BSP leaves partition the entire map bounding box, including solid
          # void behind one-sided walls. Segs are directed with their front
          # sector on the right; clipping by each one trims the leaf to the
          # actual playable subsector surface.
          points = clip_to_segs(points, segs)

          sector = segs.lazy.map { |seg| sector_for_seg(seg) }.find(&:itself)
          next unless sector

          next if points.size < 3

          (1...(points.size - 1)).each do |i|
            add_triangle(points[0], points[i], points[i + 1], sector.floor_height,
                         [0.0, 0.0, 1.0], sector.light_level, sector.floor_texture)
            unless sector.ceiling_texture == 'F_SKY1'
              add_triangle(points[0], points[i + 1], points[i], sector.ceiling_height,
                           [0.0, 0.0, -1.0], sector.light_level, sector.ceiling_texture)
            end
          end
        end
      end

      def clip_to_segs(points, segs)
        segs.reduce(points) do |polygon, seg|
          break [] if polygon.size < 3

          a = @map.vertices[seg.v1]
          b = @map.vertices[seg.v2]
          dx = b.x - a.x
          dy = b.y - a.y
          clip_by_values(polygon) { |point| (point.x - a.x) * dy - (point.y - a.y) * dx }
        end
      end

      def clip_by_values(polygon)
        output = []
        polygon.each_with_index do |current, index|
          previous = polygon[index - 1]
          current_value = yield(current)
          previous_value = yield(previous)
          current_inside = current_value >= -1e-7
          previous_inside = previous_value >= -1e-7
          if current_inside != previous_inside
            t = previous_value / (previous_value - current_value).to_f
            output << Map::Vertex.new(
              previous.x + (current.x - previous.x) * t,
              previous.y + (current.y - previous.y) * t
            )
          end
          output << current if current_inside
        end
        output
      end

      # Reconstruct exact convex subsector cells by carrying the map bounding
      # polygon through the BSP and clipping it at every partition. Seg
      # endpoints alone do not contain the artificial BSP split edges.
      def bsp_leaf_polygons
        xs = @map.vertices.map(&:x)
        ys = @map.vertices.map(&:y)
        padding = 1.0
        root_polygon = [
          [xs.min - padding, ys.min - padding],
          [xs.max + padding, ys.min - padding],
          [xs.max + padding, ys.max + padding],
          [xs.min - padding, ys.max + padding],
        ]
        leaves = {}
        visit_bsp(@map.nodes.size - 1, root_polygon, leaves)
        leaves
      end

      def visit_bsp(index, polygon, leaves)
        return if polygon.size < 3

        if (index & Map::Node::SUBSECTOR_FLAG) != 0
          leaves[index & ~Map::Node::SUBSECTOR_FLAG] = polygon.map { |x, y| Map::Vertex.new(x, y) }
          return
        end

        node = @map.nodes[index]
        visit_bsp(node.child_right, clip_polygon(polygon, node, true), leaves)
        visit_bsp(node.child_left, clip_polygon(polygon, node, false), leaves)
      end

      def clip_polygon(polygon, node, keep_right)
        output = []
        polygon.each_with_index do |current, index|
          previous = polygon[index - 1]
          current_side = partition_value(current, node)
          previous_side = partition_value(previous, node)
          current_inside = keep_right ? current_side >= -1e-7 : current_side <= 1e-7
          previous_inside = keep_right ? previous_side >= -1e-7 : previous_side <= 1e-7

          if current_inside != previous_inside
            t = previous_side / (previous_side - current_side).to_f
            output << [previous[0] + (current[0] - previous[0]) * t,
                       previous[1] + (current[1] - previous[1]) * t]
          end
          output << current if current_inside
        end
        output
      end

      def partition_value(point, node)
        (point[0] - node.x) * node.dy - (point[1] - node.y) * node.dx
      end

      def build_walls
        @map.linedefs.each do |line|
          right = sidedef(line.sidedef_right)
          left = sidedef(line.sidedef_left)
          next unless right || left

          front = right && @map.sectors[right.sector]
          back = left && @map.sectors[left.sector]
          a = @map.vertices[line.v1]
          b = @map.vertices[line.v2]

          if front && back
            # Doom's sky hack: adjacent sky ceilings are one continuous
            # infinite sky even when their numeric heights differ. Emitting an
            # upper wall here creates the conspicuous tower at outdoor edges.
            both_sky = front.ceiling_texture == 'F_SKY1' && back.ceiling_texture == 'F_SKY1'
            if !both_sky && front.ceiling_height > back.ceiling_height
              v_top = right.y_offset
              v_top += back.ceiling_height - front.ceiling_height unless line.upper_unpegged?
              wall_quad(a, b, back.ceiling_height, front.ceiling_height,
                        front.light_level, right.upper_texture,
                        u_offset: right.x_offset, v_top: v_top)
            elsif !both_sky && back.ceiling_height > front.ceiling_height
              v_top = left.y_offset
              v_top += front.ceiling_height - back.ceiling_height unless line.upper_unpegged?
              wall_quad(a, b, front.ceiling_height, back.ceiling_height,
                        back.light_level, left.upper_texture, flip: true,
                        u_offset: left.x_offset, v_top: v_top)
            end
            if back.floor_height > front.floor_height
              v_top = right.y_offset
              v_top += front.ceiling_height - back.floor_height if line.lower_unpegged?
              wall_quad(a, b, front.floor_height, back.floor_height,
                        front.light_level, right.lower_texture,
                        u_offset: right.x_offset, v_top: v_top)
            elsif front.floor_height > back.floor_height
              v_top = left.y_offset
              v_top += back.ceiling_height - front.floor_height if line.lower_unpegged?
              wall_quad(a, b, back.floor_height, front.floor_height,
                        back.light_level, left.lower_texture, flip: true,
                        u_offset: left.x_offset, v_top: v_top)
            end
          else
            sector = front || back
            side = right || left
            v_top = side.y_offset
            v_top -= sector.ceiling_height - sector.floor_height if line.lower_unpegged?
            wall_quad(a, b, sector.floor_height, sector.ceiling_height,
                      sector.light_level, side.middle_texture, flip: !right,
                      u_offset: side.x_offset, v_top: v_top)
          end
        end
      end

      def wall_quad(a, b, bottom, top, light, material, flip: false, u_offset: 0, v_top: 0)
        return unless top > bottom

        a, b = b, a if flip

        dx = b.x - a.x
        dy = b.y - a.y
        length = Math.hypot(dx, dy)
        return if length.zero?

        normal = [dy / length, -dx / length, 0.0]
        v0 = [a.x.to_f, a.y.to_f, bottom.to_f]
        v1 = [b.x.to_f, b.y.to_f, bottom.to_f]
        v2 = [b.x.to_f, b.y.to_f, top.to_f]
        v3 = [a.x.to_f, a.y.to_f, top.to_f]
        # UVs remain in Doom world/texel units. The GPU renderer normalizes
        # them by the actual material dimensions (not every wall is 64 px).
        u0 = u_offset.to_f
        u1 = u0 + length
        v0_tex = v_top.to_f + (top - bottom)
        v1_tex = v_top.to_f
        @triangles << Triangle.new([v0, v1, v2], [[u0, v0_tex], [u1, v0_tex], [u1, v1_tex]], normal, light, material)
        @triangles << Triangle.new([v0, v2, v3], [[u0, v0_tex], [u1, v1_tex], [u0, v1_tex]], normal, light, material)
      end

      def add_triangle(a, b, c, z, normal, light, material)
        area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        return if area.abs < 1e-6

        vertices = [a, b, c].map { |point| [point.x.to_f, point.y.to_f, z.to_f] }
        uvs = [a, b, c].map { |point| [point.x.to_f, -point.y.to_f] }
        @triangles << Triangle.new(vertices, uvs, normal, light, material)
      end

      def sector_for_seg(seg)
        line = @map.linedefs[seg.linedef]
        index = seg.direction.zero? ? line.sidedef_right : line.sidedef_left
        side = sidedef(index)
        side && @map.sectors[side.sector]
      end

      def sidedef(index)
        return nil unless index && index >= 0 && index < @map.sidedefs.size

        @map.sidedefs[index]
      end
    end
  end
end
