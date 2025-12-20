# frozen_string_literal: true

module Doom
  module Wad
    class Sprite
      attr_reader :name, :width, :height, :left_offset, :top_offset

      def initialize(name, width, height, left_offset, top_offset, columns)
        @name = name
        @width = width
        @height = height
        @left_offset = left_offset
        @top_offset = top_offset
        @columns = columns
      end

      def column_pixels(x)
        @columns[x] || []
      end

      # Load a sprite from a WAD patch lump
      def self.load(wad, lump_name)
        entry = wad.directory.find { |e| e.name == lump_name }
        return nil unless entry

        data = wad.read_lump_at(entry)
        return nil if data.size < 8

        width = data[0, 2].unpack1('v')
        height = data[2, 2].unpack1('v')
        left_offset = data[4, 2].unpack1('s<')
        top_offset = data[6, 2].unpack1('s<')

        # Read column offsets
        column_offsets = []
        width.times do |i|
          column_offsets << data[8 + i * 4, 4].unpack1('V')
        end

        # Read columns
        columns = []
        width.times do |x|
          column = Array.new(height, nil)  # nil = transparent
          offset = column_offsets[x]

          # Read posts for this column
          loop do
            break if offset >= data.size
            row_start = data[offset].ord
            break if row_start == 255  # End of column marker

            post_height = data[offset + 1].ord
            break if post_height == 0 || offset + 3 + post_height > data.size

            # Skip padding byte, read pixels, skip trailing padding
            post_height.times do |i|
              y = row_start + i
              if y < height
                column[y] = data[offset + 3 + i].ord
              end
            end

            offset += post_height + 4  # row_start + count + padding + pixels + padding
          end

          columns << column
        end

        new(lump_name, width, height, left_offset, top_offset, columns)
      end
    end

    class SpriteManager
      # Map thing types to sprite prefixes
      THING_SPRITES = {
        # Ammo
        2007 => 'CLIP', # Clip
        2048 => 'AMMO', # Box of ammo
        2008 => 'SHEL', # Shells
        2049 => 'SBOX', # Box of shells
        2010 => 'ROCK', # Rocket
        2046 => 'BROK', # Box of rockets
        2047 => 'CELL', # Cell charge
        17 => 'CELP',   # Cell pack

        # Weapons
        2001 => 'SHOT', # Shotgun
        2002 => 'MGUN', # Chaingun
        2003 => 'LAUN', # Rocket launcher
        2004 => 'PLAS', # Plasma rifle
        2006 => 'BFUG', # BFG 9000
        2005 => 'CSAW', # Chainsaw

        # Health/Armor
        2011 => 'STIM', # Stimpack
        2012 => 'MEDI', # Medikit
        2014 => 'BON1', # Health bonus
        2015 => 'BON2', # Armor bonus
        2018 => 'ARM1', # Green armor
        2019 => 'ARM2', # Blue armor

        # Keys
        5 => 'BKEY',    # Blue keycard
        6 => 'YKEY',    # Yellow keycard
        13 => 'RKEY',   # Red keycard
        40 => 'BSKU',   # Blue skull
        39 => 'YSKU',   # Yellow skull
        38 => 'RSKU',   # Red skull

        # Decorations
        2028 => 'COLU', # Light column
        30 => 'COL1',   # Tall green pillar
        31 => 'COL2',   # Short green pillar
        32 => 'COL3',   # Tall red pillar
        33 => 'COL4',   # Short red pillar
        34 => 'CAND',   # Candle
        44 => 'TBLU',   # Tall blue torch
        45 => 'TGRN',   # Tall green torch
        46 => 'TRED',   # Tall red torch
        48 => 'ELEC',   # Tall tech column
        35 => 'CBRA',   # Candelabra

        # Barrels
        2035 => 'BAR1', # Exploding barrel

        # Monsters
        3004 => 'POSS', # Zombieman
        9 => 'SPOS',    # Shotgun guy
        3001 => 'TROO', # Imp
        3002 => 'SARG', # Demon
        58 => 'SARG',   # Spectre (same as Demon)
        3003 => 'BOSS', # Baron of Hell
        3005 => 'HEAD', # Cacodemon
        3006 => 'SKUL', # Lost soul
        7 => 'SPID',    # Spider Mastermind
        16 => 'CYBR',   # Cyberdemon
      }.freeze

      def initialize(wad)
        @wad = wad
        @cache = {}
        @rotation_cache = {}
      end

      # Get default sprite (rotation 0 or 1)
      def [](thing_type)
        return @cache[thing_type] if @cache.key?(thing_type)

        prefix = THING_SPRITES[thing_type]
        return nil unless prefix

        # Try to find sprite with A0 (all angles) or A1 (front facing)
        sprite = Sprite.load(@wad, "#{prefix}A0") ||
                 Sprite.load(@wad, "#{prefix}A1")

        @cache[thing_type] = sprite
        sprite
      end

      # Get sprite prefix for a thing type
      def prefix_for(thing_type)
        THING_SPRITES[thing_type]
      end

      # Get sprite for specific rotation (1-8, or 0 for all angles)
      # viewer_angle: angle from viewer to sprite in radians
      # thing_angle: thing's facing angle in degrees
      def get_rotated(thing_type, viewer_angle, thing_angle)
        prefix = THING_SPRITES[thing_type]
        return nil unless prefix

        # Check cache for rotation 0 (all angles) sprite
        cache_key = "#{prefix}A0"
        if @rotation_cache.key?(cache_key)
          return @rotation_cache[cache_key] if @rotation_cache[cache_key]
        else
          sprite = Sprite.load(@wad, cache_key)
          @rotation_cache[cache_key] = sprite
          return sprite if sprite
        end

        # Calculate rotation frame (1-8)
        # Doom rotations: 1=front, 2=front-right, 3=right, etc. (clockwise)
        # The angle we need is: viewer's angle to sprite - sprite's facing angle
        angle_diff = viewer_angle - (thing_angle * Math::PI / 180.0)

        # Normalize to 0-2π
        angle_diff = angle_diff % (2 * Math::PI)
        angle_diff += 2 * Math::PI if angle_diff < 0

        # Convert to rotation frame (1-8)
        # Each rotation covers 45 degrees (π/4 radians)
        # Add π/8 to center the ranges
        rotation = ((angle_diff + Math::PI / 8) / (Math::PI / 4)).to_i % 8 + 1

        cache_key = "#{prefix}A#{rotation}"
        unless @rotation_cache.key?(cache_key)
          @rotation_cache[cache_key] = Sprite.load(@wad, cache_key)
        end

        @rotation_cache[cache_key] || @cache[thing_type]
      end
    end
  end
end
