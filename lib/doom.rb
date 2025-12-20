# frozen_string_literal: true

require_relative 'doom/version'
require_relative 'doom/wad/reader'
require_relative 'doom/wad/palette'
require_relative 'doom/wad/colormap'
require_relative 'doom/wad/flat'

module Doom
  class Error < StandardError; end

  class << self
    def run(wad_path, **options)
      wad = Wad::Reader.new(wad_path)
      puts "Loaded #{wad.type}: #{wad.num_lumps} lumps"

      palette = Wad::Palette.load(wad)
      puts "Loaded palette: #{palette.colors.size} colors"

      colormap = Wad::Colormap.load(wad)
      puts "Loaded colormap: #{colormap.maps.size} maps"

      flats = Wad::Flat.load_all(wad)
      puts "Loaded #{flats.size} flats"

      # Export first flat as test
      if flats.any?
        flats.first.to_png(palette, 'test_flat.png')
        puts "Exported #{flats.first.name} to test_flat.png"
      end

      wad
    end
  end
end
