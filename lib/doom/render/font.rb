# frozen_string_literal: true

module Doom
  module Render
    # DOOM's built-in font loaded from STCFN patches (ASCII 33-121).
    # Uppercase only -- lowercase is auto-uppercased.
    class Font
      SPACE_WIDTH = 4

      def initialize(wad, hud_graphics)
        @chars = {}
        (33..121).each do |ascii|
          name = "STCFN%03d" % ascii
          sprite = hud_graphics.send(:load_graphic, name)
          @chars[ascii] = sprite if sprite
        end
      end

      # Draw text into framebuffer at (x, y). Returns width drawn.
      def draw_text(framebuffer, text, x, y, screen_width: 320, screen_height: 240)
        cursor_x = x
        text.upcase.each_char do |char|
          if char == ' '
            cursor_x += SPACE_WIDTH
            next
          end

          sprite = @chars[char.ord]
          next unless sprite

          draw_char(framebuffer, sprite, cursor_x, y, screen_width, screen_height)
          cursor_x += sprite.width
        end
        cursor_x - x
      end

      # Measure text width without drawing
      def text_width(text)
        width = 0
        text.upcase.each_char do |char|
          if char == ' '
            width += SPACE_WIDTH
            next
          end
          sprite = @chars[char.ord]
          width += sprite.width if sprite
        end
        width
      end

      # Draw text centered horizontally
      def draw_centered(framebuffer, text, y, screen_width: 320, screen_height: 240)
        w = text_width(text)
        x = (screen_width - w) / 2
        draw_text(framebuffer, text, x, y, screen_width: screen_width, screen_height: screen_height)
      end

      private

      def draw_char(framebuffer, sprite, x, y, screen_width, screen_height)
        sprite.width.times do |col_x|
          sx = x + col_x
          next if sx < 0 || sx >= screen_width

          col = sprite.column_pixels(col_x)
          next unless col

          col.each_with_index do |color, col_y|
            next unless color
            sy = y + col_y
            next if sy < 0 || sy >= screen_height
            framebuffer[sy * screen_width + sx] = color
          end
        end
      end
    end
  end
end
