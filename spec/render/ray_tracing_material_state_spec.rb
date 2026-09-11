# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::RayTracing::MaterialState do
  let(:animations) do
    instance_double(Doom::Game::Animations,
                    flat_translation: { 'NUKAGE1' => 'NUKAGE2' },
                    texture_translation: { 'BLODGR1' => 'BLODGR2' },
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
    expect(materials.animation_names).to contain_exactly('NUKAGE1', 'NUKAGE2', 'BLODGR1', 'BLODGR2')
  end

  it 'encodes sector light, emissive liquid and alpha masking independently' do
    triangle = Struct.new(:light, :material, :masked).new(160, 'NUKAGE1', true)

    expect(materials.encoded_light(triangle)).to eq(160 + 1_024 + 2_048)
  end

  it 'does not classify ordinary materials as emissive' do
    expect(materials.emissive?('STARTAN3')).to be(false)
  end
end
