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

require 'chunky_png'

module Doom
  class Error < StandardError; end
end

wad = Doom::Wad::Reader.new('doom1.wad')
puts "WAD: #{wad.num_lumps} lumps"

palette = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites = Doom::Wad::SpriteManager.new(wad)
map = Doom::Map::MapData.load(wad, 'E1M1')

puts "Player start: #{map.player_start.x}, #{map.player_start.y}, angle #{map.player_start.angle}"
puts "Things in map: #{map.things.size}"

renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)
renderer.set_player(map.player_start.x, map.player_start.y, 41, map.player_start.angle)

puts "Rendering frame..."
renderer.render_frame

puts "Framebuffer stats:"
puts "  Size: #{renderer.framebuffer.size}"
puts "  Non-zero pixels: #{renderer.framebuffer.count { |p| p != 0 }}"
puts "  Unique colors: #{renderer.framebuffer.uniq.size}"

# Export to PNG
img = ChunkyPNG::Image.new(320, 200)
renderer.framebuffer.each_with_index do |color_idx, i|
  x = i % 320
  y = i / 320
  r, g, b = palette[color_idx]
  img[x, y] = ChunkyPNG::Color.rgb(r, g, b)
end
img.save('test_render.png')
puts "Saved to test_render.png"
