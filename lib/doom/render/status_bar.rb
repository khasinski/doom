# frozen_string_literal: true

module Doom
  module Render
    # Renders the classic DOOM status bar at the bottom of the screen
    class StatusBar
      STATUS_BAR_HEIGHT = 32
      STATUS_BAR_Y = SCREEN_HEIGHT - STATUS_BAR_HEIGHT

      # X positions for status bar elements (based on 320px width)
      AMMO_X = 44        # Ammo count position
      HEALTH_X = 90      # Health count position
      FACE_X = 143       # Face position (center of face area)
      ARMS_X = 104       # Arms area start
      ARMOR_X = 221      # Armor count position
      KEYS_X = 239       # Keys area start

      def initialize(hud_graphics, player_state)
        @gfx = hud_graphics
        @player = player_state
        @face_timer = 0
        @face_index = 0
      end

      def render(framebuffer)
        # Draw status bar background
        draw_sprite(framebuffer, @gfx.status_bar, 0, STATUS_BAR_Y) if @gfx.status_bar

        # Draw ammo count
        draw_number(framebuffer, @player.current_ammo, AMMO_X, STATUS_BAR_Y + 3, 3) if @player.current_ammo

        # Draw health
        draw_number(framebuffer, @player.health, HEALTH_X, STATUS_BAR_Y + 3, 3)
        draw_percent(framebuffer, HEALTH_X + 42, STATUS_BAR_Y + 3)

        # Draw face
        draw_face(framebuffer)

        # Draw armor
        draw_number(framebuffer, @player.armor, ARMOR_X, STATUS_BAR_Y + 3, 3)
        draw_percent(framebuffer, ARMOR_X + 42, STATUS_BAR_Y + 3)

        # Draw keys
        draw_keys(framebuffer)

        # Draw arms indicators (which weapons player has)
        draw_arms(framebuffer)
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

      def draw_number(framebuffer, value, x, y, digits)
        return unless value

        value = value.to_i.clamp(-99, 999)
        str = value.abs.to_s.rjust(digits, ' ')

        # Draw from right to left
        offset = 0
        str.reverse.each_char do |char|
          digit_sprite = nil
          if char == ' '
            offset += 14  # Number width
            next
          elsif char == '-'
            digit_sprite = @gfx.numbers['-']
          else
            digit_sprite = @gfx.numbers[char.to_i]
          end

          if digit_sprite
            draw_x = x + (digits * 14) - offset - digit_sprite.width
            draw_sprite(framebuffer, digit_sprite, draw_x, y)
            offset += 14
          end
        end

        # Draw minus sign if negative
        if value < 0
          minus = @gfx.numbers['-']
          draw_sprite(framebuffer, minus, x - 14, y) if minus
        end
      end

      def draw_percent(framebuffer, x, y)
        percent = @gfx.numbers['%']
        draw_sprite(framebuffer, percent, x, y) if percent
      end

      def draw_face(framebuffer)
        health_level = @player.health_level
        faces = @gfx.faces[health_level]
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

        # Center face in its area
        face_x = FACE_X - face.width / 2
        face_y = STATUS_BAR_Y + 3
        draw_sprite(framebuffer, face, face_x, face_y)
      end

      def draw_keys(framebuffer)
        key_y = STATUS_BAR_Y + 3
        key_spacing = 10

        # Blue keys (top row)
        if @player.keys[:blue_card]
          sprite = @gfx.keys[:blue_card]
          draw_sprite(framebuffer, sprite, KEYS_X, key_y) if sprite
        elsif @player.keys[:blue_skull]
          sprite = @gfx.keys[:blue_skull]
          draw_sprite(framebuffer, sprite, KEYS_X, key_y) if sprite
        end

        # Yellow keys (middle row)
        if @player.keys[:yellow_card]
          sprite = @gfx.keys[:yellow_card]
          draw_sprite(framebuffer, sprite, KEYS_X, key_y + key_spacing) if sprite
        elsif @player.keys[:yellow_skull]
          sprite = @gfx.keys[:yellow_skull]
          draw_sprite(framebuffer, sprite, KEYS_X, key_y + key_spacing) if sprite
        end

        # Red keys (bottom row)
        if @player.keys[:red_card]
          sprite = @gfx.keys[:red_card]
          draw_sprite(framebuffer, sprite, KEYS_X, key_y + key_spacing * 2) if sprite
        elsif @player.keys[:red_skull]
          sprite = @gfx.keys[:red_skull]
          draw_sprite(framebuffer, sprite, KEYS_X, key_y + key_spacing * 2) if sprite
        end
      end

      def draw_arms(framebuffer)
        # Arms area shows which weapons player has (2-7, fist/pistol not shown)
        # This is simplified - original has a more complex layout
        # For now just skip this as it requires additional graphics
      end
    end
  end
end
