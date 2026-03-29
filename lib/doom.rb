# frozen_string_literal: true

require_relative 'doom/version'
require_relative 'doom/wad_downloader'
require_relative 'doom/wad/reader'
require_relative 'doom/wad/palette'
require_relative 'doom/wad/colormap'
require_relative 'doom/wad/flat'
require_relative 'doom/wad/patch'
require_relative 'doom/wad/texture'
require_relative 'doom/wad/sprite'
require_relative 'doom/wad/hud_graphics'
require_relative 'doom/map/data'
require_relative 'doom/game/player_state'
require_relative 'doom/game/sector_actions'
require_relative 'doom/game/animations'
require_relative 'doom/game/item_pickup'
require_relative 'doom/game/combat'
require_relative 'doom/game/sector_effects'
require_relative 'doom/game/monster_ai'
require_relative 'doom/game/menu'
require_relative 'doom/wad/sound'
require_relative 'doom/game/sound_engine'
require_relative 'doom/render/font'
require_relative 'doom/render/renderer'
require_relative 'doom/render/status_bar'
require_relative 'doom/render/weapon_renderer'
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

      puts 'Loading HUD graphics...'
      hud_graphics = Wad::HudGraphics.new(wad)

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

      puts 'Initializing animations...'
      flat_names = flats.map(&:name)
      animations = Game::Animations.new(textures.texture_names, flat_names)

      puts 'Creating renderer...'
      renderer = Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites, animations)
      renderer.set_player(player_start.x, player_start.y, 41, player_start.angle)

      puts 'Setting up player state and HUD...'
      player_state = Game::PlayerState.new
      status_bar = Render::StatusBar.new(hud_graphics, player_state)
      weapon_renderer = Render::WeaponRenderer.new(hud_graphics, player_state)
      sector_actions = Game::SectorActions.new(map)
      sector_effects = Game::SectorEffects.new(map)
      item_pickup = Game::ItemPickup.new(map, player_state)
      sound_mgr = Wad::SoundManager.new(wad)
      sound_engine = Game::SoundEngine.new(sound_mgr)
      combat = Game::Combat.new(map, player_state, sprites, {}, sound_engine)
      monster_ai = Game::MonsterAI.new(map, combat, player_state, sprites, {}, sound_engine)
      doom_font = Render::Font.new(wad, hud_graphics)
      menu = Game::Menu.new(wad, hud_graphics, doom_font)

      puts 'Starting game window...'
      window = Platform::GosuWindow.new(renderer, palette, map, player_state, status_bar, weapon_renderer, sector_actions, animations, sector_effects, item_pickup, combat, monster_ai, menu, sound_engine)
      window.show
    end
  end
end
