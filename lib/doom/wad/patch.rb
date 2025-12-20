# frozen_string_literal: true

module Doom
  module Wad
    class Patch
      Post = Struct.new(:top_delta, :pixels)

      attr_reader :name, :width, :height, :left_offset, :top_offset, :columns

      def initialize(name, width, height, left_offset, top_offset, columns)
        @name = name
        @width = width
        @height = height
        @left_offset = left_offset
        @top_offset = top_offset
        @columns = columns
      end

      def self.load(wad, name)
        data = wad.read_lump(name)
        return nil unless data

        parse(name, data)
      end

      def self.parse(name, data)
        width = data[0, 2].unpack1('v')
        height = data[2, 2].unpack1('v')
        left_offset = data[4, 2].unpack1('s<')
        top_offset = data[6, 2].unpack1('s<')

        column_offsets = width.times.map do |i|
          data[8 + i * 4, 4].unpack1('V')
        end

        columns = column_offsets.map do |offset|
          read_column(data, offset)
        end

        new(name, width, height, left_offset, top_offset, columns)
      end

      def self.read_column(data, offset)
        posts = []
        pos = offset

        loop do
          top_delta = data[pos].ord
          break if top_delta == 0xFF

          length = data[pos + 1].ord
          pixels = data[pos + 3, length].bytes
          posts << Post.new(top_delta, pixels)
          pos += length + 4
        end

        posts
      end
    end
  end
end
