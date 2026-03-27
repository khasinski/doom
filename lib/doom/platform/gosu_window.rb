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
        rescue
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

      # Movement constants (matching Chocolate Doom P_Thrust / P_XYMovement)
      # DOOM: terminal walk speed = 7.55 units/tic = 264 units/sec
      # Continuous-time: v_terminal = thrust_rate / decay_rate
      # decay_rate = -ln(0.90625) * 35 = 3.44/sec
      # thrust_rate = 264 * 3.44 = 908 units/sec^2
      MOVE_THRUST_RATE = 264.0 * 3.44     # Thrust rate (units/sec^2)
      FRICTION_DECAY_RATE = 3.44           # Friction decay (1/sec)
      STOPSPEED = 0.5                      # Snap-to-zero threshold (units/sec)
      TURN_SPEED = 3.0       # Degrees per frame
      MOUSE_SENSITIVITY = 0.15  # Mouse look sensitivity
      PLAYER_RADIUS = 16.0   # Collision radius

      USE_DISTANCE = 64.0  # Max distance to use a linedef

      # Solid thing types with their collision radii (from mobjinfo[] MF_SOLID)
      # Monsters, barrels, pillars, lamps, torches, trees block player movement
      SOLID_THING_RADIUS = {
        9 => 20, 65 => 20, 66 => 20, 67 => 20, 68 => 20, # Shotgun Guy variants
        3004 => 20, 84 => 20,                               # Zombieman
        3001 => 20,                                          # Imp
        3002 => 30, 58 => 30,                                # Demon, Spectre
        3003 => 24, 69 => 24,                                # Baron, Hell Knight
        3006 => 16,                                          # Lost Soul
        3005 => 31,                                          # Cacodemon
        16 => 40,                                            # Cyberdemon
        7 => 128,                                            # Spider Mastermind
        64 => 20,                                            # Archvile
        71 => 31,                                            # Pain Elemental
        2035 => 10,                                          # Barrel
        2028 => 16,                                          # Tall lamp
        48 => 16, 30 => 16, 32 => 16,                       # Tech column, green/red pillars
        31 => 16, 33 => 16, 36 => 16,                       # Short pillars
        41 => 16, 43 => 16,                                  # Evil eye, burnt tree
        54 => 32,                                            # Brown tree
        44 => 16, 45 => 16, 46 => 16,                       # Tall torches
        55 => 16, 56 => 16, 57 => 16,                       # Short torches
        47 => 16, 70 => 16,                                  # Stubs
        85 => 16, 86 => 16,                                  # Tall tech lamps
        2046 => 16,                                          # Burning barrel
      }.freeze

      def initialize(renderer, palette, map, player_state = nil, status_bar = nil, weapon_renderer = nil, sector_actions = nil, animations = nil, sector_effects = nil, item_pickup = nil, combat = nil, monster_ai = nil, menu = nil)
        fullscreen = ARGV.include?('--fullscreen') || ARGV.include?('-f')
        super(Render::SCREEN_WIDTH * SCALE, Render::SCREEN_HEIGHT * SCALE, fullscreen)
        self.caption = 'Doom Ruby'
        self.update_interval = 0  # Uncap framerate (default 16.67ms = 60 FPS cap)
        SDLKeyboardGrab.setup

        @renderer = renderer
        @palette = palette
        @map = map
        @player_state = player_state
        @status_bar = status_bar
        @weapon_renderer = weapon_renderer
        @sector_actions = sector_actions
        @animations = animations
        @sector_effects = sector_effects
        @item_pickup = item_pickup
        @combat = combat
        @monster_ai = monster_ai
        @menu = menu
        @damage_multiplier = 1.0
        @last_floor_height = nil
        @move_momx = 0.0
        @move_momy = 0.0
        @leveltime = 0
        @tic_accumulator = 0.0
        @screen_image = nil
        @mouse_captured = false
        @last_mouse_x = nil
        @last_update_time = Time.now
        @use_pressed = false
        @show_debug = false
        @show_map = false
        @debug_font = Gosu::Font.new(16)
        @fps_frames = 0
        @fps_time = Time.now
        @fps_display = 0.0

        # Precompute sector colors for automap
        @sector_colors = build_sector_colors

        # Pre-build palette RGBA lookups for all 14 palettes (0=normal, 1-8=pain red)
        @all_palette_rgba = []
        wad = renderer.instance_variable_get(:@wad)
        14.times do |pal_idx|
          pal = Wad::Palette.load(wad, pal_idx)
          @all_palette_rgba << pal.colors.map { |r, g, b| [r, g, b, 255].pack('CCCC') }
        end
        @palette_rgba = @all_palette_rgba[0]
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

        handle_input(delta_time)

        # Update player state (per-frame for smooth bob)
        if @player_state
          @player_state.update_bob(delta_time)
          @player_state.update_view_bob(delta_time)
        end

        # Advance game tics at 35/sec (DOOM's tic rate)
        @tic_accumulator += delta_time * 35.0
        while @tic_accumulator >= 1.0
          @leveltime += 1
          @tic_accumulator -= 1.0
          @sector_effects&.update
          @player_state&.update_viewheight
          @player_state&.update_attack  # Attack timing at 35fps like DOOM
          @combat&.update
          @monster_ai&.update(@renderer.player_x, @renderer.player_y)

          @player_state&.update_damage_count

          # Sector damage (nukage, lava, etc.) every 32 tics
          if @player_state && !@player_state.dead && (@leveltime % 32 == 0)
            check_sector_damage
          end

          # Track death tic for death animation
          if @player_state&.dead
            @player_state.death_tic += 1
          end
        end
        @animations&.update(@leveltime)

        # Update HUD animations
        @status_bar&.update

        # Update sector actions (doors, lifts, etc.)
        if @sector_actions
          @sector_actions.update_player_position(@renderer.player_x, @renderer.player_y)
          @sector_actions.update
        end

        # Check item pickups
        if @item_pickup
          @item_pickup.update(@renderer.player_x, @renderer.player_y)
          @renderer.hidden_things = @item_pickup.picked_up
        end

        # Pass combat state to renderer for death frame rendering
        @combat&.update_player_pos(@renderer.player_x, @renderer.player_y)
        @renderer.combat = @combat
        @renderer.monster_ai = @monster_ai
        @renderer.leveltime = @leveltime

        # Render the 3D world
        @renderer.render_frame

        # Render HUD on top
        if @weapon_renderer && !@player_state&.dead
          @weapon_renderer.render(@renderer.framebuffer)
        end
        if @status_bar
          @status_bar.render(@renderer.framebuffer)
        end

        # Red tint when dead
        if @player_state&.dead
          apply_death_tint(@renderer.framebuffer)
        end
      end

      def handle_input(delta_time)
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

        # Mouse look
        handle_mouse_look

        # Keyboard turning
        if Gosu.button_down?(Gosu::KB_LEFT)
          @renderer.turn(TURN_SPEED)
        end
        if Gosu.button_down?(Gosu::KB_RIGHT)
          @renderer.turn(-TURN_SPEED)
        end

        # Apply thrust from input (P_Thrust: additive, scaled by delta_time)
        thrust = MOVE_THRUST_RATE * delta_time
        has_input = false

        if Gosu.button_down?(Gosu::KB_UP) || Gosu.button_down?(Gosu::KB_W)
          @move_momx += @renderer.cos_angle * thrust
          @move_momy += @renderer.sin_angle * thrust
          has_input = true
        end
        if Gosu.button_down?(Gosu::KB_DOWN) || Gosu.button_down?(Gosu::KB_S)
          @move_momx -= @renderer.cos_angle * thrust
          @move_momy -= @renderer.sin_angle * thrust
          has_input = true
        end
        if Gosu.button_down?(Gosu::KB_A)
          @move_momx -= @renderer.sin_angle * thrust
          @move_momy += @renderer.cos_angle * thrust
          has_input = true
        end
        if Gosu.button_down?(Gosu::KB_D)
          @move_momx += @renderer.sin_angle * thrust
          @move_momy -= @renderer.cos_angle * thrust
          has_input = true
        end

        # Apply friction (continuous-time equivalent of *= 0.90625 per tic)
        decay = Math.exp(-FRICTION_DECAY_RATE * delta_time)
        if !has_input && @move_momx.abs < STOPSPEED && @move_momy.abs < STOPSPEED
          @move_momx = 0.0
          @move_momy = 0.0
        else
          @move_momx *= decay
          @move_momy *= decay
        end

        # Track movement state for weapon/view bob
        if @player_state
          @player_state.is_moving = has_input
          @player_state.set_movement_momentum(@move_momx, @move_momy)
        end

        # Apply momentum with collision detection (scale by delta_time for frame-rate independence)
        if @move_momx.abs > STOPSPEED || @move_momy.abs > STOPSPEED
          try_move(@move_momx * delta_time, @move_momy * delta_time)
        end

        # Handle firing (left click, Ctrl, X, or Shift)
        if @player_state && ((@mouse_captured && Gosu.button_down?(Gosu::MS_LEFT)) ||
            Gosu.button_down?(Gosu::KB_LEFT_CONTROL) || Gosu.button_down?(Gosu::KB_RIGHT_CONTROL) ||
            Gosu.button_down?(Gosu::KB_X) || Gosu.button_down?(Gosu::KB_LEFT_SHIFT) ||
            Gosu.button_down?(Gosu::KB_RIGHT_SHIFT))
          was_attacking = @player_state.attacking
          @player_state.start_attack
          # Fire hitscan on the first frame of the attack
          if @player_state.attacking && !was_attacking && @combat
            @combat.fire(@renderer.player_x, @renderer.player_y, @renderer.player_z,
                         @renderer.cos_angle, @renderer.sin_angle, @player_state.weapon)
          end
        end

        # Handle weapon switching with number keys
        handle_weapon_switch if @player_state

        # Handle use key (spacebar or E)
        handle_use_key if @sector_actions
      end

      def handle_use_key
        use_down = Gosu.button_down?(Gosu::KB_SPACE) || Gosu.button_down?(Gosu::KB_E)

        if use_down && !@use_pressed
          @use_pressed = true
          try_use_linedef
        elsif !use_down
          @use_pressed = false
        end
      end

      def try_use_linedef
        # Cast a ray forward to find a usable linedef
        player_x = @renderer.player_x
        player_y = @renderer.player_y
        cos_angle = @renderer.cos_angle
        sin_angle = @renderer.sin_angle

        # Check point in front of player
        use_x = player_x + cos_angle * USE_DISTANCE
        use_y = player_y + sin_angle * USE_DISTANCE

        # Find the closest linedef the player is facing
        best_linedef = nil
        best_idx = nil
        best_dist = Float::INFINITY

        @map.linedefs.each_with_index do |linedef, idx|
          next if linedef.special == 0  # Skip non-special linedefs

          v1 = @map.vertices[linedef.v1]
          v2 = @map.vertices[linedef.v2]

          # Check if player is close enough to the linedef
          dist = point_to_line_distance(player_x, player_y, v1.x, v1.y, v2.x, v2.y)
          next if dist > USE_DISTANCE
          next if dist >= best_dist

          # Check if player is facing the linedef (on the front side)
          next unless facing_linedef?(player_x, player_y, cos_angle, sin_angle, v1, v2)

          best_linedef = linedef
          best_idx = idx
          best_dist = dist
        end

        if best_linedef
          @sector_actions.use_linedef(best_linedef, best_idx)
        end
      end

      def point_to_line_distance(px, py, x1, y1, x2, y2)
        # Vector from line start to point
        dx = px - x1
        dy = py - y1

        # Line direction vector
        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = line_dx * line_dx + line_dy * line_dy

        return Math.sqrt(dx * dx + dy * dy) if line_len_sq == 0

        # Project point onto line, clamped to segment
        t = ((dx * line_dx) + (dy * line_dy)) / line_len_sq
        t = [[t, 0.0].max, 1.0].min

        # Closest point on line segment
        closest_x = x1 + t * line_dx
        closest_y = y1 + t * line_dy

        # Distance from point to closest point on segment
        dist_x = px - closest_x
        dist_y = py - closest_y
        Math.sqrt(dist_x * dist_x + dist_y * dist_y)
      end

      def facing_linedef?(px, py, cos_angle, sin_angle, v1, v2)
        # Calculate linedef normal (perpendicular to line, pointing to front side)
        line_dx = v2.x - v1.x
        line_dy = v2.y - v1.y

        # Normal points to the right of the line direction
        normal_x = -line_dy
        normal_y = line_dx

        # Normalize
        len = Math.sqrt(normal_x * normal_x + normal_y * normal_y)
        return false if len == 0

        normal_x /= len
        normal_y /= len

        # Check if player is on the front side (normal side) of the line
        to_player_x = px - v1.x
        to_player_y = py - v1.y
        dot_player = to_player_x * normal_x + to_player_y * normal_y

        # Player must be on front side
        return false if dot_player < 0

        # Check if player is facing toward the line
        dot_facing = cos_angle * (-normal_x) + sin_angle * (-normal_y)
        dot_facing > 0.5  # Must be roughly facing the line
      end

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

      def try_move(dx, dy)
        old_x = @renderer.player_x
        old_y = @renderer.player_y
        new_x = old_x + dx
        new_y = old_y + dy

        # Check if new position is valid and path doesn't cross blocking linedefs
        if valid_move?(old_x, old_y, new_x, new_y)
          @renderer.move_to(new_x, new_y)
          update_player_height(new_x, new_y)
        else
          # Wall sliding: project movement along the blocking wall
          slide_x, slide_y = compute_slide(old_x, old_y, dx, dy)
          if slide_x && (slide_x != 0.0 || slide_y != 0.0)
            sx = old_x + slide_x
            sy = old_y + slide_y
            if valid_move?(old_x, old_y, sx, sy)
              @renderer.move_to(sx, sy)
              update_player_height(sx, sy)
              # Redirect momentum along the wall
              @move_momx = slide_x / ([dx.abs, dy.abs].max.nonzero? || 1) * @move_momx.abs
              @move_momy = slide_y / ([dx.abs, dy.abs].max.nonzero? || 1) * @move_momy.abs
              return
            end
          end

          # Fallback: try axis-aligned sliding
          if dx != 0.0 && valid_move?(old_x, old_y, new_x, old_y)
            @renderer.move_to(new_x, old_y)
            update_player_height(new_x, old_y)
            @move_momy *= 0.0
          elsif dy != 0.0 && valid_move?(old_x, old_y, old_x, new_y)
            @renderer.move_to(old_x, new_y)
            update_player_height(old_x, new_y)
            @move_momx *= 0.0
          else
            # Fully blocked - kill momentum
            @move_momx = 0.0
            @move_momy = 0.0
          end
        end
      end

      # Find the blocking linedef and project movement along it
      def compute_slide(px, py, dx, dy)
        best_wall = nil
        best_dist = Float::INFINITY

        @map.linedefs.each do |linedef|
          v1 = @map.vertices[linedef.v1]
          v2 = @map.vertices[linedef.v2]

          # Only check linedefs near the player
          next unless line_circle_intersect?(v1.x, v1.y, v2.x, v2.y, px + dx, py + dy, PLAYER_RADIUS)

          # Check if this linedef actually blocks
          next unless linedef_blocks?(linedef, px + dx, py + dy) ||
                      crosses_blocking_linedef?(px, py, px + dx, py + dy, linedef)

          # Distance from player to this linedef
          dist = point_to_line_distance(px, py, v1.x, v1.y, v2.x, v2.y)
          if dist < best_dist
            best_dist = dist
            best_wall = linedef
          end
        end

        return nil unless best_wall

        # Get wall direction vector
        v1 = @map.vertices[best_wall.v1]
        v2 = @map.vertices[best_wall.v2]
        wall_dx = (v2.x - v1.x).to_f
        wall_dy = (v2.y - v1.y).to_f
        wall_len = Math.sqrt(wall_dx * wall_dx + wall_dy * wall_dy)
        return nil if wall_len == 0

        wall_dx /= wall_len
        wall_dy /= wall_len

        # Project movement onto wall direction
        dot = dx * wall_dx + dy * wall_dy
        [dot * wall_dx, dot * wall_dy]
      end

      def update_player_height(x, y)
        sector = @map.sector_at(x, y)
        return unless sector

        new_floor = sector.floor_height

        if @player_state
          # Detect step: floor height changed since last move
          if @last_floor_height && @last_floor_height != new_floor
            step = new_floor - @last_floor_height
            @player_state.notify_step(step) if step.abs <= 24
          end
          @last_floor_height = new_floor

          view_bob = @player_state.view_bob_offset
          @renderer.set_z(new_floor + @player_state.viewheight + view_bob)
        else
          @renderer.set_z(new_floor + 41)
        end
      end

      def valid_move?(old_x, old_y, new_x, new_y)
        # Check if destination is inside a valid sector
        sector = @map.sector_at(new_x, new_y)
        return false unless sector

        # Check floor height - can't step up too high
        floor_height = sector.floor_height
        return false if floor_height > @renderer.player_z + 24  # Max step height

        # Check against blocking linedefs: both circle intersection and path crossing
        @map.linedefs.each do |linedef|
          if linedef_blocks?(linedef, new_x, new_y)
            return false
          end
          if crosses_blocking_linedef?(old_x, old_y, new_x, new_y, linedef)
            return false
          end
        end

        # Check against solid things (monsters, barrels, pillars, etc.)
        combined_radius = PLAYER_RADIUS
        picked = @item_pickup&.picked_up
        @map.things.each_with_index do |thing, idx|
          next if picked && picked[idx]
          next if @combat && @combat.dead?(idx)
          thing_radius = SOLID_THING_RADIUS[thing.type]
          next unless thing_radius

          dx = new_x - thing.x
          dy = new_y - thing.y
          min_dist = combined_radius + thing_radius
          if dx * dx + dy * dy < min_dist * min_dist
            return false
          end
        end

        true
      end

      # Check if movement from (x1,y1) to (x2,y2) crosses a blocking linedef
      def crosses_blocking_linedef?(x1, y1, x2, y2, linedef)
        v1 = @map.vertices[linedef.v1]
        v2 = @map.vertices[linedef.v2]

        # One-sided linedef always blocks crossing
        if linedef.sidedef_left == 0xFFFF
          return segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)
        end

        # BLOCKING flag blocks crossing even on two-sided linedefs
        if (linedef.flags & 0x0001) != 0
          return segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)
        end

        # Two-sided: check if impassable (high step OR low ceiling)
        front_side = @map.sidedefs[linedef.sidedef_right]
        back_side = @map.sidedefs[linedef.sidedef_left]
        front_sector = @map.sectors[front_side.sector]
        back_sector = @map.sectors[back_side.sector]

        step = (back_sector.floor_height - front_sector.floor_height).abs
        min_ceiling = [front_sector.ceiling_height, back_sector.ceiling_height].min
        max_floor = [front_sector.floor_height, back_sector.floor_height].max

        # Passable if step is small AND enough headroom
        return false if step <= 24 && (min_ceiling - max_floor) >= 56

        segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)
      end

      # Test if line segment (ax1,ay1)-(ax2,ay2) intersects (bx1,by1)-(bx2,by2)
      def segments_intersect?(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
        d1x = ax2 - ax1
        d1y = ay2 - ay1
        d2x = bx2 - bx1
        d2y = by2 - by1

        denom = d1x * d2y - d1y * d2x
        return false if denom.abs < 0.001  # Parallel

        dx = bx1 - ax1
        dy = by1 - ay1

        t = (dx * d2y - dy * d2x).to_f / denom
        u = (dx * d1y - dy * d1x).to_f / denom

        t > 0.0 && t < 1.0 && u >= 0.0 && u <= 1.0
      end

      def linedef_blocks?(linedef, x, y)
        v1 = @map.vertices[linedef.v1]
        v2 = @map.vertices[linedef.v2]

        # Check if player circle intersects this line
        return false unless line_circle_intersect?(v1.x, v1.y, v2.x, v2.y, x, y, PLAYER_RADIUS)

        # One-sided linedef (wall) always blocks
        return true if linedef.sidedef_left == 0xFFFF

        # BLOCKING flag (0x0001) blocks even on two-sided linedefs (e.g., windows)
        return true if (linedef.flags & 0x0001) != 0

        # Two-sided: check if impassable (high step OR low ceiling)
        front_side = @map.sidedefs[linedef.sidedef_right]
        back_side = @map.sidedefs[linedef.sidedef_left]

        front_sector = @map.sectors[front_side.sector]
        back_sector = @map.sectors[back_side.sector]

        step = (back_sector.floor_height - front_sector.floor_height).abs
        min_ceiling = [front_sector.ceiling_height, back_sector.ceiling_height].min
        max_floor = [front_sector.floor_height, back_sector.floor_height].max

        # Block if step too high OR not enough headroom
        step > 24 || (min_ceiling - max_floor) < 56
      end

      def line_circle_intersect?(x1, y1, x2, y2, cx, cy, radius)
        # Vector from line start to circle center
        dx = cx - x1
        dy = cy - y1

        # Line direction vector
        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = line_dx * line_dx + line_dy * line_dy

        return false if line_len_sq == 0

        # Project circle center onto line, clamped to segment
        t = ((dx * line_dx) + (dy * line_dy)) / line_len_sq
        t = [[t, 0.0].max, 1.0].min

        # Closest point on line segment
        closest_x = x1 + t * line_dx
        closest_y = y1 + t * line_dy

        # Distance from circle center to closest point
        dist_x = cx - closest_x
        dist_y = cy - closest_y
        dist_sq = dist_x * dist_x + dist_y * dist_y

        dist_sq < radius * radius
      end

      def handle_mouse_look
        return unless @mouse_captured

        current_x = mouse_x
        if @last_mouse_x
          delta_x = current_x - @last_mouse_x
          @renderer.turn(-delta_x * MOUSE_SENSITIVITY) if delta_x != 0
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

      def draw
        if @menu&.active?
          if @menu.needs_background?
            # Render game view as background, then overlay menu on top
            @renderer.render_frame
            fb = @renderer.framebuffer.dup
          else
            # Title screen: black background
            fb = Array.new(Render::SCREEN_WIDTH * Render::SCREEN_HEIGHT, 0)
          end
          @menu.render(fb, nil)
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
          pal_idx = @player_state ? @player_state.damage_count.clamp(0, 8) : 0
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
        # Update FPS counter (refresh every 0.5 seconds)
        @fps_frames += 1
        now = Time.now
        elapsed = now - @fps_time
        if elapsed >= 0.5
          @fps_display = (@fps_frames / elapsed).round(1)
          @fps_frames = 0
          @fps_time = now
        end

        sector = @map.sector_at(@renderer.player_x, @renderer.player_y)
        return unless sector

        # Find sector index
        sector_idx = @map.sectors.index(sector)

        lines = [
          "FPS: #{@fps_display}",
          "Sector #{sector_idx}",
          "Floor: #{sector.floor_height} (#{sector.floor_texture})",
          "Ceil:  #{sector.ceiling_height} (#{sector.ceiling_texture})",
          "Light: #{sector.light_level}",
          "Pos: #{@renderer.player_x.round}, #{@renderer.player_y.round}",
          "Heading: #{(Math.atan2(@renderer.sin_angle, @renderer.cos_angle) * 180.0 / Math::PI).round(1)}",
          "YJIT: #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 'ON' : 'OFF'} (Y to toggle)",
        ]

        y = 4
        lines.each do |line|
          @debug_font.draw_text(line, 6, y + 1, 1, 1, 1, Gosu::Color::BLACK)
          @debug_font.draw_text(line, 5, y, 1, 1, 1, Gosu::Color::WHITE)
          y += 18
        end
      end

      def button_down(id)
        # Menu handles input when active
        if @menu&.active?
          key = case id
                when Gosu::KB_UP then :up
                when Gosu::KB_DOWN then :down
                when Gosu::KB_RETURN, Gosu::KB_SPACE then :enter
                when Gosu::KB_ESCAPE then :escape
                end
          if key
            result = @menu.handle_key(key)
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
      SECTOR_DAMAGE = { 5 => 10, 7 => 5, 4 => 20, 16 => 20, 11 => 20 }.freeze

      def check_sector_damage
        sector = @map.sector_at(@renderer.player_x, @renderer.player_y)
        return unless sector

        damage = SECTOR_DAMAGE[sector.special]
        @player_state.take_damage((damage * @damage_multiplier).to_i) if damage
      end

      def apply_death_tint(framebuffer)
        # Death keeps damage_count at max so the pain palette stays red
        @player_state.damage_count = 8 if @player_state&.dead
      end

      def respawn_player
        @player_state.reset
        @last_floor_height = nil
        @move_momx = 0.0
        @move_momy = 0.0

        # Reset item pickup, combat, and monster AI state
        sprites = @combat&.instance_variable_get(:@sprites)
        @item_pickup = Game::ItemPickup.new(@map, @player_state) if @item_pickup
        @combat = Game::Combat.new(@map, @player_state, sprites) if @combat && sprites
        @monster_ai = Game::MonsterAI.new(@map, @combat, @player_state) if @monster_ai && @combat

        # Move player to start position
        ps = @map.player_start
        if ps
          @renderer.set_player(ps.x, ps.y, 41, ps.angle)
          update_player_height(ps.x, ps.y)
        end
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
            (0..7).each { |w| @player_state.has_weapons[w] = true }
            @player_state.ammo_bullets = @player_state.max_bullets
            @player_state.ammo_shells = @player_state.max_shells
            @player_state.ammo_rockets = @player_state.max_rockets
            @player_state.ammo_cells = @player_state.max_cells
          end
        when :fullscreen
          self.fullscreen = value if respond_to?(:fullscreen=)
        when :rubykaigi_mode
          # Placeholder for RubyKaigi mode
        end
      end

      def apply_difficulty(skill)
        @damage_multiplier = case skill
                             when Game::Menu::SKILL_BABY then 0.5
                             when Game::Menu::SKILL_EASY then 0.75
                             when Game::Menu::SKILL_MEDIUM then 1.0
                             when Game::Menu::SKILL_HARD then 1.0
                             when Game::Menu::SKILL_NIGHTMARE then 1.5
                             else 1.0
                             end

        # Baby mode: start with some armor
        if skill == Game::Menu::SKILL_BABY
          @player_state.armor = 50
        end

        if @monster_ai
          @monster_ai.aggression = true
          @monster_ai.damage_multiplier = @damage_multiplier
        end

        # Baby: double ammo from pickups (matching DOOM skill 1)
        if @item_pickup
          @item_pickup.ammo_multiplier = (skill == Game::Menu::SKILL_BABY) ? 2 : 1
        end

        respawn_player
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
      rescue => e
        puts "YJIT toggle setup failed: #{e.message}"
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
        sector = @map.sector_at(@renderer.player_x, @renderer.player_y)
        sector_idx = sector ? @map.sectors.index(sector) : nil
        angle_deg = Math.atan2(@renderer.sin_angle, @renderer.cos_angle) * 180.0 / Math::PI

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
          pos: #{@renderer.player_x.round(1)}, #{@renderer.player_y.round(1)}, #{@renderer.player_z.round(1)}
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

        # Compute map bounds
        verts = @map.vertices
        min_x = min_y = Float::INFINITY
        max_x = max_y = -Float::INFINITY
        verts.each do |v|
          min_x = v.x if v.x < min_x
          max_x = v.x if v.x > max_x
          min_y = v.y if v.y < min_y
          max_y = v.y if v.y > max_y
        end

        map_w = max_x - min_x
        map_h = max_y - min_y
        return if map_w == 0 || map_h == 0

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
        px = to_sx.call(@renderer.player_x)
        py = to_sy.call(@renderer.player_y)

        cos_a = @renderer.cos_angle
        sin_a = @renderer.sin_angle

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
