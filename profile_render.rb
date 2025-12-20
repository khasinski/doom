#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/doom/version'
require_relative 'lib/doom/wad/reader'
require_relative 'lib/doom/wad/palette'
require_relative 'lib/doom/wad/colormap'
require_relative 'lib/doom/wad/flat'
require_relative 'lib/doom/wad/patch'
require_relative 'lib/doom/wad/texture'
require_relative 'lib/doom/wad/sprite'
require_relative 'lib/doom/map/data'
require_relative 'lib/doom/render/renderer'

module Doom
  class Error < StandardError; end
end

wad = Doom::Wad::Reader.new('doom1.wad')
palette = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites = Doom::Wad::SpriteManager.new(wad)
map = Doom::Map::MapData.load(wad, 'E1M1')

renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)
renderer.set_player(1056, -3616, 41, 90)

# Warm up
3.times { renderer.render_frame }

# Profile
require 'benchmark'

puts "Profiling 10 frames..."
times = []
10.times do
  t = Benchmark.realtime { renderer.render_frame }
  times << t
end

avg = times.sum / times.size
fps = 1.0 / avg

puts "Average frame time: #{(avg * 1000).round(2)}ms"
puts "Estimated FPS: #{fps.round(1)}"
puts "Min: #{(times.min * 1000).round(2)}ms, Max: #{(times.max * 1000).round(2)}ms"

# Profile individual components
puts "\nProfiling components..."

# Measure floor/ceiling background
t_floor_ceil = Benchmark.realtime do
  10.times do
    renderer.send(:clear_framebuffer)
    renderer.send(:draw_floor_ceiling_background)
  end
end / 10

# Measure BSP traversal + walls
renderer.send(:clear_framebuffer)
renderer.send(:reset_clipping)
t_bsp = Benchmark.realtime do
  10.times do
    renderer.send(:clear_framebuffer)
    renderer.send(:reset_clipping)
    renderer.instance_variable_set(:@sin_angle, Math.sin(renderer.instance_variable_get(:@player_angle)))
    renderer.instance_variable_set(:@cos_angle, Math.cos(renderer.instance_variable_get(:@player_angle)))
    renderer.send(:render_bsp_node, map.nodes.size - 1)
  end
end / 10

puts "Floor/ceiling background: #{(t_floor_ceil * 1000).round(2)}ms"
puts "BSP traversal + walls: #{(t_bsp * 1000).round(2)}ms"
