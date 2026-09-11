# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::RayTracing::TextureAtlas do
  Palette = Struct.new(:colors)
  Texture = Struct.new(:width, :height, :columns) do
    def column_pixels(index) = columns[index]
  end

  it 'packs column-major textures and preserves transparent holes' do
    texture = Texture.new(2, 2, [[1, nil], [2, 1]])
    palette = Palette.new([[0, 0, 0], [10, 20, 30], [40, 50, 60]])
    atlas = described_class.new(size: 4, textures: { 'GRATE' => texture },
                                flats: {}, palette: palette)

    pixels, rectangles = atlas.build(['GRATE'])

    expect(pixels.byteslice(0, 8).bytes).to eq([10, 20, 30, 255, 40, 50, 60, 255])
    expect(pixels.byteslice(16, 8).bytes).to eq([0, 0, 0, 0, 10, 20, 30, 255])
    expect(rectangles['GRATE']).to eq([0.0, 0.0, 0.5, 0.5, 2.0, 2.0])
  end

  it 'fails clearly when materials exceed the configured atlas' do
    texture = Texture.new(3, 3, Array.new(3) { Array.new(3, 0) })
    atlas = described_class.new(size: 2, textures: { 'BIG' => texture },
                                flats: {}, palette: Palette.new([[0, 0, 0]]))

    expect { atlas.build(['BIG']) }.to raise_error(ArgumentError, /overflow/)
  end
end
