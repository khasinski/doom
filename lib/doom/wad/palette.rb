# frozen_string_literal: true

module Doom
  module Wad
    class Palette
      COLORS = 256
      PALETTES = 14
      PALETTE_SIZE = COLORS * 3

      attr_reader :colors

      def initialize(colors)
        @colors = colors
      end

      def [](index)
        @colors[index]
      end

      def self.load(wad, palette_index = 0)
        data = wad.read_lump('PLAYPAL')
        raise Error, 'PLAYPAL lump not found' unless data

        offset = palette_index * PALETTE_SIZE
        colors = COLORS.times.map do |i|
          [
            data[offset + i * 3].ord,
            data[offset + i * 3 + 1].ord,
            data[offset + i * 3 + 2].ord
          ]
        end

        new(colors)
      end
    end
  end
end
