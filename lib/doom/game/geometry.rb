# frozen_string_literal: true

module Doom
  module Game
    # Shared 2D geometry for the simulation. These three helpers were copy-pasted
    # across combat, monster AI, player physics, world and sector actions (the
    # last under the name point_line_dist); consolidated here so line-of-sight,
    # collision and use-line checks share one definition.
    #
    # Pure functions of their arguments -- no state, no RNG, no wall clock -- so
    # they stay deterministic and every peer computes the same result.
    module Geometry
      module_function

      # Do the open segments A (ax1,ay1)->(ax2,ay2) and B (bx1,by1)->(bx2,by2)
      # cross? Used for line-of-sight and hitscan against walls. Parallel or
      # barely-crossing segments (tiny determinant) count as no intersection.
      def segments_intersect?(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
        d1x = ax2 - ax1
        d1y = ay2 - ay1
        d2x = bx2 - bx1
        d2y = by2 - by1
        denom = d1x * d2y - d1y * d2x
        return false if denom.abs < 0.001

        dx = bx1 - ax1
        dy = by1 - ay1
        t = (dx * d2y - dy * d2x).to_f / denom
        u = (dx * d1y - dy * d1x).to_f / denom
        t > 0.0 && t < 1.0 && u >= 0.0 && u <= 1.0
      end

      # Does the segment (x1,y1)->(x2,y2) pass within `radius` of the circle
      # centred at (cx,cy)? The collision test for a body of that radius sliding
      # against a wall.
      def line_circle_intersect?(x1, y1, x2, y2, cx, cy, radius)
        dx = cx - x1
        dy = cy - y1
        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = (line_dx * line_dx) + (line_dy * line_dy)
        return false if line_len_sq.zero?

        t = (((dx * line_dx) + (dy * line_dy)).to_f / line_len_sq).clamp(0.0, 1.0)
        closest_x = x1 + (t * line_dx)
        closest_y = y1 + (t * line_dy)
        dist_sq = ((cx - closest_x)**2) + ((cy - closest_y)**2)
        dist_sq < radius * radius
      end

      # Shortest distance from point (px,py) to the segment (x1,y1)->(x2,y2),
      # clamped to the segment ends. Used for use-line and trigger proximity.
      def point_to_segment_distance(px, py, x1, y1, x2, y2)
        dx = px - x1
        dy = py - y1
        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = (line_dx * line_dx) + (line_dy * line_dy)
        return Math.sqrt((dx * dx) + (dy * dy)) if line_len_sq.zero?

        t = (((dx * line_dx) + (dy * line_dy)).to_f / line_len_sq).clamp(0.0, 1.0)
        closest_x = x1 + (t * line_dx)
        closest_y = y1 + (t * line_dy)
        Math.sqrt(((px - closest_x)**2) + ((py - closest_y)**2))
      end
    end
  end
end
