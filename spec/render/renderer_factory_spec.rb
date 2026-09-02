# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::RendererFactory do
  it 'normalizes supported renderer names' do
    expect(described_class.normalize('classic')).to eq(:classic)
    expect(described_class.normalize(:zbuffer)).to eq(:zbuffer)
  end

  it 'rejects an unknown renderer' do
    expect { described_class.normalize('gpu') }.to raise_error(ArgumentError, /unknown renderer/)
  end
end

RSpec.describe Doom::Render::ZBufferRenderer do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @palette = Doom::Wad::Palette.load(@wad)
    @colormap = Doom::Wad::Colormap.load(@wad)
    @flats = Doom::Wad::Flat.load_all(@wad)
    @textures = Doom::Wad::TextureManager.new(@wad)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
  end

  after(:all) { @wad&.close }

  it 'writes finite depth for visible opaque geometry' do
    renderer = described_class.new(@wad, @map, @textures, @palette, @colormap,
                                   @flats, @sprites)
    start = @map.player_start
    renderer.set_player(start.x, start.y, 41, start.angle)
    renderer.render_frame

    expect(renderer.depth_buffer.length).to eq(Doom::Render::SCREEN_WIDTH * Doom::Render::SCREEN_HEIGHT)
    expect(renderer.depth_buffer.any?(&:finite?)).to be(true)
  end
end
