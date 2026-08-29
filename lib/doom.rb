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
require_relative 'doom/game/random'
require_relative 'doom/game/state_hash'
require_relative 'doom/game/player_state'
require_relative 'doom/game/player'
require_relative 'doom/game/ticcmd'
require_relative 'doom/game/player_physics'
require_relative 'doom/game/sector_actions'
require_relative 'doom/game/animations'
require_relative 'doom/game/item_pickup'
require_relative 'doom/game/combat'
require_relative 'doom/game/sector_effects'
require_relative 'doom/game/monster_ai'
require_relative 'doom/game/world'
require_relative 'doom/game/snapshot'
require_relative 'doom/net/protocol'
require_relative 'doom/net/transport'
require_relative 'doom/net/desync_monitor'
require_relative 'doom/net/lockstep'
require_relative 'doom/net/session'
require_relative 'doom/net/game_server'
require_relative 'doom/net/client'
require_relative 'doom/game/menu'
require_relative 'doom/game/intermission'
require_relative 'doom/wad/sound'
require_relative 'doom/game/sound_engine'
require_relative 'doom/render/font'
require_relative 'doom/render/renderer'
require_relative 'doom/render/screen_melt'
require_relative 'doom/render/status_bar'
require_relative 'doom/render/weapon_renderer'
require_relative 'doom/platform/gosu_window'

module Doom
  class Error < StandardError; end

  class << self
    def run(wad_path, map_name: 'E1M1', rubykaigi: false, net: nil, frag_limit: nil)
      session = build_session(net, map_name)
      if session
        # The host decides the map, seed and mode; a client is told them. Wait
        # for that before loading anything, so both sides load the same level.
        map_name = wait_for_session(session) || map_name
      end

      puts "Loading WAD: #{wad_path}"
      wad = Wad::Reader.new(wad_path)
      puts "  #{wad.type}: #{wad.num_lumps} lumps"

      # If it's a PWAD, we need a base IWAD for resources (palette, textures, etc.)
      if wad.pwad?
        iwad_path = find_iwad
        raise Error, "PWAD requires a base IWAD (doom1.wad). Place it in the current directory or ~/.doom/" unless iwad_path
        puts "  PWAD detected, loading base IWAD: #{iwad_path}"
        base_wad = Wad::Reader.new(iwad_path)
        base_wad.merge_pwad(wad)
        wad = base_wad

        # Auto-detect map name from PWAD lumps
        pwad_map = wad.directory.find { |e| e.name =~ /^(E\dM\d|MAP\d\d)$/ }
        map_name = pwad_map.name if pwad_map
        puts "  Using map: #{map_name}"
      end

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
      # No initial camera pose needed: the world owns the player, and draw aims
      # the camera at it every frame.
      renderer = Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites, animations)

      puts 'Building world...'
      sound_mgr = Wad::SoundManager.new(wad)
      sound_engine = Game::SoundEngine.new(sound_mgr)
      # One RNG shared by every subsystem that touches game state -- its index is
      # part of the simulation, so all peers must draw from the same sequence.
      # In a session the seed and mode come from the host, so every peer builds
      # the same world; solo play picks its own.
      random = Game::Random.new(session ? session.seed : 0)
      world = Game::World.new(map, sprites: sprites, sound: sound_engine, random: random,
                                   mode: session ? session.mode : :coop,
                                   frag_limit: frag_limit)
      ids = session ? session.player_ids : [0]
      ids.each { |id| world.add_player(id: id) }
      player = world.player(session ? session.local_id : 0)
      player_state = player.state

      puts 'Setting up HUD...'
      status_bar = Render::StatusBar.new(hud_graphics, player_state)
      weapon_renderer = Render::WeaponRenderer.new(hud_graphics, player_state)
      doom_font = Render::Font.new(wad, hud_graphics)
      menu = Game::Menu.new(wad, hud_graphics, doom_font)

      # RubyKaigi mode: god mode, no aggression, benchmark HUD
      if rubykaigi
        menu.options[:rubykaigi_mode] = true
        menu.options[:god_mode] = true
      end

      puts 'Starting game window...'
      window = Platform::GosuWindow.new(renderer, palette, world, status_bar, weapon_renderer,
                                        animations, menu, sound_engine, session: session)
      # A networked game skips the title screen: the other players are already
      # waiting, and there is nothing to configure that the host has not set.
      menu.instance_variable_set(:@state, Game::Menu::STATE_NONE) if session
      window.show
    ensure
      session&.quit
    end

    private

    def build_session(net, map_name)
      return nil unless net

      case net[:role]
      when :host
        puts "Hosting on port #{net[:port]}, waiting for #{net[:players]} players..."
        Net::Session.host(port: net[:port], players: net[:players],
                          map: map_name, mode: net[:mode])
      when :client
        puts "Connecting to #{net[:host]}:#{net[:port]}..."
        Net::Session.connect(host: net[:host], port: net[:port])
      end
    end

    # Block until the handshake finishes. This is the one place blocking is
    # right: there is no game to render yet.
    def wait_for_session(session, timeout: 120)
      deadline = Time.now + timeout
      until session.started?
        raise Error, 'timed out waiting for the other players' if Time.now > deadline

        session.poll
        sleep 0.02
      end

      puts "  Joined as player #{session.local_id} of #{session.num_players} " \
           "(#{session.mode}, map #{session.map_name})"
      session.map_name
    end

    def find_iwad
      candidates = [
        File.join(Dir.pwd, 'doom1.wad'),
        File.join(Dir.pwd, 'doom.wad'),
        File.join(Dir.home, '.doom', 'doom1.wad'),
      ]
      candidates.find { |p| File.exist?(p) }
    end
  end
end
