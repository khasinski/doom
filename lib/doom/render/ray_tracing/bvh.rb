# frozen_string_literal: true

module Doom
  module Render
    module RayTracing
      # Stackless, pre-order bounding volume hierarchy for GPU traversal.
      # Internal nodes point at their children and every node stores an escape
      # index, allowing GLSL 1.20 to traverse without a dynamic stack.
      class Bvh
        Node = Struct.new(:minimum, :maximum, :start, :count, :escape, :left, :right,
                          keyword_init: true) do
          def leaf?
            start >= 0
          end
        end

        attr_reader :nodes, :triangles, :triangle_order, :leaf_size

        def initialize(source_triangles, leaf_size: 8)
          @leaf_size = leaf_size
          @nodes = []
          @triangles = []
          @triangle_order = []
          build(source_triangles.each_with_index.to_a)
        end

        def compatible?(source_triangles)
          @triangle_order.size == source_triangles.size
        end

        # Door/lift motion changes vertices but not triangle identity. Refit
        # bounds bottom-up while preserving the GPU-friendly leaf ordering.
        def refit(source_triangles)
          raise ArgumentError, 'triangle topology changed' unless compatible?(source_triangles)

          @triangles = @triangle_order.map { |index| source_triangles[index] }
          (@nodes.size - 1).downto(0) do |index|
            node = @nodes[index]
            if node.leaf?
              node.minimum, node.maximum = bounds(@triangles[node.start, node.count])
            else
              left = @nodes[node.left]
              right = @nodes[node.right]
              node.minimum = axes { |axis| [left.minimum[axis], right.minimum[axis]].min }
              node.maximum = axes { |axis| [left.maximum[axis], right.maximum[axis]].max }
            end
          end
          self
        end

        # Three RGBA texels per node: min/escape, max/start, count/padding.
        def packed_floats
          @nodes.flat_map do |node|
            [*node.minimum, node.escape.to_f,
             *node.maximum, node.start.to_f,
             node.count.to_f, 0.0, 0.0, 0.0]
          end
        end

        private

        def build(entries)
          node_index = @nodes.size
          @nodes << nil
          triangles = entries.map(&:first)
          minimum, maximum = bounds(triangles)
          if entries.size <= @leaf_size
            start = @triangles.size
            @triangles.concat(triangles)
            @triangle_order.concat(entries.map(&:last))
            @nodes[node_index] = Node.new(minimum: minimum, maximum: maximum,
                                          start: start, count: entries.size,
                                          escape: node_index + 1)
            return node_index
          end

          centers = triangles.map { |triangle| axes { |axis| triangle.vertices.sum { |v| v[axis] } / 3.0 } }
          extents = axes { |axis| centers.map { |center| center[axis] }.minmax.then { |a, b| b - a } }
          split_axis = extents.each_with_index.max_by(&:first).last
          sorted = entries.zip(centers).sort_by { |_entry, center| center[split_axis] }.map(&:first)
          middle = sorted.size / 2
          left = build(sorted[0...middle])
          right = build(sorted[middle..])
          @nodes[node_index] = Node.new(minimum: minimum, maximum: maximum,
                                        start: -1, count: 0, escape: @nodes.size,
                                        left: left, right: right)
          node_index
        end

        def bounds(triangles)
          points = triangles.flat_map(&:vertices)
          minimum = axes { |axis| points.min_by { |point| point[axis] }[axis] - 0.01 }
          maximum = axes { |axis| points.max_by { |point| point[axis] }[axis] + 0.01 }
          [minimum, maximum]
        end

        def axes(&block)
          3.times.map(&block)
        end
      end
    end
  end
end
