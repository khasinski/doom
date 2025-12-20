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

# Test positions that reveal floor/ceiling issues
TEST_POSITIONS = [
  { name: 'spawn', x: 1056, y: -3616, angle: 90 },
  { name: 'hallway', x: 1056, y: -3200, angle: 90 },
  { name: 'looking_down_hall', x: 1056, y: -3400, angle: 0 },
  { name: 'corner', x: 1200, y: -3616, angle: 180 },
  { name: 'near_pillar', x: 1088, y: -3488, angle: 45 },
  { name: 'stairs_area', x: 1472, y: -3072, angle: 90 },
]

wad = Doom::Wad::Reader.new('doom1.wad')
palette = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites = Doom::Wad::SpriteManager.new(wad)
map = Doom::Map::MapData.load(wad, 'E1M1')

renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)

Dir.mkdir('debug_frames') unless Dir.exist?('debug_frames')

TEST_POSITIONS.each do |pos|
  puts "Rendering #{pos[:name]}..."
  renderer.set_player(pos[:x], pos[:y], 41, pos[:angle])
  renderer.render_frame

  img = ChunkyPNG::Image.new(320, 200)
  renderer.framebuffer.each_with_index do |color_idx, i|
    x = i % 320
    y = i / 320
    r, g, b = palette[color_idx]
    img[x, y] = ChunkyPNG::Color.rgb(r, g, b)
  end
  img.save("debug_frames/#{pos[:name]}.png")
end

puts "Done! Check debug_frames/ folder"
