# frozen_string_literal: true

module Doom
  module Render
    module RayTracing
      # Resolves animated WAD materials and packs per-surface flags into the
      # float shared with sector light level in the GPU triangle texture.
      class MaterialState
        EMISSIVE_FLAG = 1_024.0
        MASKED_FLAG = 2_048.0
        EMISSIVE_PATTERN = /\A(?:NUKAGE|SLIME|LAVA)/

        def initialize(flats, animations)
          @flats = flats
          @animations = animations
        end

        def animation_signature
          return nil unless @animations

          [@animations.flat_translation.values, @animations.texture_translation.values]
        end

        def animation_names
          return [] unless @animations

          [@animations.flat_translation, @animations.texture_translation]
            .flat_map { |translation| translation.keys + translation.values }
        end

        def resolve(name)
          return name unless @animations

          @flats.key?(name) ? @animations.translate_flat(name) : @animations.translate_texture(name)
        end

        def emissive?(name)
          name&.match?(EMISSIVE_PATTERN) || false
        end

        def encoded_light(triangle)
          value = triangle.light.to_f
          value += EMISSIVE_FLAG if emissive?(triangle.material)
          value += MASKED_FLAG if triangle.masked
          value
        end
      end
    end
  end
end
