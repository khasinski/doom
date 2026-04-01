# frozen_string_literal: true

module Doom
  module Render
    # DOOM's screen melt/wipe effect from wipe.c.
    # Each column slides down at a slightly different speed,
    # revealing the new screen underneath.
    class ScreenMelt
      WIDTH = SCREEN_WIDTH
      HEIGHT = SCREEN_HEIGHT
      MELT_SPEED = HEIGHT / 15  # ~16 pixels per tic (matching Chocolate Doom)

      def initialize(old_screen, new_screen)
        # Snapshot both screens (arrays of palette indices, 320x240)
        @old = old_screen.dup
        @new = new_screen.dup
        @done = false

        # Initialize column offsets (from wipe_initMelt in wipe.c)
        # Column 0 gets random negative offset, each subsequent column
        # varies by -1/0/+1 from previous, creating a jagged melt line
        @y = Array.new(WIDTH)
        @y[0] = -(rand(16))
        (1...WIDTH).each do |i|
          @y[i] = @y[i - 1] + (rand(3) - 1)
          @y[i] = -15 if @y[i] < -15
          @y[i] = 0 if @y[i] > 0
        end
      end

      def done?
        @done
      end

      # Advance one tic. Returns the composited framebuffer.
      def update(framebuffer)
        all_done = true

        WIDTH.times do |x|
          if @y[x] < 0
            @y[x] += 1
            all_done = false
            # Column hasn't started melting yet - show old screen
            HEIGHT.times { |row| framebuffer[row * WIDTH + x] = @old[row * WIDTH + x] }
          elsif @y[x] < HEIGHT
            all_done = false
            dy = @y[x]

            # Top part: new screen revealed
            dy.times do |row|
              framebuffer[row * WIDTH + x] = @new[row * WIDTH + x]
            end

            # Bottom part: old screen shifted down
            (dy...HEIGHT).each do |row|
              src_row = row - dy
              framebuffer[row * WIDTH + x] = @old[src_row * WIDTH + x]
            end

            @y[x] += MELT_SPEED
          else
            # Column fully melted - show new screen
            HEIGHT.times { |row| framebuffer[row * WIDTH + x] = @new[row * WIDTH + x] }
          end
        end

        @done = all_done
      end
    end
  end
end
