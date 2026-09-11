# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Doom::Render::RayTracing::Bvh do
  Triangle = Struct.new(:vertices)

  def triangle(x, z = 0.0)
    Triangle.new([[x, 0.0, z], [x + 1.0, 0.0, z], [x, 1.0, z]])
  end

  it 'builds stackless preorder nodes whose escape indices skip subtrees' do
    bvh = described_class.new(10.times.map { |x| triangle(x * 10.0) }, leaf_size: 2)

    expect(bvh.nodes.first.escape).to eq(bvh.nodes.size)
    expect(bvh.nodes.select(&:leaf?)).to all(satisfy { |node| node.count <= 2 })
    expect(bvh.triangle_order.sort).to eq((0...10).to_a)
  end

  it 'refits moving geometry without changing topology or leaf order' do
    bvh = described_class.new([triangle(0), triangle(20)], leaf_size: 1)
    order = bvh.triangle_order.dup
    node_count = bvh.nodes.size

    bvh.refit([triangle(100), triangle(120)])

    expect(bvh.triangle_order).to eq(order)
    expect(bvh.nodes.size).to eq(node_count)
    expect(bvh.nodes.first.minimum[0]).to be_within(0.001).of(99.99)
    expect(bvh.nodes.first.maximum[0]).to be_within(0.001).of(121.01)
  end

  it 'rejects a refit after triangle topology changes' do
    bvh = described_class.new([triangle(0)])

    expect { bvh.refit([triangle(0), triangle(1)]) }
      .to raise_error(ArgumentError, /topology changed/)
  end

  it 'packs exactly three RGBA texels per node' do
    bvh = described_class.new([triangle(0)])

    expect(bvh.packed_floats.size).to eq(bvh.nodes.size * 12)
  end
end
