# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::RayTracing::MaterialState do
  let(:animations) do
    instance_double(Doom::Game::Animations,
                    flat_translation: { 'NUKAGE1' => 'NUKAGE2' },
                    texture_translation: { 'BLODGR1' => 'BLODGR2' },
                    frame_names: %w[NUKAGE1 NUKAGE2 NUKAGE3 BLODGR1 BLODGR2],
                    translate_flat: 'NUKAGE2', translate_texture: 'BLODGR2')
  end
  subject(:materials) { described_class.new({ 'NUKAGE1' => Object.new }, animations) }

  it 'resolves flats and wall textures through their separate animation tables' do
    expect(materials.resolve('NUKAGE1')).to eq('NUKAGE2')
    expect(materials.resolve('BLODGR1')).to eq('BLODGR2')
    expect(animations).to have_received(:translate_flat).with('NUKAGE1')
    expect(animations).to have_received(:translate_texture).with('BLODGR1')
  end

  it 'exposes every animation frame for the immutable atlas' do
    expect(materials.animation_names)
      .to contain_exactly('NUKAGE1', 'NUKAGE2', 'NUKAGE3', 'BLODGR1', 'BLODGR2')
  end

  it 'encodes sector light and independent material properties' do
    triangle = Struct.new(:light, :material, :masked).new(160, 'NUKAGE1', true)

    expect(materials.encoded_light(triangle)).to eq(160 + 1_024 + 2_048 + 4_096 + 8_192)
  end

  it 'does not classify ordinary materials as emissive' do
    expect(materials.emissive?('STARTAN3')).to be(false)
  end

  it 'classifies every Doom liquid family as reflective and refractive' do
    %w[NUKAGE1 SLIME01 LAVA1 FWATER1 SWATER1 BLOOD1].each do |name|
      expect(materials.reflective?(name)).to be(true), name
      expect(materials.refractive?(name)).to be(true), name
    end
  end

  it 'classifies metal as reflective but opaque' do
    expect(materials.reflective?('METAL1')).to be(true)
    expect(materials.refractive?('METAL1')).to be(false)
  end
end
