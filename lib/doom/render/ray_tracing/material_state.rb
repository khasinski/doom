# frozen_string_literal: true

module Doom
  module Render
    module RayTracing
      # Resolves animated WAD materials and packs per-surface flags into the
      # float shared with sector light level in the GPU triangle texture.
      class MaterialState
        EMISSIVE_FLAG = 1_024.0
        MASKED_FLAG = 2_048.0
        REFLECTIVE_FLAG = 4_096.0
        REFRACTIVE_FLAG = 8_192.0
        EMISSIVE_PATTERN = /\A(?:NUKAGE|SLIME|LAVA)/
        LIQUID_PATTERN = /\A(?:NUKAGE|SLIME|LAVA|FWATER|SWATER|BLOOD)/
        REFLECTIVE_PATTERN = /#{LIQUID_PATTERN.source}|(?:METAL|SILVER|COMP|TEK|SUPPORT)/
        REFRACTIVE_PATTERN = LIQUID_PATTERN

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
          return @animations.frame_names if @animations.respond_to?(:frame_names)

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

        def reflective?(name)
          name&.match?(REFLECTIVE_PATTERN) || false
        end

        def refractive?(name)
          name&.match?(REFRACTIVE_PATTERN) || false
        end

        def encoded_light(triangle)
          value = triangle.light.to_f
          value += EMISSIVE_FLAG if emissive?(triangle.material)
          value += MASKED_FLAG if triangle.masked
          value += REFLECTIVE_FLAG if reflective?(triangle.material)
          value += REFRACTIVE_FLAG if refractive?(triangle.material)
          value
        end
      end
    end
  end
end
