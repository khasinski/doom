# frozen_string_literal: true

module Doom
  module Game
    # Shared framebuffer blitting for the full-screen menu and intermission
    # screens. Both draw palette-index sprites into a flat 320x240 framebuffer,
    # so the clipping loop lived duplicated in each. It lives here once and uses
    # the renderer's screen constants instead of hardcoded 320/240.
    #
    # A "sprite" here is anything exposing #width and #column_pixels(x), where a
    # column is an array of palette indices (nil = transparent).
    module FramebufferBlitter
      # Blit a sprite's opaque pixels at (x, y), clipping to the screen.
      def blit_sprite(framebuffer, sprite, x, y)
        return unless sprite

        w = Render::SCREEN_WIDTH
        h = Render::SCREEN_HEIGHT
        sprite.width.times do |col_x|
          sx = x + col_x
          next if sx < 0 || sx >= w

          col = sprite.column_pixels(col_x)
          next unless col

          col.each_with_index do |color, col_y|
            next unless color

            sy = y + col_y
            next if sy < 0 || sy >= h

            framebuffer[sy * w + sx] = color
          end
        end
      end
    end
  end
end
