# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Wad::Reader do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
  end

  after(:all) do
    @wad&.close
  end

  describe '#initialize' do
    it 'reads the WAD header correctly' do
      expect(@wad.type).to match(/^[IP]WAD$/)
    end

    it 'reads the correct number of lumps' do
      # DOOM1.WAD (shareware) has 2306 lumps
      expect(@wad.num_lumps).to be > 2000
    end

    it 'populates the directory' do
      expect(@wad.directory).not_to be_empty
      expect(@wad.directory.size).to eq(@wad.num_lumps)
    end
  end

  describe '#find_lump' do
    it 'finds existing lumps by name' do
      playpal = @wad.find_lump('PLAYPAL')
      expect(playpal).not_to be_nil
      expect(playpal.name).to eq('PLAYPAL')
    end

    it 'returns nil for non-existent lumps' do
      expect(@wad.find_lump('NOTEXIST')).to be_nil
    end

    it 'is case-insensitive' do
      expect(@wad.find_lump('playpal')).not_to be_nil
      expect(@wad.find_lump('PlayPal')).not_to be_nil
    end
  end

  describe '#read_lump' do
    it 'reads lump data correctly' do
      playpal = @wad.read_lump('PLAYPAL')
      expect(playpal).not_to be_nil
      # PLAYPAL is 14 palettes * 256 colors * 3 bytes = 10752 bytes
      expect(playpal.size).to eq(10752)
    end

    it 'caches lump data' do
      data1 = @wad.read_lump('COLORMAP')
      data2 = @wad.read_lump('COLORMAP')
      expect(data1).to equal(data2) # Same object
    end

    it 'returns nil for non-existent lumps' do
      expect(@wad.read_lump('NOTEXIST')).to be_nil
    end
  end

  describe '#lumps_between' do
    it 'returns lumps between markers' do
      flats = @wad.lumps_between('F_START', 'F_END')
      expect(flats).not_to be_empty
      expect(flats.all? { |e| e.is_a?(Doom::Wad::Reader::DirectoryEntry) }).to be true
    end

    it 'returns empty array for invalid markers' do
      expect(@wad.lumps_between('INVALID', 'MARKERS')).to eq([])
    end
  end

  describe 'DirectoryEntry' do
    it 'has correct structure' do
      entry = @wad.directory.first
      expect(entry).to respond_to(:offset)
      expect(entry).to respond_to(:size)
      expect(entry).to respond_to(:name)
    end

    it 'has valid offsets and sizes' do
      @wad.directory.each do |entry|
        expect(entry.offset).to be >= 0
        expect(entry.size).to be >= 0
      end
    end
  end
end
