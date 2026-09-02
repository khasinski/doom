# frozen_string_literal: true

module Doom
  module Render
    module RendererFactory
      TYPES = %i[classic zbuffer rasterizer raytracing].freeze
      SWITCH_TYPES = %i[classic rasterizer raytracing].freeze

      module_function

      def build(type, wad, map, textures, palette, colormap, flats, sprites = nil, animations = nil)
        klass = case normalize(type)
                when :classic then Renderer
                when :zbuffer then ZBufferRenderer
                when :rasterizer then HardwareRenderer
                when :raytracing then RayTracingRenderer
                end
        klass.new(wad, map, textures, palette, colormap, flats, sprites, animations)
      end

      def build_like(renderer, type)
        build(type, renderer.wad, renderer.map, renderer.textures, renderer.palette,
              renderer.colormap, renderer.flats.values, renderer.sprites, renderer.animations)
      end

      def normalize(type)
        value = (type || :classic).to_sym
        raise ArgumentError, "unknown renderer #{type.inspect}; expected #{TYPES.join(' or ')}" unless TYPES.include?(value)

        value
      end

      def type_of(renderer)
        return :raytracing if renderer.is_a?(RayTracingRenderer)
        return :rasterizer if renderer.is_a?(HardwareRenderer)
        return :zbuffer if renderer.is_a?(ZBufferRenderer)

        :classic
      end

      def next_type(renderer)
        current_index = SWITCH_TYPES.index(type_of(renderer)) || 0
        SWITCH_TYPES[(current_index + 1) % SWITCH_TYPES.size]
      end
    end
  end
end
