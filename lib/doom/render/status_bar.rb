# frozen_string_literal: true

module Doom
  module Render
    # Renders the classic DOOM status bar at the bottom of the screen
    class StatusBar
      STATUS_BAR_HEIGHT = 32
      STATUS_BAR_Y = SCREEN_HEIGHT - STATUS_BAR_HEIGHT

      # DOOM status bar layout (from st_stuff.c)
      # X positions are RIGHT EDGE of each number area (numbers are right-aligned)
      # Y positions relative to status bar top

      # Right edge X positions for numbers
      AMMO_RIGHT_X = 44      # ST_AMMOX - right edge of 3-digit ammo
      HEALTH_RIGHT_X = 90    # ST_HEALTHX - right edge of 3-digit health
      ARMOR_RIGHT_X = 221    # ST_ARMORX - right edge of 3-digit armor

      FACE_X = 149           # Adjusted for proper centering in face background
      KEYS_X = 239           # ST_KEY0X

      NUM_WIDTH = 14         # Width of each digit

      def initialize(hud_graphics, player_state)
        @gfx = hud_graphics
        @player = player_state
        @face_timer = 0
        @face_index = 0
      end

      def render(framebuffer)
        # Draw status bar background
        draw_sprite(framebuffer, @gfx.status_bar, 0, STATUS_BAR_Y) if @gfx.status_bar

        # Y position for numbers (3 pixels from top of status bar)
        num_y = STATUS_BAR_Y + 3

        # Draw ammo count (right-aligned ending at AMMO_RIGHT_X)
        draw_number_right(framebuffer, @player.current_ammo, AMMO_RIGHT_X, num_y) if @player.current_ammo

        # Draw health with percent (right-aligned ending at HEALTH_RIGHT_X)
        draw_number_right(framebuffer, @player.health, HEALTH_RIGHT_X, num_y)
        draw_percent(framebuffer, HEALTH_RIGHT_X, num_y)

        # Draw face
        draw_face(framebuffer)

        # Draw armor with percent (right-aligned ending at ARMOR_RIGHT_X)
        draw_number_right(framebuffer, @player.armor, ARMOR_RIGHT_X, num_y)
        draw_percent(framebuffer, ARMOR_RIGHT_X, num_y)

        # Draw keys
        draw_keys(framebuffer)
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

      def draw_face(framebuffer)
        # In DOOM, face sprite health levels are inverted: 0 = full health, 4 = dying
        sprite_health = 4 - @player.health_level
        faces = @gfx.faces[sprite_health]
        return unless faces

        # Get current face sprite
        face = if @player.health <= 0
                 @gfx.faces[:dead]
               elsif faces[:straight] && faces[:straight][@face_index]
                 faces[:straight][@face_index]
               else
                 faces[:straight]&.first
               end

        return unless face

        # Position face in the background area
        face_x = FACE_X
        face_y = STATUS_BAR_Y + 2  # Slightly below top of status bar
        draw_sprite(framebuffer, face, face_x, face_y)
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
