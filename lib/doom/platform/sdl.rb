# frozen_string_literal: true

module Doom
  module Platform
    # SDL2 keyboard grab via Gosu's bundled SDL -- prevents OS key interception.
    module SDLKeyboardGrab
      def self.setup
        require 'fiddle'
        gosu_spec = Gem.loaded_specs['gosu']
        lib_ext = RbConfig::CONFIG['DLEXT'] || 'so'
        bundle = File.join(gosu_spec.full_gem_path, 'lib', "gosu.#{lib_ext}")
        @lib = Fiddle.dlopen(bundle)
        @shared_window = Fiddle::Function.new(
          @lib['_ZN4Gosu13shared_windowEv'], [], Fiddle::TYPE_VOIDP
        )
        @set_kb_grab = Fiddle::Function.new(
          @lib['SDL_SetWindowKeyboardGrab'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOID
        )
        @ready = true
      rescue StandardError, LoadError => e
        warn "SDLKeyboardGrab.setup failed: #{e.class}: #{e.message}"
        @ready = false
      end

      def self.grab!
        return unless @ready

        @set_kb_grab.call(@shared_window.call, 1)
      end

      def self.release!
        return unless @ready

        @set_kb_grab.call(@shared_window.call, 0)
      end
    end

    # Ask SDL for the display's refresh rate.
    #
    # Timing our own buffer swaps cannot answer this: when the engine renders
    # slower than the display refreshes -- which is the normal case here --
    # the swap cadence measures our render time, not the monitor. SDL knows
    # the real number, and Gosu bundles SDL, so we read it directly the same
    # way SDLKeyboardGrab reaches for SDL_SetWindowKeyboardGrab.
    module SDLDisplayMode
      # SDL_DisplayMode { Uint32 format; int w; int h; int refresh_rate; void *driverdata; }
      REFRESH_RATE_OFFSET = 12
      STRUCT_SIZE = 32

      def self.refresh_rate
        require 'fiddle'
        gosu_spec = Gem.loaded_specs['gosu']
        lib_ext = RbConfig::CONFIG['DLEXT'] || 'so'
        lib = Fiddle.dlopen(File.join(gosu_spec.full_gem_path, 'lib', "gosu.#{lib_ext}"))

        get_mode = Fiddle::Function.new(
          lib['SDL_GetCurrentDisplayMode'],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT
        )

        buf = Fiddle::Pointer.malloc(STRUCT_SIZE)
        return nil unless get_mode.call(0, buf).zero?

        hz = buf[REFRESH_RATE_OFFSET, 4].unpack1('l')
        # SDL reports 0 when the rate is unspecified (some virtual displays).
        hz.positive? ? hz : nil
      rescue StandardError, LoadError => e
        warn "SDLDisplayMode.refresh_rate failed: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
