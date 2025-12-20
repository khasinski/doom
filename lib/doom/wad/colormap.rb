# frozen_string_literal: true

module Doom
  module Wad
    class Colormap
      MAPS = 34
      MAP_SIZE = 256

      attr_reader :maps

      def initialize(maps)
        @maps = maps
      end

      def [](map_index)
        @maps[map_index]
      end

      def map_color(color_index, light_level)
        map_index = 31 - (light_level >> 3)
        map_index = map_index.clamp(0, 31)
        @maps[map_index][color_index]
      end

      def self.load(wad)
        data = wad.read_lump('COLORMAP')
        raise Error, 'COLORMAP lump not found' unless data

        maps = MAPS.times.map do |i|
          offset = i * MAP_SIZE
          data[offset, MAP_SIZE].bytes
        end

        new(maps)
      end
    end
  end
end
