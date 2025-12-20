# frozen_string_literal: true

require 'gosu'

module Doom
  module Platform
    class GosuWindow < Gosu::Window
      SCALE = 3

      def initialize(renderer, palette)
        super(Render::SCREEN_WIDTH * SCALE, Render::SCREEN_HEIGHT * SCALE, false)
        self.caption = 'Doom Ruby'

        @renderer = renderer
        @palette = palette
        @screen_image = nil
      end

      def update
        @renderer.render_frame
      end

      def draw
        rgba = @renderer.framebuffer.flat_map do |color_idx|
          r, g, b = @palette[color_idx]
          [r, g, b, 255]
        end.pack('C*')

        @screen_image = Gosu::Image.from_blob(
          Render::SCREEN_WIDTH,
          Render::SCREEN_HEIGHT,
          rgba
        )

        @screen_image.draw(0, 0, 0, SCALE, SCALE)
      end

      def button_down(id)
        close if id == Gosu::KB_ESCAPE
      end
    end
  end
end
