# frozen_string_literal: true

require_relative 'lib/doom/version'

Gem::Specification.new do |s|
  s.name        = 'doom'
  s.version     = Doom::VERSION
  s.summary     = 'Doom engine port in pure Ruby'
  s.description = 'A faithful port of the Doom (1993) rendering engine to Ruby. ' \
                  'Supports original WAD files with near pixel-perfect BSP rendering.'
  s.authors     = ['Chris Hasinski']
  s.email       = ['krzysztof.hasinski@gmail.com']
  s.homepage    = 'https://github.com/khasinski/doom'
  s.license     = 'GPL-2.0'

  s.files       = Dir['lib/**/*', 'bin/*', 'README.md', 'LICENSE']
  s.executables = ['doom']
  s.require_paths = ['lib']

  s.required_ruby_version = '>= 3.1'

  s.add_dependency 'gosu', '~> 1.4'
  # Gosu owns the window/context; these bindings expose that context for the
  # hardware-accelerated 3D renderer. Fiddle is explicit on Ruby 4+.
  s.add_dependency 'fiddle'
  s.add_dependency 'opengl-bindings', '~> 1.6'

  s.add_development_dependency 'rspec', '~> 3.12'
  # Dev-only: used solely by the debug screenshot capture (F-key), which
  # requires it lazily. Normal gameplay never loads it, so it stays out of the
  # runtime dependencies.
  s.add_development_dependency 'chunky_png', '~> 1.4'
end
