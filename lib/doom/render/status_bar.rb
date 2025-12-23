# frozen_string_literal: true

module Doom
  module Render
    # Renders the classic DOOM status bar at the bottom of the screen
    class StatusBar
      STATUS_BAR_HEIGHT = 32
      STATUS_BAR_Y = SCREEN_HEIGHT - STATUS_BAR_HEIGHT

      # DOOM status bar layout (from st_stuff.c):
      # Ammo: x=2, 3-digit number ending at ~x=43
      # Health: x=50, 3-digit number ending at ~x=90, then % at x=90
      # Face: x=143 (center), actual background area is 104-167
      # Armor: x=179, 3-digit number, then %
      # Keys: x=239, y=3/13/23 for blue/yellow/red

      # Number positions (right edge of the number area)
      AMMO_X = 2
      HEALTH_X = 50
      ARMOR_X = 179
      FACE_X = 144       # Center of face background (143-144)
      KEYS_X = 239

      NUM_WIDTH = 14     # Width of each digit
      NUM_HEIGHT = 16

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

        # Draw ammo count (left side)
        draw_number_left(framebuffer, @player.current_ammo, AMMO_X, num_y, 3) if @player.current_ammo

        # Draw health with percent
        draw_number_left(framebuffer, @player.health, HEALTH_X, num_y, 3)
        draw_percent(framebuffer, HEALTH_X + NUM_WIDTH * 3, num_y)

        # Draw face
        draw_face(framebuffer)

        # Draw armor with percent
        draw_number_left(framebuffer, @player.armor, ARMOR_X, num_y, 3)
        draw_percent(framebuffer, ARMOR_X + NUM_WIDTH * 3, num_y)

        # Draw keys (right side)
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

      # Draw number left-to-right starting at x position
      def draw_number_left(framebuffer, value, x, y, max_digits)
        return unless value

        value = value.to_i.clamp(-999, 999)
        str = value.to_s

        # Draw each digit
        current_x = x
        str.each_char do |char|
          digit_sprite = if char == '-'
                           @gfx.numbers['-']
                         else
                           @gfx.numbers[char.to_i]
                         end

          if digit_sprite
            draw_sprite(framebuffer, digit_sprite, current_x, y)
            current_x += NUM_WIDTH
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

        # Center face in its background area (face bg is roughly 104-167, center ~143)
        face_x = FACE_X - (face.width / 2)
        face_y = STATUS_BAR_Y + 1  # Face is positioned near top of status bar
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
