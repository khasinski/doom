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
palette = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites = Doom::Wad::SpriteManager.new(wad)
map = Doom::Map::MapData.load(wad, 'E1M1')

renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)

# Position where barrels should be visible
positions = [
  { name: 'spawn', x: 1056, y: -3616, angle: 90 },
  { name: 'near_barrel', x: 1056, y: -3400, angle: 90 },
  { name: 'different_sector', x: 1200, y: -3200, angle: 180 },
]

Dir.mkdir('debug_frames') unless Dir.exist?('debug_frames')

positions.each do |pos|
  puts "Rendering #{pos[:name]}..."
  renderer.set_player(pos[:x], pos[:y], 41, pos[:angle])

  # Debug: check things in map
  puts "  Things in map: #{map.things.size}"
  barrel_things = map.things.select { |t| t.type == 2035 } # Barrel type
  puts "  Barrels: #{barrel_things.size}"

  if barrel_things.any?
    barrel = barrel_things.first
    puts "  First barrel at: (#{barrel.x}, #{barrel.y})"
    puts "  Sprite prefix: #{sprites.prefix_for(barrel.type).inspect}"

    # Check transform
    sin_a = Math.sin(pos[:angle] * Math::PI / 180.0)
    cos_a = Math.cos(pos[:angle] * Math::PI / 180.0)
    dx = barrel.x - pos[:x]
    dy = barrel.y - pos[:y]
    view_x = dx * sin_a - dy * cos_a
    view_y = dx * cos_a + dy * sin_a
    puts "  Barrel in view space: (#{view_x.round(2)}, #{view_y.round(2)})"

    # Check if sprite can be retrieved
    angle_to_thing = Math.atan2(dy, dx)
    sprite = sprites.get_rotated(barrel.type, angle_to_thing, barrel.angle)
    puts "  get_rotated result: #{sprite ? sprite.class : 'nil'}"
    # Check available sprites
    sprites_hash = sprites.instance_variable_get(:@sprites) || {}
    puts "  Available BAR sprites: #{sprites_hash.keys.grep(/BAR/).first(5) rescue 'error'}"
  end

  renderer.render_frame

  # Check wall_depth stats
  wall_depths = renderer.instance_variable_get(:@sprite_wall_depth)
  finite_depths = wall_depths.reject { |d| d == Float::INFINITY }

  puts "  Wall depth stats:"
  puts "    Columns with walls: #{finite_depths.size}"
  puts "    Min depth: #{finite_depths.min&.round(2)}"
  puts "    Max depth: #{finite_depths.max&.round(2)}"

  # Check visible sprites
  visible_sprites = renderer.instance_variable_get(:@visible_sprites) || []
  puts "  Visible sprites: #{visible_sprites.size}"
  puts "  Sprite columns drawn: #{renderer.instance_variable_get(:@sprites_drawn)}"

  sprite_debug = renderer.instance_variable_get(:@sprite_debug) || []
  sprite_debug.first(3).each_with_index do |info, i|
    puts "    Sprite #{i}: dist=#{info[:dist].round(1)}, drawn=#{info[:columns_drawn]}, clipped=#{info[:columns_clipped]}, range=#{info[:sprite_left]}..#{info[:sprite_right]}"
  end

  img = ChunkyPNG::Image.new(320, 200)
  renderer.framebuffer.each_with_index do |color_idx, i|
    x = i % 320
    y = i / 320
    r, g, b = palette[color_idx]
    img[x, y] = ChunkyPNG::Color.rgb(r, g, b)
  end
  img.save("debug_frames/sprite_#{pos[:name]}.png")
end

puts "Done! Check debug_frames/ folder"
