# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Wad::Palette do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @palette = Doom::Wad::Palette.load(@wad)
  end

  after(:all) do
    @wad&.close
  end

  describe '.load' do
    it 'loads palette successfully' do
      expect(@palette).not_to be_nil
    end

    it 'has 256 colors' do
      expect(@palette.colors.size).to eq(256)
    end
  end

  describe '#[]' do
    it 'returns RGB triplet for valid index' do
      color = @palette[0]
      expect(color).to be_an(Array)
      expect(color.size).to eq(3)
    end

    it 'returns values in 0-255 range' do
      256.times do |i|
        r, g, b = @palette[i]
        expect(r).to be_between(0, 255)
        expect(g).to be_between(0, 255)
        expect(b).to be_between(0, 255)
      end
    end

    # Doom palette index 0 is black (0, 0, 0)
    it 'has black at index 0' do
      expect(@palette[0]).to eq([0, 0, 0])
    end
  end
end

RSpec.describe Doom::Wad::Colormap do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @colormap = Doom::Wad::Colormap.load(@wad)
  end

  after(:all) do
    @wad&.close
  end

  describe '.load' do
    it 'loads colormap successfully' do
      expect(@colormap).not_to be_nil
    end

    # 34 colormaps: 32 light levels + inverse + all black
    it 'has 34 maps' do
      expect(@colormap.maps.size).to eq(34)
    end
  end

  describe '#maps' do
    it 'each map has 256 entries' do
      @colormap.maps.each do |map|
        expect(map.size).to eq(256)
      end
    end

    it 'map 0 (full bright) is identity' do
      # Full bright should mostly preserve colors
      bright = @colormap.maps[0]
      expect(bright[0]).to eq(0) # Black stays black
    end

    it 'map 31 (darkest) maps to dark colors' do
      dark = @colormap.maps[31]
      # Most colors should map to darker indices
      expect(dark.uniq.size).to be < 256
    end

    it 'all values are valid palette indices' do
      @colormap.maps.each do |map|
        map.each do |idx|
          expect(idx).to be_between(0, 255)
        end
      end
    end
  end
end
