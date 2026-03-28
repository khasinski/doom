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

        # Dead bodies / gore decorations
        10 => 'PLAY',   # Bloody mess
        12 => 'PLAY',   # Bloody mess 2
        15 => 'PLAY',   # Dead player
        24 => 'POL5',   # Pool of blood and flesh

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

      # Things that use a specific frame instead of 'A'
      # From DOOM info.h mobjinfo spawnstate:
      # MT_MISC10 (type 10) -> S_PLAY_XDIE9 = PLAY W (gibbed mess)
      # MT_MISC12 (type 12) -> S_PLAY_DIE7 = PLAY N (dead body)
      # MT_MISC15 (type 15) -> S_PLAY_DIE7 = PLAY N (dead body)
      THING_DEFAULT_FRAME = {
        10 => 'W',   # Bloody mess (gibbed)
        12 => 'N',   # Bloody mess 2 (dead body flat)
        15 => 'N',   # Dead player (dead body flat)
      }.freeze

      def initialize(wad)
        @wad = wad
        @cache = {}
        @rotation_cache = {}

        # Build sprite lump index: maps "PREFIXframe_rotation" -> [lump_name, mirrored?]
        # Handles combined lumps like SPOSA2A8 (rotation 2 normal, rotation 8 mirrored)
        @sprite_index = {}
        build_sprite_index
      end

      # Get default sprite (rotation 0 or 1)
      def [](thing_type)
        return @cache[thing_type] if @cache.key?(thing_type)

        prefix = THING_SPRITES[thing_type]
        return nil unless prefix

        frame = THING_DEFAULT_FRAME[thing_type] || 'A'
        sprite = load_sprite_frame(prefix, frame, 0) ||
                 load_sprite_frame(prefix, frame, 1)

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

        frame = THING_DEFAULT_FRAME[thing_type] || 'A'

        # Check for rotation 0 (all angles) sprite first
        sprite = load_sprite_frame(prefix, frame, 0)
        return sprite if sprite

        # Calculate rotation frame (1-8)
        # DOOM: rot = (R_PointToAngle(thing) - thing->angle + ANG45/2*9) >> 29
        # Rotation 1=front (viewer faces monster's front), 5=back
        angle_diff = viewer_angle - (thing_angle * Math::PI / 180.0) + Math::PI
        angle_diff = angle_diff % (2 * Math::PI)
        angle_diff += 2 * Math::PI if angle_diff < 0
        rotation = ((angle_diff + Math::PI / 8) / (Math::PI / 4)).to_i % 8 + 1

        load_sprite_frame(prefix, frame, rotation) || @cache[thing_type]
      end

      # Get a specific frame (for death animations, etc.)
      def get_frame(thing_type, frame_letter, viewer_angle, thing_angle)
        prefix = THING_SPRITES[thing_type]
        return nil unless prefix

        # Death frames typically use rotation 0 (same from all angles)
        sprite = load_sprite_frame(prefix, frame_letter, 0)
        return sprite if sprite

        # Try with calculated rotation (same formula as get_rotated)
        angle_diff = viewer_angle - (thing_angle * Math::PI / 180.0) + Math::PI
        angle_diff = angle_diff % (2 * Math::PI)
        angle_diff += 2 * Math::PI if angle_diff < 0
        rotation = ((angle_diff + Math::PI / 8) / (Math::PI / 4)).to_i % 8 + 1

        load_sprite_frame(prefix, frame_letter, rotation)
      end

      # Get a frame by explicit prefix (for barrel explosions where prefix differs from thing type)
      def get_frame_by_prefix(prefix, frame_letter)
        load_sprite_frame(prefix, frame_letter, 0)
      end

      private

      def build_sprite_index
        @wad.directory.each do |entry|
          name = entry.name
          next if name.length < 6

          prefix = name[0, 4]
          frame1 = name[4]
          rot1 = name[5].to_i

          # Register first frame+rotation
          key = "#{prefix}#{frame1}#{rot1}"
          @sprite_index[key] = [name, false]

          # Check for mirrored second rotation (e.g., SPOSA2A8)
          if name.length >= 8
            frame2 = name[6]
            rot2 = name[7].to_i
            key2 = "#{prefix}#{frame2}#{rot2}"
            @sprite_index[key2] = [name, true]
          end
        end
      end

      def load_sprite_frame(prefix, frame, rotation)
        key = "#{prefix}#{frame}#{rotation}"
        return @rotation_cache[key] if @rotation_cache.key?(key)

        index_entry = @sprite_index[key]
        unless index_entry
          @rotation_cache[key] = nil
          return nil
        end

        lump_name, mirrored = index_entry
        # Load the base sprite (may be shared by mirrored pair)
        base = load_or_cache_lump(lump_name)
        unless base
          @rotation_cache[key] = nil
          return nil
        end

        sprite = mirrored ? mirror_sprite(base) : base
        @rotation_cache[key] = sprite
        sprite
      end

      def load_or_cache_lump(lump_name)
        cache_key = "_lump_#{lump_name}"
        return @rotation_cache[cache_key] if @rotation_cache.key?(cache_key)

        sprite = Sprite.load(@wad, lump_name)
        @rotation_cache[cache_key] = sprite
        sprite
      end

      def mirror_sprite(sprite)
        # Flip columns horizontally, adjust left_offset
        mirrored_columns = sprite.instance_variable_get(:@columns).reverse
        mirrored_left = sprite.width - sprite.left_offset
        Sprite.new(
          "#{sprite.name}_M",
          sprite.width, sprite.height,
          mirrored_left, sprite.top_offset,
          mirrored_columns
        )
      end
    end
  end
end
