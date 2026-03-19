# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::Animations do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @textures = Doom::Wad::TextureManager.new(@wad)
    @flats = Doom::Wad::Flat.load_all(@wad)
  end

  after(:all) { @wad&.close }

  subject(:anims) { described_class.new(@textures.texture_names, @flats.map(&:name)) }

  describe '#initialize' do
    it 'finds NUKAGE animation sequence' do
      anim_list = anims.instance_variable_get(:@anims)
      nukage = anim_list.find { |a| a[:frames].include?('NUKAGE1') }
      expect(nukage).not_to be_nil
      expect(nukage[:frames]).to eq(%w[NUKAGE1 NUKAGE2 NUKAGE3])
    end

    it 'finds SLADRIP wall texture animation' do
      anim_list = anims.instance_variable_get(:@anims)
      sladrip = anim_list.find { |a| a[:frames].include?('SLADRIP1') }
      expect(sladrip).not_to be_nil
      expect(sladrip[:is_texture]).to be true
    end
  end

  describe '#update' do
    it 'cycles flat animations' do
      anims.update(0)
      expect(anims.translate_flat('NUKAGE1')).to eq('NUKAGE1')

      anims.update(8) # 8 tics = 1 frame advance
      expect(anims.translate_flat('NUKAGE1')).to eq('NUKAGE2')

      anims.update(16)
      expect(anims.translate_flat('NUKAGE1')).to eq('NUKAGE3')

      anims.update(24) # wraps back
      expect(anims.translate_flat('NUKAGE1')).to eq('NUKAGE1')
    end

    it 'keeps non-animated textures unchanged' do
      anims.update(8)
      expect(anims.translate_flat('FLOOR5_2')).to eq('FLOOR5_2')
      expect(anims.translate_texture('STARTAN3')).to eq('STARTAN3')
    end
  end
end
