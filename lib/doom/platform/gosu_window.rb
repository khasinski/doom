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
        @needs_render = true

        # Pre-build palette lookup for speed
        @palette_rgba = palette.colors.map { |r, g, b| [r, g, b, 255].pack('CCCC') }
      end

      def update
        if @needs_render
          @renderer.render_frame
          @needs_render = false
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
        close if id == Gosu::KB_ESCAPE
      end
    end
  end
end
