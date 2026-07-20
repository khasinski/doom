# frozen_string_literal: true

require 'gosu'

module Doom
  module Platform
    class GosuWindow < Gosu::Window
      SCALE = 3

      # SDL2 keyboard grab via Gosu's bundled SDL -- prevents OS key interception
      module SDLKeyboardGrab
        def self.setup
          require "fiddle"
          gosu_spec = Gem.loaded_specs["gosu"]
          lib_ext = RbConfig::CONFIG["DLEXT"] || "so"
          bundle = File.join(gosu_spec.full_gem_path, "lib", "gosu.#{lib_ext}")
          @lib = Fiddle.dlopen(bundle)
          @shared_window = Fiddle::Function.new(
            @lib["_ZN4Gosu13shared_windowEv"], [], Fiddle::TYPE_VOIDP
          )
          @set_kb_grab = Fiddle::Function.new(
            @lib["SDL_SetWindowKeyboardGrab"],
            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOID
          )
          @ready = true
        rescue StandardError, LoadError => e
          warn "SDLKeyboardGrab.setup failed: #{e.class}: #{e.message}"
          @ready = false
        end

        def self.grab!
          return unless @ready
          @set_kb_grab.call(@shared_window.call, 1)
        end

        def self.release!
          return unless @ready
          @set_kb_grab.call(@shared_window.call, 0)
        end
      end

      # Ask SDL for the display's refresh rate.
      #
      # Timing our own buffer swaps cannot answer this: when the engine renders
      # slower than the display refreshes -- which is the normal case here --
      # the swap cadence measures our render time, not the monitor. SDL knows
      # the real number, and Gosu bundles SDL, so we read it directly the same
      # way SDLKeyboardGrab reaches for SDL_SetWindowKeyboardGrab.
      module SDLDisplayMode
        # SDL_DisplayMode { Uint32 format; int w; int h; int refresh_rate; void *driverdata; }
        REFRESH_RATE_OFFSET = 12
        STRUCT_SIZE = 32

        def self.refresh_rate
          require 'fiddle'
          gosu_spec = Gem.loaded_specs['gosu']
          lib_ext = RbConfig::CONFIG['DLEXT'] || 'so'
          lib = Fiddle.dlopen(File.join(gosu_spec.full_gem_path, "lib", "gosu.#{lib_ext}"))

          get_mode = Fiddle::Function.new(
            lib['SDL_GetCurrentDisplayMode'],
            [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT
          )

          buf = Fiddle::Pointer.malloc(STRUCT_SIZE)
          return nil unless get_mode.call(0, buf).zero?

          hz = buf[REFRESH_RATE_OFFSET, 4].unpack1('l')
          # SDL reports 0 when the rate is unspecified (some virtual displays).
          hz.positive? ? hz : nil
        rescue StandardError, LoadError => e
          warn "SDLDisplayMode.refresh_rate failed: #{e.class}: #{e.message}"
          nil
        end
      end

      # Movement now lives in Game::PlayerPhysics and runs per tic, so the old
      # continuous-time thrust/friction constants moved there with it.
      TURN_SPEED = 3.0       # Degrees per tic
      TIC_SECONDS = 1.0 / 35.0

      # Frame generation is decoupled from presentation. Gosu's main loop is
      # limited by the buffer swap, which blocks on vblank -- so drawing every
      # iteration pins the whole engine to the monitor's refresh rate. Instead
      # we render every iteration (in update) but only ask Gosu to present when
      # a refresh interval has elapsed; needs_redraw? => false skips both the
      # blit and the swap, letting the loop spin freely in between.
      #
      # Gosu 1.4 exposes no refresh-rate API, so we ask SDL (see
      # SDLDisplayMode) and fall back to 60 Hz if it will not say.
      DEFAULT_REFRESH_HZ = 60.0
      PRESENT_INTERVAL_SLACK = 0.85  # Aim slightly early so we don't miss a vblank
      MOUSE_SENSITIVITY = 0.15  # Mouse look sensitivity

      USE_DISTANCE = 64.0  # Max distance to use a linedef

      # The simulation now lives in Game::World; this class is input and
      # output only. The world's subsystems are cached in ivars because the
      # automap, debug overlay and HUD read them constantly -- bind_world keeps
      # those caches honest whenever the world is rebuilt.
      def initialize(renderer, palette, world, status_bar = nil, weapon_renderer = nil,
                     animations = nil, menu = nil, sound_engine = nil)
        fullscreen = ARGV.include?('--fullscreen') || ARGV.include?('-f')
        super(Render::SCREEN_WIDTH * SCALE, Render::SCREEN_HEIGHT * SCALE, fullscreen)
        self.caption = 'Doom Ruby'
        self.update_interval = 0  # Uncap framerate (default 16.67ms = 60 FPS cap)
        SDLKeyboardGrab.setup

        @renderer = renderer
        @palette = palette
        @status_bar = status_bar
        @weapon_renderer = weapon_renderer
        @animations = animations
        @menu = menu
        @doom_font = menu&.font
        @sound = sound_engine
        @skill = Game::Menu::SKILL_MEDIUM

        bind_world(world)
        @pending_turn = 0.0  # Mouse turn accumulated between tics
        @tic_accumulator = 0.0
        @screen_image = nil
        @mouse_captured = false
        @last_mouse_x = nil
        @last_update_time = Time.now
        @use_pressed = false
        @show_debug = false
        @show_map = false
        @screen_melt = nil
        @intermission = nil
        @current_map = 'E1M1'
        @debug_font = Gosu::Font.new(24)
        @fps_frames = 0
        @fps_time = Time.now
        @fps_display = 0.0

        # Uncapped frame generation. Presented frames are counted separately so
        # the overlay can show both the render rate and what the display got.
        @uncapped_fps = !ARGV.include?('--vsync')
        menu.options[:uncapped_fps] = @uncapped_fps if menu
        @present_frames = 0
        @present_fps_display = 0.0
        @last_present_ms = 0
        @refresh_hz = (SDLDisplayMode.refresh_rate || DEFAULT_REFRESH_HZ).to_f
        @present_interval_ms = 1000.0 / @refresh_hz

        # Precompute sector colors for automap
        @sector_colors = build_sector_colors

        # Pre-build palette RGBA lookups for all 14 palettes (0=normal, 1-8=pain red)
        @all_palette_rgba = []
        wad = renderer.wad
        14.times do |pal_idx|
          pal = Wad::Palette.load(wad, pal_idx)
          @all_palette_rgba << pal.colors.map { |r, g, b| [r, g, b, 255].pack('CCCC') }
        end
        @palette_rgba = @all_palette_rgba[0]
      end

      # Point this window at a world, refreshing every cached reference. Called
      # on construction and whenever the world is rebuilt (new map, respawn).
      def bind_world(world)
        @world = world
        @map = world.map
        @random = world.random
        @player = world.player(0) || world.add_player(world.map.player_start || Map::Thing.new(0, 0, 90, 1, 0))
        @player_state = @player.state
        @physics = world.physics_for(@player)
        @combat = world.combat
        @monster_ai = world.monster_ai
        @item_pickup = world.item_pickup
        @sector_actions = world.sector_actions
        @sector_effects = world.sector_effects
        @skill_hidden = world.skill_hidden
        @damage_multiplier = world.damage_multiplier
        @leveltime = world.leveltime
      end

      def update
        # Calculate delta time for smooth animations
        now = Time.now
        delta_time = now - @last_update_time
        @last_update_time = now

        # Menu is active -- only update menu animation, skip game logic
        if @menu&.active?
          @menu.update
          return
        end

        # Intermission screen active
        if @intermission
          @intermission.update
          return
        end

        handle_input(delta_time)

        # Advance the simulation at 35/sec (DOOM's tic rate). Everything that
        # decides what happens now lives in Game::World; this loop only decides
        # how many tics are owed and hands over the input for each.
        @tic_accumulator += delta_time * 35.0
        while @tic_accumulator >= 1.0
          @tic_accumulator -= 1.0
          @leveltime = @world.run_tic(@player.id => build_ticcmd)
          @item_pickup.update_flash
        end

        @animations&.update(@leveltime)
        @status_bar&.update
        @renderer.hidden_things = @world.hidden_things

        if @world.exit_triggered && !@intermission
          trigger_level_exit(@world.exit_triggered)
        end

        # Other players are drawn as sprites; the local one never is.
        @renderer.players = @world.players
        @renderer.view_player = @player

        # Pass combat state to renderer for death frame rendering
        @renderer.combat = @combat
        @renderer.monster_ai = @monster_ai
        @renderer.leveltime = @leveltime

        # Render the 3D world. This is the generated-frame rate: it runs every
        # loop iteration, whether or not the result gets presented.
        @renderer.render_frame
        track_frame_rates

        # Render HUD on top
        if @weapon_renderer && !@player_state&.dead
          @weapon_renderer.render(@renderer.framebuffer)
        end
        if @status_bar
          @status_bar.render(@renderer.framebuffer)
        end

        # Pickup message (drawn into framebuffer with DOOM font, 4 seconds like Chocolate Doom)
        if @doom_font && @item_pickup&.pickup_message && @item_pickup.message_tics > 0
          @doom_font.draw_text(@renderer.framebuffer, @item_pickup.pickup_message, 2, 2)
        end

        # Red tint when dead
        if @player_state&.dead
          apply_death_tint(@renderer.framebuffer)
        end
      end

      # Per-frame input sampling. Produces nothing but intent: the simulation
      # itself runs per-tic in run_player_tic. Mouse motion is accumulated here
      # because frames are more frequent than tics and dropping the surplus
      # would lose part of every flick.
      def handle_input(_delta_time)
        # Handle respawn when dead
        if @player_state&.dead
          if @player_state.death_tic > 35  # 1 second delay before respawn allowed
            if Gosu.button_down?(Gosu::KB_SPACE) || Gosu.button_down?(Gosu::KB_X) ||
               Gosu.button_down?(Gosu::MS_LEFT) || Gosu.button_down?(Gosu::KB_LEFT_SHIFT)
              respawn_player
            end
          end
          return  # No other input while dead
        end

        handle_mouse_look          # accumulates into @pending_turn
        handle_weapon_switch if @player_state
      end

      # Collect this tic's intent. Everything that moves the player must come
      # through here, so that replacing it with a ticcmd off the network is the
      # only change multiplayer needs.
      def build_ticcmd
        return Game::Ticcmd.none if @player_state&.dead

        forward = 0.0
        side = 0.0
        forward += 1.0 if Gosu.button_down?(Gosu::KB_UP) || Gosu.button_down?(Gosu::KB_W)
        forward -= 1.0 if Gosu.button_down?(Gosu::KB_DOWN) || Gosu.button_down?(Gosu::KB_S)
        side += 1.0 if Gosu.button_down?(Gosu::KB_D)
        side -= 1.0 if Gosu.button_down?(Gosu::KB_A)

        turn = @pending_turn
        @pending_turn = 0.0
        turn += TURN_SPEED if Gosu.button_down?(Gosu::KB_LEFT)
        turn -= TURN_SPEED if Gosu.button_down?(Gosu::KB_RIGHT)

        buttons = 0
        if (@mouse_captured && Gosu.button_down?(Gosu::MS_LEFT)) ||
           Gosu.button_down?(Gosu::KB_LEFT_CONTROL) || Gosu.button_down?(Gosu::KB_RIGHT_CONTROL) ||
           Gosu.button_down?(Gosu::KB_X) || Gosu.button_down?(Gosu::KB_LEFT_SHIFT) ||
           Gosu.button_down?(Gosu::KB_RIGHT_SHIFT)
          buttons |= Game::Ticcmd::BTN_FIRE
        end
        if Gosu.button_down?(Gosu::KB_SPACE) || Gosu.button_down?(Gosu::KB_E)
          buttons |= Game::Ticcmd::BTN_USE
        end

        Game::Ticcmd.new(forward, side, turn, buttons)
      end

      # Apply one tic of intent to one player. Movement, firing and use all live
      # here so they advance at a fixed 35 Hz regardless of frame rate.
      def handle_weapon_switch
        if Gosu.button_down?(Gosu::KB_1)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_FIST)
        elsif Gosu.button_down?(Gosu::KB_2)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_PISTOL)
        elsif Gosu.button_down?(Gosu::KB_3)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_SHOTGUN)
        elsif Gosu.button_down?(Gosu::KB_4)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_CHAINGUN)
        elsif Gosu.button_down?(Gosu::KB_5)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_ROCKET)
        elsif Gosu.button_down?(Gosu::KB_6)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_PLASMA)
        elsif Gosu.button_down?(Gosu::KB_7)
          @player_state.switch_weapon(Game::PlayerState::WEAPON_BFG)
        end
      end

      # Lazily computed and cached on first access; cleared by load_next_map.
      def map_bounds
        return @map_bounds if defined?(@map_bounds) && @map_bounds
        min_x = min_y = Float::INFINITY
        max_x = max_y = -Float::INFINITY
        @map.vertices.each do |v|
          min_x = v.x if v.x < min_x
          max_x = v.x if v.x > max_x
          min_y = v.y if v.y < min_y
          max_y = v.y if v.y > max_y
        end
        return nil if max_x == min_x || max_y == min_y
        @map_bounds = { min_x: min_x, max_x: max_x, min_y: min_y, max_y: max_y }
      end

      def handle_mouse_look
        return unless @mouse_captured

        current_x = mouse_x
        if @last_mouse_x
          delta_x = current_x - @last_mouse_x
          # Accumulate rather than turn: the turn is applied by the next ticcmd,
          # so fast mouse motion between tics is summed instead of dropped.
          @pending_turn -= delta_x * MOUSE_SENSITIVITY if delta_x != 0
        end

        # Keep mouse centered
        center_x = width / 2
        if (current_x - center_x).abs > 50
          self.mouse_x = center_x
          @last_mouse_x = center_x
        else
          @last_mouse_x = current_x
        end
      end

      # Gosu calls this before draw; false skips both the blit and the buffer
      # swap, so the main loop keeps generating frames without waiting on the
      # display. Returning true unconditionally restores plain vsync behaviour.
      def needs_redraw?
        return true unless @uncapped_fps

        (Gosu.milliseconds - @last_present_ms) >= (@present_interval_ms * PRESENT_INTERVAL_SLACK)
      end

      attr_reader :refresh_hz

      # Frames generated vs frames actually shown. With uncapped rendering the
      # first number can run well above the second, which is the whole point.
      def track_frame_rates
        @fps_frames += 1
        now = Time.now
        elapsed = now - @fps_time
        return if elapsed < 0.5

        @fps_display = (@fps_frames / elapsed).round(1)
        @present_fps_display = (@present_frames / elapsed).round(1)
        @fps_frames = 0
        @present_frames = 0
        @fps_time = now
      end

      def draw
        @present_frames += 1
        @last_present_ms = Gosu.milliseconds

        # Aim the camera at the local player. The simulation runs at 35 Hz but
        # we draw as fast as we can, so interpolate between the previous tic's
        # pose and the current one by however far into the tic we are.
        @renderer.apply_view(*@player.view_pose(@tic_accumulator))

        # Intermission screen
        if @intermission
          fb = Array.new(Render::SCREEN_WIDTH * Render::SCREEN_HEIGHT, 0)
          @intermission.render(fb)
          active_pal = @all_palette_rgba[0]
          rgba = fb.map { |idx| active_pal[idx] }.join
          @screen_image = Gosu::Image.from_blob(
            Render::SCREEN_WIDTH, Render::SCREEN_HEIGHT, rgba
          )
          @screen_image.draw(0, 0, 0, SCALE, SCALE)
          return
        end

        # Screen melt effect in progress
        if @screen_melt && !@screen_melt.done?
          fb = Array.new(Render::SCREEN_WIDTH * Render::SCREEN_HEIGHT, 0)
          @screen_melt.update(fb)
          active_pal = @all_palette_rgba[0]
          rgba = fb.map { |idx| active_pal[idx] }.join
          @screen_image = Gosu::Image.from_blob(
            Render::SCREEN_WIDTH, Render::SCREEN_HEIGHT, rgba
          )
          @screen_image.draw(0, 0, 0, SCALE, SCALE)
          @screen_melt = nil if @screen_melt.done?
          return
        end

        if @menu&.active?
          if @menu.needs_background?
            # Render game view + HUD as background, then overlay menu on top
            @renderer.render_frame
            @weapon_renderer&.render(@renderer.framebuffer) unless @player_state&.dead
            @status_bar&.render(@renderer.framebuffer)
            fb = @renderer.framebuffer.dup
          else
            # Title screen: black background
            fb = Array.new(Render::SCREEN_WIDTH * Render::SCREEN_HEIGHT, 0)
          end
          @menu.render(fb, nil)

          # Capture current menu frame for melt transitions
          @last_menu_fb = fb.dup

          active_pal = @all_palette_rgba[0]
          rgba = fb.map { |idx| active_pal[idx] }.join
          @screen_image = Gosu::Image.from_blob(
            Render::SCREEN_WIDTH, Render::SCREEN_HEIGHT, rgba
          )
          @screen_image.draw(0, 0, 0, SCALE, SCALE)
        elsif @show_map
          draw_automap
        else
          # Select palette: red tint when taking damage (palettes 1-8)
          # Pain palette (1-8 red), pickup palette (9 yellow)
          pal_idx = if @item_pickup && @item_pickup.pickup_flash > 0
                      9  # Yellow flash for item pickup
                    elsif @player_state
                      @player_state.damage_count.clamp(0, 8)
                    else
                      0
                    end
          active_pal = @all_palette_rgba[pal_idx]
          rgba = @renderer.framebuffer.map { |idx| active_pal[idx] }.join

          @screen_image = Gosu::Image.from_blob(
            Render::SCREEN_WIDTH, Render::SCREEN_HEIGHT, rgba
          )
          @screen_image.draw(0, 0, 0, SCALE, SCALE)

          draw_debug_overlay if @show_debug
        end
      end

      def draw_debug_overlay
        yjit_status = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 'ON' : 'OFF'
        ang = (Math.atan2(@player.sin_angle, @player.cos_angle) * 180.0 / Math::PI).round(1)

        # Shown vs generated: only worth spelling out when they differ.
        shown = if @uncapped_fps
                  "shown #{@present_fps_display} / #{@refresh_hz.round} Hz"
                else
                  'vsync'
                end

        lines = if @menu&.options&.[](:rubykaigi_mode)
                  [
                    "#{@fps_display} FPS  (#{shown})",
                    "YJIT: #{yjit_status}  (Y to toggle)",
                    "Ruby #{RUBY_VERSION}",
                    "Map: #{@current_map}",
                    "Pos: #{@player.x.round}, #{@player.y.round}",
                    "Ang: #{ang}",
                  ]
                else
                  [
                    "FPS: #{@fps_display}  (#{shown})",
                    "YJIT: #{yjit_status}",
                    "Pos: #{@player.x.round}, #{@player.y.round}",
                    "Ang: #{ang}",
                  ]
                end

        y = 4
        lines.each do |line|
          @debug_font.draw_text(line, 8, y + 2, 1, 1, 1, Gosu::Color::BLACK)
          @debug_font.draw_text(line, 6, y, 1, 1, 1, Gosu::Color::WHITE)
          y += 26
        end
      end

      def button_down(id)
        # Intermission handles input
        if @intermission
          @intermission.handle_key
          if @intermission.finished
            next_map = @intermission.next_map
            @intermission = nil
            if next_map
              load_next_map(next_map)
            else
              # Episode complete - return to menu
              @menu&.show
            end
          end
          return
        end

        # Menu handles input when active
        if @menu&.active?
          key = case id
                when Gosu::KB_UP then :up
                when Gosu::KB_DOWN then :down
                when Gosu::KB_RETURN, Gosu::KB_SPACE then :enter
                when Gosu::KB_ESCAPE then :escape
                end
          if key
            # Play menu navigation sounds
            case key
            when :up, :down
              @sound&.menu_move
            when :escape
              @sound&.menu_back
            end

            # Capture old screen before menu state change (for melt effect)
            old_state = @menu.state
            result = @menu.handle_key(key)
            new_state = @menu.state

            # Trigger melt when transitioning from title to main menu
            if old_state == Game::Menu::STATE_TITLE && new_state == Game::Menu::STATE_MAIN && @last_menu_fb
              # Build the new screen (main menu with game background)
              @renderer.render_frame
              @weapon_renderer&.render(@renderer.framebuffer) unless @player_state&.dead
              @status_bar&.render(@renderer.framebuffer)
              new_fb = @renderer.framebuffer.dup
              @menu.render(new_fb, nil)
              @screen_melt = Render::ScreenMelt.new(@last_menu_fb, new_fb)
            end

            # Play confirmation sound on select
            @sound&.menu_select if key == :enter

            case result
            when :start_game
              apply_difficulty(@menu.selected_skill)
            when :resume
              @mouse_captured = true
              SDLKeyboardGrab.grab!
            when :quit
              close
            when Hash
              handle_option_toggle(result[:option], result[:value]) if result[:action] == :toggle_option
            end
          end
          return
        end

        case id
        when Gosu::KB_ESCAPE
          SDLKeyboardGrab.release!
          @mouse_captured = false
          self.mouse_x = width / 2
          self.mouse_y = height / 2
          @menu&.show
        when Gosu::MS_LEFT, Gosu::KB_TAB
          unless @mouse_captured
            @mouse_captured = true
            @last_mouse_x = mouse_x
            SDLKeyboardGrab.grab!
          end
        when Gosu::KB_Z
          @show_debug = !@show_debug
        when Gosu::KB_B
          @renderer.skip_background_fill = !@renderer.skip_background_fill
          puts "Background fill: #{@renderer.skip_background_fill ? 'OFF' : 'ON'}"
        when Gosu::KB_Y
          if defined?(RubyVM::YJIT)
            setup_yjit_toggle
            if RubyVM::YJIT.enabled?
              RubyVM::YJIT.disable
              puts "YJIT disabled!"
            else
              RubyVM::YJIT.enable
              puts "YJIT enabled!"
            end
          end
        when Gosu::KB_C
          if @monster_ai
            @monster_ai.aggression = !@monster_ai.aggression
            puts "Monster aggression: #{@monster_ai.aggression ? 'ON' : 'OFF'}"
          end
        when Gosu::KB_M
          @show_map = !@show_map
        when Gosu::KB_F12
          capture_debug_snapshot
        end
      end

      # Sector damage types from DOOM (p_spec.c)
      # Type 5: 10 damage, Type 7: 5 damage, Type 4/16: 20 damage
      def apply_death_tint(framebuffer)
        # Death keeps damage_count at max so the pain palette stays red
        @player_state.damage_count = 8 if @player_state&.dead
      end

      def respawn_player
        # Single player: death restarts the level, so the world rebuilds its
        # actor subsystems and the cached references must be refreshed.
        @world.restart_level(@player)
        bind_world(@world)

        # Re-apply active cheats from menu options
        return unless @menu

        opts = @menu.options
        @player_state.god_mode = opts[:god_mode]
        @player_state.infinite_ammo = opts[:infinite_ammo]
        handle_option_toggle(:all_weapons, true) if opts[:all_weapons]
        apply_rubykaigi_mode if opts[:rubykaigi_mode]
      end

      def handle_option_toggle(option, value)
        case option
        when :god_mode
          @player_state.god_mode = value
          @player_state.health = 100 if value
        when :infinite_ammo
          @player_state.infinite_ammo = value
        when :all_weapons
          if value
            # Give all weapons that have sprites loaded
            @gfx_weapons ||= @weapon_renderer&.gfx&.weapons || {}
            (0..7).each do |w|
              name = Game::PlayerState::WEAPON_NAMES[w]
              @player_state.has_weapons[w] = true if @gfx_weapons[name]&.dig(:idle)
            end
            @player_state.ammo_bullets = @player_state.max_bullets
            @player_state.ammo_shells = @player_state.max_shells
            @player_state.ammo_rockets = @player_state.max_rockets
            @player_state.ammo_cells = @player_state.max_cells
          end
        when :uncapped_fps
          @uncapped_fps = value
          # Re-read on re-enable: the window may have moved to a display with a
          # different refresh rate.
          if value
            @refresh_hz = (SDLDisplayMode.refresh_rate || DEFAULT_REFRESH_HZ).to_f
            @present_interval_ms = 1000.0 / @refresh_hz
          end
        when :fullscreen
          self.fullscreen = value if respond_to?(:fullscreen=)
        when :rubykaigi_mode
          apply_rubykaigi_mode if value
        end
      end

      def apply_rubykaigi_mode
        return unless @menu&.options&.[](:rubykaigi_mode)

        # God mode: invincible for stress-free demos
        @player_state.god_mode = true
        @player_state.health = 100

        # All weapons + full ammo
        handle_option_toggle(:all_weapons, true)
        @player_state.infinite_ammo = true

        # Monsters don't attack (peaceful exploration)
        @monster_ai.aggression = false if @monster_ai

        # Force debug overlay on (shows FPS + YJIT status)
        @show_debug = true
      end

      # DOOM thing flags: bit 0 = skill 1-2, bit 1 = skill 3, bit 2 = skill 4-5
      def compute_skill_hidden(skill)
        flag_bit = case skill
                   when Game::Menu::SKILL_BABY, Game::Menu::SKILL_EASY then 0x0001
                   when Game::Menu::SKILL_MEDIUM then 0x0002
                   when Game::Menu::SKILL_HARD, Game::Menu::SKILL_NIGHTMARE then 0x0004
                   else 0x0007
                   end
        hidden = {}
        @map.things.each_with_index do |thing, idx|
          # Multiplayer-only things (bit 4) are hidden in single player
          if (thing.flags & 0x0010) != 0 || (thing.flags & flag_bit) == 0
            hidden[idx] = true
          end
        end
        hidden
      end

      def trigger_level_exit(exit_type)
        # Gather stats
        total_monsters = @monster_ai ? @monster_ai.monsters.size : 0
        killed = @combat ? @combat.dead_things.size : 0

        total_items = Game::ItemPickup::ITEMS.keys.count { |t|
          @map.things.any? { |th| th.type == t }
        }
        picked = @item_pickup ? @item_pickup.picked_up.size : 0

        # Secret sectors (type 9) tracked by SectorActions
        total_secrets = @map.sectors.count { |s| s.special == 9 }
        found_secrets = @sector_actions ? @sector_actions.secrets_found.size : 0

        stats = {
          map: @current_map,
          kills: killed, total_kills: total_monsters,
          items: picked, total_items: total_items,
          secrets: found_secrets, total_secrets: total_secrets,
          time_tics: @leveltime,
          exit_type: exit_type,
        }

        @intermission = Game::Intermission.new(@renderer.wad, @status_bar.gfx, stats)
      end

      def load_next_map(map_name)
        return unless map_name

        wad = @renderer.wad
        @current_map = map_name

        # Load new map data
        map = Map::MapData.load(wad, map_name)
        @map = map
        @map_bounds = nil  # Recompute on next automap draw

        # Rebuild all systems for new map
        @renderer = Render::Renderer.new(
          wad, map, @renderer.textures, @palette, @renderer.colormap,
          @renderer.flats.values, @renderer.sprites, @animations
        )
        # A new map means a new world; the RNG carries over so the run stays
        # one continuous deterministic sequence across level changes.
        skill_hidden = compute_skill_hidden(@skill || Game::Menu::SKILL_MEDIUM)
        world = Game::World.new(map, sprites: @renderer.sprites, sound: @sound,
                                     random: @random, skill_hidden: skill_hidden)
        world.damage_multiplier = @damage_multiplier
        world.item_pickup.ammo_multiplier = (@skill == Game::Menu::SKILL_BABY) ? 2 : 1
        world.monster_ai.aggression = true
        world.monster_ai.damage_multiplier = @damage_multiplier
        world.add_player

        bind_world(world)
      end

      def apply_difficulty(skill)
        @skill = skill
        @damage_multiplier = case skill
                             when Game::Menu::SKILL_BABY then 0.5
                             when Game::Menu::SKILL_EASY then 0.75
                             when Game::Menu::SKILL_MEDIUM then 1.0
                             when Game::Menu::SKILL_HARD then 1.0
                             when Game::Menu::SKILL_NIGHTMARE then 1.5
                             else 1.0
                             end

        # Push difficulty into the world before respawning: respawn rebuilds the
        # actor subsystems from the world's settings, so setting them here only
        # would be discarded.
        @world.skill_hidden = compute_skill_hidden(skill)
        @world.damage_multiplier = @damage_multiplier
        @physics.skill_hidden = @world.skill_hidden

        # Baby mode: start with some armor
        @player_state.armor = 50 if skill == Game::Menu::SKILL_BABY

        respawn_player

        @monster_ai.aggression = true
        @monster_ai.damage_multiplier = @damage_multiplier
        # Baby: double ammo from pickups (matching DOOM skill 1)
        @item_pickup.ammo_multiplier = (skill == Game::Menu::SKILL_BABY) ? 2 : 1
      end

      def setup_yjit_toggle
        return if @yjit_toggle_ready || !defined?(RubyVM::YJIT)
        require "fiddle"

        address = Fiddle::Handle::DEFAULT["rb_yjit_enabled_p"]
        enabled_ptr = Fiddle::Pointer.new(address, Fiddle::SIZEOF_CHAR)

        RubyVM::YJIT.singleton_class.prepend(Module.new do
          define_method(:enable) do |**kwargs|
            return false if enabled?
            return super(**kwargs) unless RUBY_DESCRIPTION.include?("+YJIT")
            enabled_ptr[0] = 1
            true
          end

          define_method(:disable) do
            return false unless enabled?
            enabled_ptr[0] = 0
            true
          end
        end)

        @yjit_toggle_ready = true
      rescue StandardError => e
        warn "YJIT toggle setup failed: #{e.class}: #{e.message}"
      end

      def needs_cursor?
        !@mouse_captured
      end

      # --- Debug Snapshot ---

      def capture_debug_snapshot
        dir = File.join(File.expand_path('../..', __dir__), '..', 'screenshots')
        FileUtils.mkdir_p(dir)

        ts = Time.now.strftime('%Y%m%d_%H%M%S_%L')
        prefix = File.join(dir, ts)

        # Save framebuffer as PNG
        require 'chunky_png' unless defined?(ChunkyPNG)
        w = Render::SCREEN_WIDTH
        h = Render::SCREEN_HEIGHT
        img = ChunkyPNG::Image.new(w, h)
        fb = @renderer.framebuffer
        colors = @palette.colors
        h.times do |y|
          row = y * w
          w.times do |x|
            r, g, b = colors[fb[row + x]]
            img[x, y] = ChunkyPNG::Color.rgb(r, g, b)
          end
        end
        img.save("#{prefix}.png")

        # Save player state and sector info
        sector = @map.sector_at(@player.x, @player.y)
        sector_idx = sector ? @map.sectors.index(sector) : nil
        angle_deg = Math.atan2(@player.sin_angle, @player.cos_angle) * 180.0 / Math::PI

        # Sprite diagnostics
        sprites_info = @renderer.sprite_diagnostics
        nearby = sprites_info.select { |s| s[:dist] && s[:dist] < 1500 }
                             .sort_by { |s| s[:dist] }

        sprite_lines = nearby.map do |s|
          "  #{s[:prefix]} type=#{s[:type]} pos=(#{s[:x]},#{s[:y]}) dist=#{s[:dist]} " \
          "screen_x=#{s[:screen_x]} scale=#{s[:sprite_scale]} " \
          "range=#{s[:screen_range]} status=#{s[:status]} " \
          "clip_segs=#{s[:clipping_segs]}" \
          "#{s[:clipping_detail]&.any? ? "\n    clips: #{s[:clipping_detail].map { |c| "ds[#{c[:x1]}..#{c[:x2]}] scale=#{c[:scale]} sil=#{c[:sil]}" }.join(', ')}" : ''}"
        end

        File.write("#{prefix}.txt", <<~INFO)
          pos: #{@player.x.round(1)}, #{@player.y.round(1)}, #{@player.z.round(1)}
          angle: #{angle_deg.round(1)}
          sector: #{sector_idx}
          floor: #{sector&.floor_height} (#{sector&.floor_texture})
          ceil: #{sector&.ceiling_height} (#{sector&.ceiling_texture})
          light: #{sector&.light_level}

          nearby sprites (#{nearby.size}):
          #{sprite_lines.join("\n")}
        INFO

        puts "Snapshot saved: #{prefix}.png + .txt"
      end

      # --- Automap ---

      MAP_MARGIN = 20

      def build_sector_colors
        # Generate distinct colors for each sector using golden ratio hue spacing
        num_sectors = @map.sectors.size
        colors = Array.new(num_sectors)
        phi = (1 + Math.sqrt(5)) / 2.0

        num_sectors.times do |i|
          hue = (i * phi * 360) % 360
          colors[i] = hsv_to_gosu(hue, 0.6, 0.85)
        end
        colors
      end

      def hsv_to_gosu(h, s, v)
        c = v * s
        x = c * (1 - ((h / 60.0) % 2 - 1).abs)
        m = v - c

        r, g, b = case (h / 60).to_i % 6
                  when 0 then [c, x, 0]
                  when 1 then [x, c, 0]
                  when 2 then [0, c, x]
                  when 3 then [0, x, c]
                  when 4 then [x, 0, c]
                  when 5 then [c, 0, x]
                  end

        Gosu::Color.new(255, ((r + m) * 255).to_i, ((g + m) * 255).to_i, ((b + m) * 255).to_i)
      end

      def draw_automap
        # Black background
        Gosu.draw_rect(0, 0, width, height, Gosu::Color::BLACK, 0)

        bounds = map_bounds
        return unless bounds

        verts = @map.vertices
        min_x, max_x, min_y, max_y = bounds[:min_x], bounds[:max_x], bounds[:min_y], bounds[:max_y]
        map_w = max_x - min_x
        map_h = max_y - min_y

        # Scale to fit screen with margin
        draw_w = width - MAP_MARGIN * 2
        draw_h = height - MAP_MARGIN * 2
        scale = [draw_w.to_f / map_w, draw_h.to_f / map_h].min

        # Center the map
        offset_x = MAP_MARGIN + (draw_w - map_w * scale) / 2.0
        offset_y = MAP_MARGIN + (draw_h - map_h * scale) / 2.0

        # World to screen coordinate transform (Y flipped: world Y+ is up, screen Y+ is down)
        to_sx = ->(wx) { offset_x + (wx - min_x) * scale }
        to_sy = ->(wy) { offset_y + (max_y - wy) * scale }

        # Draw linedefs colored by front sector
        two_sided_color = Gosu::Color.new(100, 80, 80, 80)

        @map.linedefs.each do |linedef|
          v1 = verts[linedef.v1]
          v2 = verts[linedef.v2]
          sx1 = to_sx.call(v1.x)
          sy1 = to_sy.call(v1.y)
          sx2 = to_sx.call(v2.x)
          sy2 = to_sy.call(v2.y)

          if linedef.two_sided?
            # Two-sided: dim line, colored by front sector
            front_sd = @map.sidedefs[linedef.sidedef_right]
            color = @sector_colors[front_sd.sector]
            dim = Gosu::Color.new(100, color.red, color.green, color.blue)
            Gosu.draw_line(sx1, sy1, dim, sx2, sy2, dim, 1)
          else
            # One-sided: solid wall, bright sector color
            front_sd = @map.sidedefs[linedef.sidedef_right]
            color = @sector_colors[front_sd.sector]
            Gosu.draw_line(sx1, sy1, color, sx2, sy2, color, 1)
          end
        end

        # Draw player
        px = to_sx.call(@player.x)
        py = to_sy.call(@player.y)

        cos_a = @player.cos_angle
        sin_a = @player.sin_angle

        # FOV cone
        fov_len = 40.0
        half_fov = Math::PI / 4.0 # 45 deg half = 90 deg total

        # Cone edges (in world space, Y+ is up; on screen Y is flipped via to_sy)
        left_dx = Math.cos(half_fov) * cos_a - Math.sin(half_fov) * sin_a
        left_dy = Math.cos(half_fov) * sin_a + Math.sin(half_fov) * cos_a
        right_dx = Math.cos(-half_fov) * cos_a - Math.sin(-half_fov) * sin_a
        right_dy = Math.cos(-half_fov) * sin_a + Math.sin(-half_fov) * cos_a

        # Screen positions for cone tips
        lx = px + left_dx * fov_len
        ly = py - left_dy * fov_len  # negate because screen Y is flipped
        rx = px + right_dx * fov_len
        ry = py - right_dy * fov_len

        cone_color = Gosu::Color.new(60, 0, 255, 0)
        Gosu.draw_triangle(px, py, cone_color, lx, ly, cone_color, rx, ry, cone_color, 2)

        # Cone edge lines
        edge_color = Gosu::Color.new(180, 0, 255, 0)
        Gosu.draw_line(px, py, edge_color, lx, ly, edge_color, 3)
        Gosu.draw_line(px, py, edge_color, rx, ry, edge_color, 3)

        # Player dot
        dot_size = 4
        Gosu.draw_rect(px - dot_size, py - dot_size, dot_size * 2, dot_size * 2, Gosu::Color::GREEN, 3)

        # Direction line
        dir_len = 12.0
        dx = px + cos_a * dir_len
        dy = py - sin_a * dir_len
        Gosu.draw_line(px, py, Gosu::Color::WHITE, dx, dy, Gosu::Color::WHITE, 3)
      end

      # --- End Automap ---

      def needs_cursor?
        !@mouse_captured
      end
    end
  end
end
