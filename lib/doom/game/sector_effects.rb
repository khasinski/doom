# frozen_string_literal: true

module Doom
  module Game
    # Sector light specials and scrolling walls, matching Chocolate Doom's
    # P_SpawnSpecials (p_spec.c) and p_lights.c.
    class SectorEffects
      GLOWSPEED    = 8   # Light units per tic for glow
      STROBEBRIGHT = 5   # Bright duration for strobes (tics)
      FASTDARK     = 15  # Dark duration for fast strobe (tics)
      SLOWDARK     = 35  # Dark duration for slow strobe (tics)

      def initialize(map)
        @map = map
        @effects = []
        @scroll_sides = []
        spawn_specials
      end

      # Called every game tic (35/sec)
      def update
        @effects.each(&:update)
        @scroll_sides.each { |side| side.x_offset += 1 }
      end

      private

      def spawn_specials
        @map.sectors.each do |sector|
          case sector.special
          when 1      # Flickering lights
            @effects << LightFlash.new(sector, find_min_light(sector))
          when 2      # Fast strobe
            @effects << StrobeFlash.new(sector, find_min_light(sector), FASTDARK, false)
          when 3      # Slow strobe
            @effects << StrobeFlash.new(sector, find_min_light(sector), SLOWDARK, false)
          when 4      # Fast strobe + 20% damage
            @effects << StrobeFlash.new(sector, find_min_light(sector), FASTDARK, false)
          when 8      # Glowing light
            @effects << Glow.new(sector, find_min_light(sector))
          when 12     # Sync strobe slow
            @effects << StrobeFlash.new(sector, find_min_light(sector), SLOWDARK, true)
          when 13     # Sync strobe fast
            @effects << StrobeFlash.new(sector, find_min_light(sector), FASTDARK, true)
          when 17     # Fire flicker
            @effects << FireFlicker.new(sector, find_min_light(sector))
          end
        end

        # Linedef type 48: scrolling wall (front side scrolls +1 unit/tic)
        @map.linedefs.each do |linedef|
          next unless linedef.special == 48
          side = @map.sidedefs[linedef.sidedef_right]
          @scroll_sides << side if side
        end
      end

      # P_FindMinSurroundingLight: find lowest light level among adjacent sectors
      def find_min_light(sector)
        min = sector.light_level
        sector_idx = @map.sectors.index(sector)
        return min unless sector_idx

        @map.linedefs.each do |ld|
          right = @map.sidedefs[ld.sidedef_right]
          next unless right
          left_idx = ld.sidedef_left
          next if left_idx >= 0xFFFF
          left = @map.sidedefs[left_idx]
          next unless left

          if right.sector == sector_idx && left.sector != sector_idx
            other_light = @map.sectors[left.sector].light_level
            min = other_light if other_light < min
          elsif left.sector == sector_idx && right.sector != sector_idx
            other_light = @map.sectors[right.sector].light_level
            min = other_light if other_light < min
          end
        end
        min
      end

      # T_LightFlash (type 1): mostly bright with brief random dark flickers
      class LightFlash
        def initialize(sector, minlight)
          @sector = sector
          @maxlight = sector.light_level
          @minlight = minlight
          @count = (rand(65)) + 1
        end

        def update
          @count -= 1
          return if @count > 0

          if @sector.light_level == @maxlight
            @sector.light_level = @minlight
            @count = (rand(8)) + 1       # dark for 1-8 tics
          else
            @sector.light_level = @maxlight
            @count = (rand(2) == 0 ? 1 : 65)  # bright for 1 or 65 tics (P_Random()&64)
          end
        end
      end

      # T_StrobeFlash (types 2, 3, 4, 12, 13): regular strobe blink
      class StrobeFlash
        def initialize(sector, minlight, darktime, in_sync)
          @sector = sector
          @maxlight = sector.light_level
          @minlight = minlight
          @minlight = 0 if @minlight == @maxlight
          @darktime = darktime
          @brighttime = STROBEBRIGHT
          @count = in_sync ? 1 : (rand(8)) + 1
        end

        def update
          @count -= 1
          return if @count > 0

          if @sector.light_level == @minlight
            @sector.light_level = @maxlight
            @count = @brighttime
          else
            @sector.light_level = @minlight
            @count = @darktime
          end
        end
      end

      # T_Glow (type 8): smooth triangle-wave oscillation
      class Glow
        def initialize(sector, minlight)
          @sector = sector
          @maxlight = sector.light_level
          @minlight = minlight
          @direction = -1  # start dimming
        end

        def update
          if @direction == -1
            @sector.light_level -= GLOWSPEED
            if @sector.light_level <= @minlight
              @sector.light_level += GLOWSPEED
              @direction = 1
            end
          else
            @sector.light_level += GLOWSPEED
            if @sector.light_level >= @maxlight
              @sector.light_level -= GLOWSPEED
              @direction = -1
            end
          end
        end
      end

      # T_FireFlicker (type 17): random fire-like flickering
      class FireFlicker
        def initialize(sector, minlight)
          @sector = sector
          @maxlight = sector.light_level
          @minlight = minlight + 16  # fire doesn't go as dark
          @count = 4
        end

        def update
          @count -= 1
          return if @count > 0

          amount = (rand(4)) * 16  # 0, 16, 32, or 48
          level = @maxlight - amount
          @sector.light_level = level < @minlight ? @minlight : level
          @count = 4
        end
      end
    end
  end
end
