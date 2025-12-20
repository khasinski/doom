#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/doom/wad/reader'
require_relative 'lib/doom/wad/palette'
require_relative 'lib/doom/wad/colormap'
require_relative 'lib/doom/wad/flat'
require_relative 'lib/doom/wad/patch'
require_relative 'lib/doom/wad/texture'
require_relative 'lib/doom/map/data'

module Doom
  class Error < StandardError; end
end

wad = Doom::Wad::Reader.new('doom1.wad')
map = Doom::Map::MapData.load(wad, 'E1M1')

player = map.player_start
px, py = player.x.to_f, player.y.to_f
angle = player.angle * Math::PI / 180.0

puts "Player: (#{px}, #{py}) angle #{player.angle}"
puts "Nodes: #{map.nodes.size}"
puts "Subsectors: #{map.subsectors.size}"
puts "Segs: #{map.segs.size}"

# Test BSP traversal
visited_subsectors = []
visited_segs = []

def point_on_side(x, y, node)
  dx = x - node.x
  dy = y - node.y
  left = dy * node.dx
  right = dx * node.dy
  right >= left ? 0 : 1
end

def traverse(map, node_index, px, py, visited_subsectors, visited_segs)
  if node_index & Doom::Map::Node::SUBSECTOR_FLAG != 0
    ss_idx = node_index & ~Doom::Map::Node::SUBSECTOR_FLAG
    visited_subsectors << ss_idx
    ss = map.subsectors[ss_idx]
    ss.seg_count.times do |i|
      visited_segs << (ss.first_seg + i)
    end
    return
  end

  node = map.nodes[node_index]
  side = point_on_side(px, py, node)

  if side == 0
    traverse(map, node.child_right, px, py, visited_subsectors, visited_segs)
    traverse(map, node.child_left, px, py, visited_subsectors, visited_segs)
  else
    traverse(map, node.child_left, px, py, visited_subsectors, visited_segs)
    traverse(map, node.child_right, px, py, visited_subsectors, visited_segs)
  end
end

traverse(map, map.nodes.size - 1, px, py, visited_subsectors, visited_segs)

puts "Visited subsectors: #{visited_subsectors.size}/#{map.subsectors.size}"
puts "Visited segs: #{visited_segs.size}/#{map.segs.size}"

# Check first few segs
puts "\nFirst 5 segs:"
visited_segs.first(5).each do |seg_idx|
  seg = map.segs[seg_idx]
  v1 = map.vertices[seg.v1]
  v2 = map.vertices[seg.v2]

  # Transform
  sin_a = Math.sin(angle)
  cos_a = Math.cos(angle)

  x1 = v1.x - px
  y1 = v1.y - py
  x2 = v2.x - px
  y2 = v2.y - py

  tx1 = x1 * cos_a + y1 * sin_a
  ty1 = -x1 * sin_a + y1 * cos_a
  tx2 = x2 * cos_a + y2 * sin_a
  ty2 = -x2 * sin_a + y2 * cos_a

  puts "  Seg #{seg_idx}: v1(#{v1.x},#{v1.y}) v2(#{v2.x},#{v2.y})"
  puts "    Transformed: (#{tx1.round(1)},#{ty1.round(1)}) -> (#{tx2.round(1)},#{ty2.round(1)})"
  puts "    Behind player: #{ty1 <= 0 && ty2 <= 0}"
end
