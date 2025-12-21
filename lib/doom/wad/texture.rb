# frozen_string_literal: true

module Doom
  module Wad
    class Texture
      PatchRef = Struct.new(:x_offset, :y_offset, :patch_index)

      attr_reader :name, :width, :height, :patch_refs

      def initialize(name, width, height, patch_refs)
        @name = name
        @width = width
        @height = height
        @patch_refs = patch_refs
      end

      def self.load_all(wad)
        pnames = load_pnames(wad)
        textures = {}

        %w[TEXTURE1 TEXTURE2].each do |lump_name|
          data = wad.read_lump(lump_name)
          next unless data

          parse_texture_lump(data).each do |tex|
            textures[tex.name] = tex
          end
        end

        { textures: textures, pnames: pnames }
      end

      def self.load_pnames(wad)
        data = wad.read_lump('PNAMES')
        return [] unless data

        count = data[0, 4].unpack1('V')
        count.times.map do |i|
          data[4 + i * 8, 8].delete("\x00").upcase
        end
      end

      def self.parse_texture_lump(data)
        num_textures = data[0, 4].unpack1('V')
        offsets = num_textures.times.map do |i|
          data[4 + i * 4, 4].unpack1('V')
        end

        offsets.map do |offset|
          parse_texture(data, offset)
        end
      end

      def self.parse_texture(data, offset)
        name = data[offset, 8].delete("\x00").upcase
        width = data[offset + 12, 2].unpack1('v')
        height = data[offset + 14, 2].unpack1('v')
        patch_count = data[offset + 20, 2].unpack1('v')

        patch_refs = patch_count.times.map do |i|
          po = offset + 22 + i * 10
          PatchRef.new(
            data[po, 2].unpack1('s<'),
            data[po + 2, 2].unpack1('s<'),
            data[po + 4, 2].unpack1('v')
          )
        end

        new(name, width, height, patch_refs)
      end
    end

    class TextureManager
      attr_reader :textures, :pnames, :patches

      def initialize(wad)
        @wad = wad
        result = Texture.load_all(wad)
        @textures = result[:textures]
        @pnames = result[:pnames]
        @patches = {}
        @composite_cache = {}
      end

      def [](name)
        return nil if name.nil? || name.empty? || name == '-'

        @composite_cache[name] ||= build_composite(name.upcase)
      end

      def get_patch(index)
        name = @pnames[index]
        return nil unless name

        @patches[name] ||= Patch.load(@wad, name)
      end

      private

      def build_composite(name)
        texture = @textures[name]
        return nil unless texture

        columns = Array.new(texture.width) { [] }

        texture.patch_refs.each do |pref|
          patch = get_patch(pref.patch_index)
          next unless patch

          patch.columns.each_with_index do |posts, px|
            tx = pref.x_offset + px
            next if tx < 0 || tx >= texture.width

            posts.each do |post|
              columns[tx] << Patch::Post.new(
                pref.y_offset + post.top_delta,
                post.pixels
              )
            end
          end
        end

        CompositeTexture.new(name, texture.width, texture.height, columns)
      end
    end

    class CompositeTexture
      attr_reader :name, :width, :height, :columns

      def initialize(name, width, height, columns)
        @name = name
        @width = width
        @height = height
        @columns = columns
      end

      def column_pixels(x, height_needed = nil)
        x = x % @width
        posts = @columns[x]
        height_needed ||= @height

        pixels = Array.new(height_needed, 0)
        posts.each do |post|
          post.pixels.each_with_index do |color, i|
            y = (post.top_delta + i) % @height
            pixels[y] = color if y < height_needed
          end
        end
        pixels
      end
    end
  end
end
