# frozen_string_literal: true

require 'rbconfig'

module Doom
  module Platform
    # Gosu 1.4.6's macOS extension can be linked without its AppKit and SDL2
    # dependencies when sdl2-config does not implement --static-libs. Load the
    # frameworks globally first so dyld can resolve the extension's symbols.
    module GosuLoader
      APPKIT = '/System/Library/Frameworks/AppKit.framework/AppKit'
      SDL2_CANDIDATES = %w[
        /opt/homebrew/opt/sdl2/lib/libSDL2.dylib
        /usr/local/opt/sdl2/lib/libSDL2.dylib
        /opt/homebrew/lib/libSDL2.dylib
        /usr/local/lib/libSDL2.dylib
      ].freeze

      module_function

      def prepare!
        return unless RbConfig::CONFIG['host_os'].include?('darwin')

        require 'fiddle'
        flags = Fiddle::RTLD_GLOBAL | Fiddle::RTLD_LAZY
        @handles ||= []
        @handles << Fiddle::Handle.new(APPKIT, flags)

        sdl2 = SDL2_CANDIDATES.find { |path| File.file?(path) }
        unless sdl2
          raise LoadError,
                'Could not find Homebrew SDL2 required by Gosu. Install it with `brew install sdl2`.'
        end

        @sdl2_handle = Fiddle::Handle.new(sdl2, flags)
        @handles << @sdl2_handle
      rescue Fiddle::DLError => e
        raise LoadError, "Could not load macOS frameworks required by Gosu: #{e.message}"
      end

      def sdl2_handle
        @sdl2_handle
      end
    end
  end
end
