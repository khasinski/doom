# frozen_string_literal: true

require_relative '../spec_helper'
require 'zlib'

# [map, x, y, z, angle_degrees] => expected framebuffer CRC32
RENDERER_OUTPUT_SCENES = {
  ['E1M1', 1056.0, -3616.0, 41.0, 90.0] => 1_910_367_440,
  ['E1M1', 1056.0, -3616.0, 41.0, 210.0] => 3_816_593_378,
  ['E1M1', 1520.0, -3200.0, 41.0, 45.0] => 4_045_630_233,
  ['E1M2', -320.0, -256.0, 41.0, 0.0] => 3_434_959_376,
  ['E1M5', 88.0, -3072.0, 41.0, 270.0] => 1_421_083_691
}.freeze

# Byte-for-byte characterization of the software renderer across several maps
# and camera angles. These CRCs were captured from known-good output; they pin
# the rendered image so a refactor of the drawing hot paths (draw_seg_range and
# friends) can be proven to change nothing. A diff in any scene fails here.
#
# If the renderer's output legitimately changes, regenerate the CRCs -- but only
# when the change to the image is intended.
RSpec.describe 'renderer output characterization' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @palette = Doom::Wad::Palette.load(@wad)
    @colormap = Doom::Wad::Colormap.load(@wad)
    @flats = Doom::Wad::Flat.load_all(@wad)
    @textures = Doom::Wad::TextureManager.new(@wad)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  RENDERER_OUTPUT_SCENES.each do |(map_name, x, y, z, deg), expected_crc|
    it "renders #{map_name} at (#{x}, #{y}) facing #{deg} deg byte-for-byte" do
      map = Doom::Map::MapData.load(@wad, map_name)
      renderer = Doom::Render::Renderer.new(@wad, map, @textures, @palette,
                                            @colormap, @flats, @sprites, nil)
      renderer.apply_view(x, y, z, deg * Math::PI / 180.0)
      renderer.render_frame

      crc = Zlib.crc32(renderer.framebuffer.pack('C*'))
      expect(crc).to eq(expected_crc)
    end
  end
end
