# frozen_string_literal: true

module Doom
  module Wad
    class Flat
      WIDTH = 64
      HEIGHT = 64
      SIZE = WIDTH * HEIGHT

      attr_reader :name, :pixels

      def width
        WIDTH
      end

      def height
        HEIGHT
      end

      def initialize(name, pixels)
        @name = name
        @pixels = pixels
      end

      def [](x, y)
        @pixels[(y & 63) * WIDTH + (x & 63)]
      end

      def self.load_all(wad)
        entries = wad.lumps_between('F_START', 'F_END')
        entries.map do |entry|
          next if entry.size != SIZE

          data = wad.read_lump_at(entry)
          new(entry.name, data.bytes)
        end.compact
      end
    end
  end
end
