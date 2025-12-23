# frozen_string_literal: true

module Doom
  module Wad
    # Loads HUD graphics (status bar, weapons) from WAD
    class HudGraphics
      attr_reader :status_bar, :numbers, :weapons, :faces, :keys

      def initialize(wad)
        @wad = wad
        @cache = {}

        load_status_bar
        load_numbers
        load_weapons
        load_faces
        load_keys
      end

      # Get a cached graphic by name
      def [](name)
        @cache[name]
      end

      private

      def load_graphic(name)
        return @cache[name] if @cache[name]

        entry = @wad.find_lump(name)
        return nil unless entry

        data = @wad.read_lump_at(entry)
        return nil unless data && data.size > 8

        sprite = parse_patch(name, data)
        @cache[name] = sprite
        sprite
      end

      def parse_patch(name, data)
        width = data[0, 2].unpack1('v')
        height = data[2, 2].unpack1('v')
        left_offset = data[4, 2].unpack1('s<')
        top_offset = data[6, 2].unpack1('s<')

        # Read column offsets
        column_offsets = width.times.map do |i|
          data[8 + i * 4, 4].unpack1('V')
        end

        # Build column data
        columns = column_offsets.map do |offset|
          read_column(data, offset, height)
        end

        HudSprite.new(name, width, height, left_offset, top_offset, columns)
      end

      def read_column(data, offset, height)
        pixels = Array.new(height)
        pos = offset

        loop do
          break if pos >= data.size
          top_delta = data[pos].ord
          break if top_delta == 0xFF

          length = data[pos + 1].ord
          # Skip padding byte, read pixels, skip end padding
          pixel_data = data[pos + 3, length]
          break unless pixel_data

          pixel_data.bytes.each_with_index do |color, i|
            y = top_delta + i
            pixels[y] = color if y < height
          end

          pos += length + 4
        end

        pixels
      end

      def load_status_bar
        @status_bar = load_graphic('STBAR')
      end

      def load_numbers
        @numbers = {}
        # Large red numbers for health/ammo
        (0..9).each do |n|
          @numbers[n] = load_graphic("STTNUM#{n}")
        end
        @numbers['-'] = load_graphic('STTMINUS')
        @numbers['%'] = load_graphic('STTPRCNT')

        # Small grey numbers for arms
        @grey_numbers = {}
        (0..9).each do |n|
          @grey_numbers[n] = load_graphic("STGNUM#{n}")
        end
      end

      def load_weapons
        @weapons = {}

        # Pistol frames (PISG = pistol gun)
        @weapons[:pistol] = {
          idle: load_graphic('PISGA0'),
          fire: [
            load_graphic('PISGB0'),
            load_graphic('PISGC0'),
            load_graphic('PISGD0'),
            load_graphic('PISGE0')
          ].compact,
          flash: [
            load_graphic('PISFA0'),
            load_graphic('PISFB0')
          ].compact
        }

        # Fist frames (PUNG = punch)
        @weapons[:fist] = {
          idle: load_graphic('PUNGA0'),
          fire: [
            load_graphic('PUNGB0'),
            load_graphic('PUNGC0'),
            load_graphic('PUNGD0')
          ].compact
        }
      end

      def load_faces
        @faces = {}

        # Straight ahead faces at different health levels
        # STF = status face, ST = straight, 0-4 = health level (4=full, 0=dying)
        (0..4).each do |health_level|
          @faces[health_level] = {
            straight: [
              load_graphic("STFST#{health_level}0"),
              load_graphic("STFST#{health_level}1"),
              load_graphic("STFST#{health_level}2")
            ].compact,
            left: load_graphic("STFTL#{health_level}0"),
            right: load_graphic("STFTR#{health_level}0"),
            ouch: load_graphic("STFOUCH#{health_level}"),
            evil: load_graphic("STFEVL#{health_level}"),
            kill: load_graphic("STFKILL#{health_level}")
          }
        end

        # Special faces
        @faces[:dead] = load_graphic('STFDEAD0')
        @faces[:god] = load_graphic('STFGOD0')
      end

      def load_keys
        @keys = {
          blue_card: load_graphic('STKEYS0'),
          yellow_card: load_graphic('STKEYS1'),
          red_card: load_graphic('STKEYS2'),
          blue_skull: load_graphic('STKEYS3'),
          yellow_skull: load_graphic('STKEYS4'),
          red_skull: load_graphic('STKEYS5')
        }
      end
    end

    # Simple sprite container for HUD graphics
    class HudSprite
      attr_reader :name, :width, :height, :left_offset, :top_offset, :columns

      def initialize(name, width, height, left_offset, top_offset, columns)
        @name = name
        @width = width
        @height = height
        @left_offset = left_offset
        @top_offset = top_offset
        @columns = columns
      end

      def column_pixels(x)
        @columns[x % @width]
      end
    end
  end
end
