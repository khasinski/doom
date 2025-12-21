# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::Renderer do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @palette = Doom::Wad::Palette.load(@wad)
    @colormap = Doom::Wad::Colormap.load(@wad)
    @flats = Doom::Wad::Flat.load_all(@wad)
    @textures = Doom::Wad::TextureManager.new(@wad)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')

    @renderer = Doom::Render::Renderer.new(
      @wad, @map, @textures, @palette, @colormap, @flats, @sprites
    )
  end

  after(:all) do
    @wad&.close
  end

  describe '#initialize' do
    it 'creates renderer successfully' do
      expect(@renderer).not_to be_nil
    end

    it 'has framebuffer of correct size' do
      expect(@renderer.framebuffer.size).to eq(Doom::Render::SCREEN_WIDTH * Doom::Render::SCREEN_HEIGHT)
    end

    it 'initializes framebuffer to zeros' do
      renderer = Doom::Render::Renderer.new(
        @wad, @map, @textures, @palette, @colormap, @flats, @sprites
      )
      expect(renderer.framebuffer.all?(&:zero?)).to be true
    end
  end

  describe '#set_player' do
    it 'sets player position' do
      @renderer.set_player(100, 200, 41, 90)
      # No error means success (position is private)
    end
  end

  describe '#render_frame' do
    before(:each) do
      start = @map.player_start
      @renderer.set_player(start.x, start.y, 41, start.angle)
      @renderer.render_frame
    end

    it 'fills framebuffer with non-zero values' do
      non_zero = @renderer.framebuffer.count { |p| p != 0 }
      expect(non_zero).to be > 0
    end

    it 'produces valid palette indices' do
      @renderer.framebuffer.each do |color|
        expect(color).to be_between(0, 255)
      end
    end

    it 'renders floor and ceiling' do
      w = Doom::Render::SCREEN_WIDTH
      h = Doom::Render::SCREEN_HEIGHT

      # Check that we have pixels in both top and bottom halves
      top_half = @renderer.framebuffer[0, w * (h / 2)]
      bottom_half = @renderer.framebuffer[w * (h / 2), w * (h / 2)]

      top_non_zero = top_half.count { |p| p != 0 }
      bottom_non_zero = bottom_half.count { |p| p != 0 }

      expect(top_non_zero).to be > 0
      expect(bottom_non_zero).to be > 0
    end

    it 'renders walls (non-uniform columns)' do
      w = Doom::Render::SCREEN_WIDTH
      h = Doom::Render::SCREEN_HEIGHT

      # Check that different columns have different patterns
      columns = (0...w).map do |x|
        (0...h).map { |y| @renderer.framebuffer[y * w + x] }
      end

      unique_columns = columns.uniq.size
      expect(unique_columns).to be > 1
    end
  end

  describe 'consistency' do
    it 'produces same output for same input' do
      start = @map.player_start
      @renderer.set_player(start.x, start.y, 41, start.angle)
      @renderer.render_frame
      frame1 = @renderer.framebuffer.dup

      @renderer.render_frame
      frame2 = @renderer.framebuffer.dup

      expect(frame1).to eq(frame2)
    end
  end
end

RSpec.describe 'Doom::Render constants' do
  it 'has correct screen dimensions' do
    expect(Doom::Render::SCREEN_WIDTH).to eq(320)
    expect(Doom::Render::SCREEN_HEIGHT).to eq(240)
  end

  it 'has correct half dimensions' do
    expect(Doom::Render::HALF_WIDTH).to eq(Doom::Render::SCREEN_WIDTH / 2)
    expect(Doom::Render::HALF_HEIGHT).to eq(Doom::Render::SCREEN_HEIGHT / 2)
  end

  it 'has 90 degree FOV' do
    expect(Doom::Render::FOV).to eq(90.0)
  end
end
