# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::WorldMesh do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
    @mesh = described_class.new(@map)
  end

  after(:all) { @wad&.close }

  it 'turns map surfaces into non-degenerate triangles' do
    expect(@mesh.triangles).not_to be_empty
    @mesh.triangles.each do |triangle|
      expect(triangle.vertices.size).to eq(3)
      expect(triangle.vertices.uniq.size).to eq(3)
    end
  end

  it 'contains horizontal planes and vertical walls' do
    normals = @mesh.triangles.map(&:normal)
    expect(normals.any? { |normal| normal[2].abs == 1.0 }).to be(true)
    expect(normals.any? { |normal| normal[2].zero? }).to be(true)
  end

  it 'builds plane triangles for every reconstructable subsector' do
    represented = @mesh.triangles.select { |triangle| triangle.normal[2].abs == 1.0 }
    expect(represented.size).to be > @map.subsectors.size
  end
end
