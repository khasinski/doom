# frozen_string_literal: true

module Doom
  module Render
    # Renders the classic DOOM status bar at the bottom of the screen
    class StatusBar
      STATUS_BAR_HEIGHT = 32
      STATUS_BAR_Y = SCREEN_HEIGHT - STATUS_BAR_HEIGHT

      # DOOM status bar layout (from st_stuff.c)
      # Positions from Chocolate Doom st_stuff.c (relative to status bar top)
      AMMO_RIGHT_X = 44      # ST_AMMOX - right edge of 3-digit ammo
      HEALTH_RIGHT_X = 90    # ST_HEALTHX
      ARMOR_RIGHT_X = 221    # ST_ARMORX

      ARMS_BG_X = 104        # ST_ARMSBGX
      ARMS_BG_Y = 0          # ST_ARMSBGY (relative to status bar)
      ARMS_X = 111            # ST_ARMSX
      ARMS_Y = 4              # ST_ARMSY (relative to status bar)
      ARMS_XSPACE = 12
      ARMS_YSPACE = 10

      FACE_X = 149           # Centered in face background area
      FACE_Y = 2             # Vertically centered in status bar

      KEYS_X = 239           # ST_KEY0X

      # Small ammo counts (right side of status bar)
      SMALL_AMMO_X = 288     # Current ammo X
      SMALL_MAX_X = 314      # Max ammo X
      SMALL_AMMO_Y = [5, 11, 23, 17]  # Bullets, Shells, Cells, Rockets (relative to bar)

      NUM_WIDTH = 14          # Width of large digit
      SMALL_NUM_WIDTH = 4     # Width of small digit

      def initialize(hud_graphics, player_state)
        @gfx = hud_graphics
        @player = player_state
        @face_timer = 0
        @face_index = 0
      end

      def render(framebuffer)
        # Draw status bar background
        draw_sprite(framebuffer, @gfx.status_bar, 0, STATUS_BAR_Y) if @gfx.status_bar

        # Draw arms background (single-player only, replaces FRAG area)
        draw_sprite(framebuffer, @gfx.arms_background, ARMS_BG_X, STATUS_BAR_Y + ARMS_BG_Y) if @gfx.arms_background

        # Y position for numbers (3 pixels from top of status bar)
        num_y = STATUS_BAR_Y + 3

        # Draw ammo count (right-aligned ending at AMMO_RIGHT_X)
        draw_number_right(framebuffer, @player.current_ammo, AMMO_RIGHT_X, num_y) if @player.current_ammo

        # Draw health with percent
        draw_number_right(framebuffer, @player.health, HEALTH_RIGHT_X, num_y)
        draw_percent(framebuffer, HEALTH_RIGHT_X, num_y)

        # Draw weapon selector (2-7)
        draw_arms(framebuffer)

        # Draw face
        draw_face(framebuffer)

        # Draw armor with percent
        draw_number_right(framebuffer, @player.armor, ARMOR_RIGHT_X, num_y)
        draw_percent(framebuffer, ARMOR_RIGHT_X, num_y)

        # Draw keys
        draw_keys(framebuffer)

        # Draw small ammo counts (right side)
        draw_ammo_counts(framebuffer)
      end

      def update
        # Cycle face animation
        @face_timer += 1
        if @face_timer > 15  # Change face every ~0.5 seconds
          @face_timer = 0
          @face_index = (@face_index + 1) % 3
        end
      end

      private

      def draw_sprite(framebuffer, sprite, x, y)
        return unless sprite

        sprite.width.times do |sx|
          column = sprite.column_pixels(sx)
          next unless column

          draw_x = x + sx
          next if draw_x < 0 || draw_x >= SCREEN_WIDTH

          column.each_with_index do |color, sy|
            next unless color

            draw_y = y + sy
            next if draw_y < 0 || draw_y >= SCREEN_HEIGHT

            framebuffer[draw_y * SCREEN_WIDTH + draw_x] = color
          end
        end
      end

      # Draw number right-aligned with right edge at right_x
      def draw_number_right(framebuffer, value, right_x, y)
        return unless value

        value = value.to_i.clamp(-999, 999)
        str = value.to_s

        # Draw from right to left, starting from right edge
        current_x = right_x
        str.reverse.each_char do |char|
          digit_sprite = if char == '-'
                           @gfx.numbers['-']
                         else
                           @gfx.numbers[char.to_i]
                         end

          if digit_sprite
            current_x -= NUM_WIDTH
            draw_sprite(framebuffer, digit_sprite, current_x, y)
          end
        end
      end

      def draw_percent(framebuffer, x, y)
        percent = @gfx.numbers['%']
        draw_sprite(framebuffer, percent, x, y) if percent
      end

      def draw_arms(framebuffer)
        # Weapon numbers 2-7 in a 3x2 grid
        6.times do |i|
          weapon_num = i + 2  # weapons 2-7
          owned = @player.has_weapons[weapon_num]
          digit = owned ? @gfx.yellow_numbers[weapon_num] : @gfx.grey_numbers[weapon_num]
          next unless digit

          x = ARMS_X + (i % 3) * ARMS_XSPACE
          y = STATUS_BAR_Y + ARMS_Y + (i / 3) * ARMS_YSPACE
          draw_sprite(framebuffer, digit, x, y)
        end
      end

      def draw_face(framebuffer)
        # Pain level: 0 = healthy, 4 = near death
        health = @player.health.clamp(0, 100)
        pain_level = ((100 - health) * 5) / 101

        face = if @player.health <= 0
                 @gfx.faces[:dead]
               else
                 faces = @gfx.faces[pain_level]
                 faces[:straight][@face_index] if faces && faces[:straight]
               end

        return unless face
        draw_sprite(framebuffer, face, FACE_X, STATUS_BAR_Y + FACE_Y)
      end

      def draw_ammo_counts(framebuffer)
        ammo_current = [@player.ammo_bullets, @player.ammo_shells, @player.ammo_cells, @player.ammo_rockets]
        ammo_max = [@player.max_bullets, @player.max_shells, @player.max_cells, @player.max_rockets]

        4.times do |i|
          y = STATUS_BAR_Y + SMALL_AMMO_Y[i]
          draw_small_number_right(framebuffer, ammo_current[i], SMALL_AMMO_X, y)
          draw_small_number_right(framebuffer, ammo_max[i], SMALL_MAX_X, y)
        end
      end

      def draw_small_number_right(framebuffer, value, right_x, y)
        return unless value
        str = value.to_i.to_s
        current_x = right_x
        str.reverse.each_char do |char|
          digit = @gfx.yellow_numbers[char.to_i]
          if digit
            current_x -= SMALL_NUM_WIDTH
            draw_sprite(framebuffer, digit, current_x, y)
          end
        end
      end

      def draw_keys(framebuffer)
        key_x = KEYS_X
        key_spacing = 10

        # Blue keys (top row)
        if @player.keys[:blue_card]
          draw_sprite(framebuffer, @gfx.keys[:blue_card], key_x, STATUS_BAR_Y + 3)
        elsif @player.keys[:blue_skull]
          draw_sprite(framebuffer, @gfx.keys[:blue_skull], key_x, STATUS_BAR_Y + 3)
        end

        # Yellow keys (middle row)
        if @player.keys[:yellow_card]
          draw_sprite(framebuffer, @gfx.keys[:yellow_card], key_x, STATUS_BAR_Y + 13)
        elsif @player.keys[:yellow_skull]
          draw_sprite(framebuffer, @gfx.keys[:yellow_skull], key_x, STATUS_BAR_Y + 13)
        end

        # Red keys (bottom row)
        if @player.keys[:red_card]
          draw_sprite(framebuffer, @gfx.keys[:red_card], key_x, STATUS_BAR_Y + 23)
        elsif @player.keys[:red_skull]
          draw_sprite(framebuffer, @gfx.keys[:red_skull], key_x, STATUS_BAR_Y + 23)
        end
      end
    end
  end
end
