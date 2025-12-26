# frozen_string_literal: true

require 'gosu'

module Doom
  module Platform
    class GosuWindow < Gosu::Window
      SCALE = 3

      # Movement constants
      MOVE_SPEED = 8.0       # Units per frame
      TURN_SPEED = 3.0       # Degrees per frame
      MOUSE_SENSITIVITY = 0.15  # Mouse look sensitivity
      PLAYER_RADIUS = 16.0   # Collision radius

      USE_DISTANCE = 64.0  # Max distance to use a linedef

      def initialize(renderer, palette, map, player_state = nil, status_bar = nil, weapon_renderer = nil, sector_actions = nil)
        super(Render::SCREEN_WIDTH * SCALE, Render::SCREEN_HEIGHT * SCALE, false)
        self.caption = 'Doom Ruby'

        @renderer = renderer
        @palette = palette
        @map = map
        @player_state = player_state
        @status_bar = status_bar
        @weapon_renderer = weapon_renderer
        @sector_actions = sector_actions
        @screen_image = nil
        @mouse_captured = false
        @last_mouse_x = nil
        @last_update_time = Time.now
        @use_pressed = false

        # Pre-build palette lookup for speed
        @palette_rgba = palette.colors.map { |r, g, b| [r, g, b, 255].pack('CCCC') }
      end

      def update
        # Calculate delta time for smooth animations
        now = Time.now
        delta_time = now - @last_update_time
        @last_update_time = now

        handle_input

        # Update player state
        if @player_state
          @player_state.update_attack
          @player_state.update_bob(delta_time)
        end

        # Update HUD animations
        @status_bar&.update

        # Update sector actions (doors, lifts, etc.)
        @sector_actions&.update

        # Render the 3D world
        @renderer.render_frame

        # Render HUD on top
        if @weapon_renderer
          @weapon_renderer.render(@renderer.framebuffer)
        end
        if @status_bar
          @status_bar.render(@renderer.framebuffer)
        end
      end

      def handle_input
        # Mouse look
        handle_mouse_look

        # Keyboard turning
        if Gosu.button_down?(Gosu::KB_LEFT)
          @renderer.turn(TURN_SPEED)
        end
        if Gosu.button_down?(Gosu::KB_RIGHT)
          @renderer.turn(-TURN_SPEED)
        end

        # Forward/backward movement
        move_x = 0.0
        move_y = 0.0

        if Gosu.button_down?(Gosu::KB_UP) || Gosu.button_down?(Gosu::KB_W)
          move_x += @renderer.cos_angle * MOVE_SPEED
          move_y += @renderer.sin_angle * MOVE_SPEED
        end
        if Gosu.button_down?(Gosu::KB_DOWN) || Gosu.button_down?(Gosu::KB_S)
          move_x -= @renderer.cos_angle * MOVE_SPEED
          move_y -= @renderer.sin_angle * MOVE_SPEED
        end

        # Strafe
        if Gosu.button_down?(Gosu::KB_A)
          move_x += @renderer.sin_angle * MOVE_SPEED
          move_y -= @renderer.cos_angle * MOVE_SPEED
        end
        if Gosu.button_down?(Gosu::KB_D)
          move_x -= @renderer.sin_angle * MOVE_SPEED
          move_y += @renderer.cos_angle * MOVE_SPEED
        end

        # Track if player is moving (for weapon bob)
        is_moving = move_x != 0.0 || move_y != 0.0
        @player_state.is_moving = is_moving if @player_state

        # Apply movement with collision detection
        if is_moving
          try_move(move_x, move_y)
        end

        # Handle firing
        if @player_state && @mouse_captured && Gosu.button_down?(Gosu::MS_LEFT)
          @player_state.start_attack
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
        new_x = @renderer.player_x + dx
        new_y = @renderer.player_y + dy

        # Check if new position is valid (simple collision detection)
        if valid_position?(new_x, new_y)
          @renderer.move_to(new_x, new_y)
          update_player_height(new_x, new_y)
        else
          # Try sliding along walls - try X movement only
          if valid_position?(new_x, @renderer.player_y)
            @renderer.move_to(new_x, @renderer.player_y)
            update_player_height(new_x, @renderer.player_y)
          # Try Y movement only
          elsif valid_position?(@renderer.player_x, new_y)
            @renderer.move_to(@renderer.player_x, new_y)
            update_player_height(@renderer.player_x, new_y)
          end
        end
      end

      def update_player_height(x, y)
        sector = @map.sector_at(x, y)
        return unless sector

        # Player view height is 41 units above floor
        target_z = sector.floor_height + 41
        @renderer.set_z(target_z)
      end

      def valid_position?(x, y)
        # Check if position is inside a valid sector
        sector = @map.sector_at(x, y)
        return false unless sector

        # Check floor height - can't walk into walls
        floor_height = sector.floor_height
        return false if floor_height > @renderer.player_z + 24  # Max step height

        # Check against blocking linedefs
        @map.linedefs.each do |linedef|
          next unless linedef_blocks?(linedef, x, y)
          return false
        end

        true
      end

      def linedef_blocks?(linedef, x, y)
        v1 = @map.vertices[linedef.v1]
        v2 = @map.vertices[linedef.v2]

        # Check if player circle intersects this line
        return false unless line_circle_intersect?(v1.x, v1.y, v2.x, v2.y, x, y, PLAYER_RADIUS)

        # One-sided linedef (wall) always blocks
        return true if linedef.sidedef_left == 0xFFFF

        # Two-sided: check if passable
        front_side = @map.sidedefs[linedef.sidedef_right]
        back_side = @map.sidedefs[linedef.sidedef_left]

        front_sector = @map.sectors[front_side.sector]
        back_sector = @map.sectors[back_side.sector]

        # Check step height
        step = back_sector.floor_height - front_sector.floor_height
        return true if step.abs > 24

        # Check ceiling clearance
        min_ceiling = [front_sector.ceiling_height, back_sector.ceiling_height].min
        max_floor = [front_sector.floor_height, back_sector.floor_height].max
        return true if min_ceiling - max_floor < 56  # Player height

        false
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
        # Fast RGBA conversion using pre-built palette
        rgba = @renderer.framebuffer.map { |idx| @palette_rgba[idx] }.join

        @screen_image = Gosu::Image.from_blob(
          Render::SCREEN_WIDTH,
          Render::SCREEN_HEIGHT,
          rgba
        )

        @screen_image.draw(0, 0, 0, SCALE, SCALE)
      end

      def button_down(id)
        case id
        when Gosu::KB_ESCAPE
          if @mouse_captured
            @mouse_captured = false
            self.mouse_x = width / 2
            self.mouse_y = height / 2
          else
            close
          end
        when Gosu::MS_LEFT, Gosu::KB_TAB
          unless @mouse_captured
            @mouse_captured = true
            @last_mouse_x = mouse_x
          end
        end
      end

      def needs_cursor?
        !@mouse_captured
      end
    end
  end
end
