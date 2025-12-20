# frozen_string_literal: true

require_relative 'doom/version'
require_relative 'doom/wad/reader'
require_relative 'doom/wad/palette'
require_relative 'doom/wad/colormap'
require_relative 'doom/wad/flat'
require_relative 'doom/wad/patch'
require_relative 'doom/wad/texture'
require_relative 'doom/wad/sprite'
require_relative 'doom/map/data'
require_relative 'doom/render/renderer'
require_relative 'doom/platform/gosu_window'

module Doom
  class Error < StandardError; end

  class << self
    def run(wad_path, map_name: 'E1M1')
      puts "Loading WAD: #{wad_path}"
      wad = Wad::Reader.new(wad_path)
      puts "  #{wad.type}: #{wad.num_lumps} lumps"

      puts 'Loading palette...'
      palette = Wad::Palette.load(wad)

      puts 'Loading colormap...'
      colormap = Wad::Colormap.load(wad)

      puts 'Loading flats...'
      flats = Wad::Flat.load_all(wad)
      puts "  #{flats.size} flats"

      puts 'Loading textures...'
      textures = Wad::TextureManager.new(wad)
      puts "  #{textures.textures.size} textures, #{textures.pnames.size} patches"

      puts 'Loading sprites...'
      sprites = Wad::SpriteManager.new(wad)

      puts "Loading map #{map_name}..."
      map = Map::MapData.load(wad, map_name)
      puts "  #{map.vertices.size} vertices, #{map.linedefs.size} linedefs"
      puts "  #{map.segs.size} segs, #{map.subsectors.size} subsectors, #{map.nodes.size} nodes"

      # Find player start
      player_start = map.player_start
      if player_start
        puts "  Player start: (#{player_start.x}, #{player_start.y}) angle #{player_start.angle}"
      else
        puts '  Warning: No player start found!'
        player_start = Map::Thing.new(0, 0, 90, 1, 0)
      end

      puts 'Creating renderer...'
      renderer = Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)
      renderer.set_player(player_start.x, player_start.y, 41, player_start.angle)

      puts 'Starting game window...'
      window = Platform::GosuWindow.new(renderer, palette)
      window.show
    end
  end
end
