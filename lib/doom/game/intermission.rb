# frozen_string_literal: true

module Doom
  module Game
    # Intermission screen shown between levels.
    # Displays kill%, item%, secret%, time, and par time.
    class Intermission
      # Episode 1 par times in seconds (from Chocolate Doom)
      PAR_TIMES = {
        'E1M1' => 30, 'E1M2' => 75, 'E1M3' => 120, 'E1M4' => 90,
        'E1M5' => 165, 'E1M6' => 180, 'E1M7' => 180, 'E1M8' => 30, 'E1M9' => 165,
      }.freeze

      # Next map progression
      NEXT_MAP = {
        'E1M1' => 'E1M2', 'E1M2' => 'E1M3', 'E1M3' => 'E1M4', 'E1M4' => 'E1M5',
        'E1M5' => 'E1M6', 'E1M6' => 'E1M7', 'E1M7' => 'E1M8', 'E1M8' => nil,
        'E1M9' => 'E1M4',
      }.freeze

      # Counter animation speed (percentage points per tic)
      COUNT_SPEED = 2
      TICS_PER_COUNT = 1

      attr_reader :finished, :next_map

      def initialize(wad, hud_graphics, stats)
        @wad = wad
        @gfx = hud_graphics
        @stats = stats  # { map:, kills:, total_kills:, items:, total_items:, secrets:, total_secrets:, time_tics: }
        @finished = false
        @next_map = NEXT_MAP[stats[:map]]
        @tic = 0

        # Animated counters (count up from 0 to actual value)
        @kill_count = 0
        @item_count = 0
        @secret_count = 0
        @time_count = 0
        @counting_done = false

        # Target percentages
        @kill_pct = @stats[:total_kills] > 0 ? (@stats[:kills] * 100 / @stats[:total_kills]) : 100
        @item_pct = @stats[:total_items] > 0 ? (@stats[:items] * 100 / @stats[:total_items]) : 100
        @secret_pct = @stats[:total_secrets] > 0 ? (@stats[:secrets] * 100 / @stats[:total_secrets]) : 100
        @time_secs = @stats[:time_tics] / 35

        @par_time = PAR_TIMES[stats[:map]] || 0

        load_graphics
      end

      def update
        @tic += 1
        return if @counting_done

        # Animate counters
        if @kill_count < @kill_pct
          @kill_count = [@kill_count + COUNT_SPEED, @kill_pct].min
        elsif @item_count < @item_pct
          @item_count = [@item_count + COUNT_SPEED, @item_pct].min
        elsif @secret_count < @secret_pct
          @secret_count = [@secret_count + COUNT_SPEED, @secret_pct].min
        elsif @time_count < @time_secs
          @time_count = [@time_count + 3, @time_secs].min
        else
          @counting_done = true
        end
      end

      def render(framebuffer)
        # Background
        draw_background(framebuffer)

        # "Finished" text + level name
        draw_sprite(framebuffer, @wifinish, 64, 4) if @wifinish
        level_idx = map_to_level_index(@stats[:map])
        lv = @level_names[level_idx]
        draw_sprite(framebuffer, lv, (320 - (lv&.width || 0)) / 2, 24) if lv

        # Kill, Item, Secret percentages
        y = 60
        draw_sprite(framebuffer, @wiostk, 50, y) if @wiostk
        draw_percent(framebuffer, 260, y, @kill_count)

        y += 24
        draw_sprite(framebuffer, @wiosti, 50, y) if @wiosti
        draw_percent(framebuffer, 260, y, @item_count)

        y += 24
        draw_sprite(framebuffer, @wiosts, 50, y) if @wiosts
        draw_percent(framebuffer, 260, y, @secret_count)

        # Time
        y += 30
        draw_sprite(framebuffer, @witime, 16, y) if @witime
        draw_time(framebuffer, 160, y, @time_count)

        # Par time
        draw_sprite(framebuffer, @wipar, 176, y) if @wipar
        draw_time(framebuffer, 292, y, @par_time)

        # "Entering" next level (after counting done)
        if @counting_done && @next_map
          y += 30
          draw_sprite(framebuffer, @wienter, 64, y) if @wienter
          next_idx = map_to_level_index(@next_map)
          nlv = @level_names[next_idx]
          draw_sprite(framebuffer, nlv, (320 - (nlv&.width || 0)) / 2, y + 18) if nlv
        end

        # "Press any key" hint after counting
        if @counting_done && (@tic / 17) % 2 == 0
          # Blink hint via skull
          skull = @skulls[@tic / 8 % 2]
          draw_sprite(framebuffer, skull, 144, 210) if skull
        end
      end

      def handle_key
        if @counting_done
          @finished = true
        else
          # Skip counting animation
          @kill_count = @kill_pct
          @item_count = @item_pct
          @secret_count = @secret_pct
          @time_count = @time_secs
          @counting_done = true
        end
      end

      private

      def map_to_level_index(map_name)
        return 0 unless map_name
        map_name[3].to_i - 1  # E1M1 -> 0, E1M2 -> 1, etc.
      end

      def load_graphics
        # Intermission number digits
        @nums = (0..9).map { |n| load_patch("WINUM#{n}") }
        @percent = load_patch('WIPCNT')
        @colon = load_patch('WICOLON')
        @minus = load_patch('WIMINUS')

        # Labels
        @wiostk = load_patch('WIOSTK')   # "Kills"
        @wiosti = load_patch('WIOSTI')   # "Items"
        @wiosts = load_patch('WIOSTS')   # "Scrt" (Secrets)
        @witime = load_patch('WITIME')   # "Time"
        @wipar = load_patch('WIPAR')     # "Par"
        @wifinish = load_patch('WIF')    # "Finished"
        @wienter = load_patch('WIENTER') # "Entering"

        # Map background
        @wimap = load_patch('WIMAP0')

        # Level names (WILV00-WILV08)
        @level_names = (0..8).map { |n| load_patch("WILV0#{n}") }

        # Skull cursor
        @skulls = [load_patch('M_SKULL1'), load_patch('M_SKULL2')]
      end

      def load_patch(name)
        @gfx.send(:load_graphic, name)
      end

      def draw_background(framebuffer)
        return unless @wimap
        draw_fullscreen(framebuffer, @wimap)
      end

      def draw_fullscreen(framebuffer, sprite)
        return unless sprite
        y_offset = (240 - sprite.height) / 2
        y_offset = [y_offset, 0].max
        sprite.width.times do |x|
          next if x >= 320
          col = sprite.column_pixels(x)
          next unless col
          col.each_with_index do |color, y|
            next unless color
            sy = y + y_offset
            next if sy < 0 || sy >= 240
            framebuffer[sy * 320 + x] = color
          end
        end
      end

      def draw_percent(framebuffer, right_x, y, value)
        # Draw percent sign
        draw_sprite(framebuffer, @percent, right_x, y) if @percent

        # Draw number right-aligned before percent
        draw_num_right(framebuffer, right_x - 2, y, value)
      end

      def draw_time(framebuffer, right_x, y, seconds)
        mins = seconds / 60
        secs = seconds % 60

        # Draw seconds (2 digits, zero-padded)
        draw_num_right(framebuffer, right_x, y, secs, pad: 2)

        # Colon
        colon_x = right_x - num_width * 2 - 4
        draw_sprite(framebuffer, @colon, colon_x, y) if @colon

        # Minutes
        draw_num_right(framebuffer, colon_x - 2, y, mins)
      end

      def num_width
        @nums[0]&.width || 14
      end

      def draw_num_right(framebuffer, right_x, y, value, pad: 0)
        w = num_width
        str = value.to_i.to_s
        str = str.rjust(pad, '0') if pad > 0
        x = right_x
        str.reverse.each_char do |ch|
          x -= w
          digit = @nums[ch.to_i]
          draw_sprite(framebuffer, digit, x, y) if digit
        end
      end

      def draw_sprite(framebuffer, sprite, x, y)
        return unless sprite
        sprite.width.times do |col_x|
          sx = x + col_x
          next if sx < 0 || sx >= 320
          col = sprite.column_pixels(col_x)
          next unless col
          col.each_with_index do |color, col_y|
            next unless color
            sy = y + col_y
            next if sy < 0 || sy >= 240
            framebuffer[sy * 320 + sx] = color
          end
        end
      end
    end
  end
end
