# frozen_string_literal: true

module Doom
  module Game
    # Animated texture/flat cycling, matching Chocolate Doom's P_InitPicAnims
    # and P_UpdateSpecials from p_spec.c.
    #
    # All animations run at 8 tics per frame (8/35 sec ≈ 0.23s).
    # Frames must be consecutive entries in the WAD; the engine uses
    # start/end names to find the range.
    class Animations
      TICS_PER_FRAME = 8

      # [is_texture, start_name, end_name]
      # From Chocolate Doom animdefs[] in p_spec.c
      ANIMDEFS = [
        # Animated flats
        [false, 'NUKAGE1',  'NUKAGE3'],
        [false, 'FWATER1',  'FWATER4'],
        [false, 'SWATER1',  'SWATER4'],
        [false, 'LAVA1',    'LAVA4'],
        [false, 'BLOOD1',   'BLOOD3'],
        [false, 'RROCK05',  'RROCK08'],
        [false, 'SLIME01',  'SLIME04'],
        [false, 'SLIME05',  'SLIME08'],
        [false, 'SLIME09',  'SLIME12'],
        # Animated wall textures
        [true, 'BLODGR1',  'BLODGR4'],
        [true, 'SLADRIP1', 'SLADRIP3'],
        [true, 'BLODRIP1', 'BLODRIP4'],
        [true, 'FIREWALA', 'FIREWALL'],
        [true, 'GSTFONT1', 'GSTFONT3'],
        [true, 'FIRELAV3', 'FIRELAVA'],
        [true, 'FIREMAG1', 'FIREMAG3'],
        [true, 'FIREBLU1', 'FIREBLU2'],
        [true, 'ROCKRED1', 'ROCKRED3'],
        [true, 'BFALL1',   'BFALL4'],
        [true, 'SFALL1',   'SFALL4'],
        [true, 'WFALL1',   'WFALL4'],
        [true, 'DBRAIN1',  'DBRAIN4'],
      ].freeze

      attr_reader :flat_translation, :texture_translation

      def initialize(texture_names, flat_names)
        @flat_translation = {}      # flat_name -> current_frame_name
        @texture_translation = {}   # texture_name -> current_frame_name
        @anims = []

        ANIMDEFS.each do |is_texture, start_name, end_name|
          names = is_texture ? texture_names : flat_names

          start_idx = names.index(start_name)
          end_idx = names.index(end_name)
          next unless start_idx && end_idx
          next if end_idx <= start_idx

          frames = names[start_idx..end_idx]
          next if frames.size < 2

          @anims << {
            is_texture: is_texture,
            frames: frames,
            speed: TICS_PER_FRAME,
          }
        end
      end

      # Call every game tic (or approximate with leveltime).
      # Matches Chocolate Doom P_UpdateSpecials:
      #   pic = basepic + ((leveltime / speed + i) % numpics)
      def update(leveltime)
        @anims.each do |anim|
          frames = anim[:frames]
          numpics = frames.size
          phase = leveltime / anim[:speed]
          translation = anim[:is_texture] ? @texture_translation : @flat_translation

          numpics.times do |i|
            current_frame = frames[(phase + i) % numpics]
            translation[frames[i]] = current_frame
          end
        end
      end

      # Translate a flat name to its current animation frame
      def translate_flat(name)
        @flat_translation[name] || name
      end

      # Translate a texture name to its current animation frame
      def translate_texture(name)
        @texture_translation[name] || name
      end
    end
  end
end
