# frozen_string_literal: true

module Doom
  module Render
    module RayTracing
      # Packs palette-indexed flats and composite wall textures into one RGBA
      # texture. Rectangle entries are [x, y, width, height, texel_w, texel_h].
      class TextureAtlas
        attr_reader :size

        def initialize(size:, textures:, flats:, palette:)
          @size = size
          @textures = textures
          @flats = flats
          @palette = palette
        end

        def build(material_names)
          pixels = "\0" * (@size * @size * 4)
          rectangles = {}
          x = y = row_height = 0
          material_names.uniq.each do |name|
            source = source_for(name)
            next unless source

            width, height, rgba = source
            if x + width > @size
              x = 0
              y += row_height
              row_height = 0
            end
            raise ArgumentError, 'ray texture atlas overflow' if y + height > @size

            height.times do |row|
              destination = ((y + row) * @size + x) * 4
              pixels[destination, width * 4] = rgba.byteslice(row * width * 4, width * 4)
            end
            rectangles[name] = [x.to_f / @size, y.to_f / @size,
                                width.to_f / @size, height.to_f / @size,
                                width.to_f, height.to_f]
            x += width
            row_height = [row_height, height].max
          end
          [pixels, rectangles]
        end

        private

        def source_for(name)
          source = @flats[name] || @textures[name]
          return unless source

          width = source.width
          height = source.height
          indices = if source.respond_to?(:column_pixels)
                      columns_to_rows(source, width, height)
                    else
                      source.pixels
                    end
          rgba = indices.map do |index|
            index.nil? ? "\0\0\0\0" : [*@palette.colors[index], 255].pack('C4')
          end.join
          [width, height, rgba]
        end

        def columns_to_rows(source, width, height)
          pixels = Array.new(width * height)
          width.times do |column|
            source.column_pixels(column).each_with_index do |value, row|
              pixels[row * width + column] = value if row < height
            end
          end
          pixels
        end
      end
    end
  end
end
