# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Wad::Flat do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @flats = Doom::Wad::Flat.load_all(@wad)
  end

  after(:all) do
    @wad&.close
  end

  describe '.load_all' do
    it 'loads flats successfully' do
      expect(@flats).not_to be_empty
    end

    it 'includes common floor textures' do
      names = @flats.map(&:name)
      expect(names).to include('FLOOR4_8')
      expect(names).to include('CEIL3_5')
    end
  end

  describe 'Flat instance' do
    before(:all) do
      @flat = @flats.find { |f| f.name == 'FLOOR4_8' }
    end

    it 'has correct dimensions (64x64)' do
      expect(@flat.width).to eq(64)
      expect(@flat.height).to eq(64)
    end

    it 'has pixels array of correct size' do
      expect(@flat.pixels.size).to eq(@flat.width * @flat.height)
    end

    it 'returns valid palette indices' do
      64.times do |x|
        64.times do |y|
          color = @flat[x, y]
          expect(color).to be_between(0, 255)
        end
      end
    end
  end
end

RSpec.describe Doom::Wad::TextureManager do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @textures = Doom::Wad::TextureManager.new(@wad)
  end

  after(:all) do
    @wad&.close
  end

  describe '#[]' do
    it 'loads wall textures' do
      texture = @textures['STARTAN3']
      expect(texture).not_to be_nil
    end

    it 'returns nil for non-existent textures' do
      expect(@textures['NOTEXIST']).to be_nil
    end

    it 'caches loaded textures' do
      tex1 = @textures['DOOR1']
      tex2 = @textures['DOOR1']
      expect(tex1).to equal(tex2)
    end
  end

  describe 'Texture instance' do
    before(:all) do
      @texture = @textures['STARTAN3']
    end

    it 'has dimensions' do
      expect(@texture.width).to be > 0
      expect(@texture.height).to be > 0
    end

    it 'has column_pixels method' do
      expect(@texture).to respond_to(:column_pixels)
    end

    it 'returns pixel data for columns' do
      column = @texture.column_pixels(0)
      expect(column).to be_an(Array)
      expect(column.size).to eq(@texture.height)
    end
  end
end

RSpec.describe Doom::Wad::Sprite do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
  end

  after(:all) do
    @wad&.close
  end

  describe '.load' do
    it 'loads sprite successfully' do
      sprite = Doom::Wad::Sprite.load(@wad, 'PLAYA1')
      expect(sprite).not_to be_nil
    end

    it 'returns nil for non-existent sprite' do
      expect(Doom::Wad::Sprite.load(@wad, 'NOTEXIST')).to be_nil
    end
  end

  describe 'Sprite instance' do
    before(:all) do
      @sprite = Doom::Wad::Sprite.load(@wad, 'PLAYA1')
    end

    it 'has dimensions' do
      expect(@sprite.width).to be > 0
      expect(@sprite.height).to be > 0
    end

    it 'has offsets' do
      expect(@sprite.left_offset).to be_a(Integer)
      expect(@sprite.top_offset).to be_a(Integer)
    end

    it 'returns column pixels with transparency' do
      column = @sprite.column_pixels(0)
      expect(column).to be_an(Array)
      # Sprites have transparent pixels (nil)
      expect(column).to include(nil).or(all(be_between(0, 255)))
    end
  end
end

RSpec.describe Doom::Wad::SpriteManager do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) do
    @wad&.close
  end

  describe '#[]' do
    it 'returns sprite for known thing types' do
      # 2007 = Clip
      sprite = @sprites[2007]
      expect(sprite).not_to be_nil
    end

    it 'returns nil for unknown thing types' do
      expect(@sprites[99999]).to be_nil
    end

    it 'caches sprites' do
      sprite1 = @sprites[2007]
      sprite2 = @sprites[2007]
      expect(sprite1).to equal(sprite2)
    end
  end
end
