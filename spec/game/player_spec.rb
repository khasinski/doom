# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Game::Player do
  subject(:player) { described_class.new }

  describe 'angle handling' do
    it 'keeps sin/cos in step with the angle' do
      player.angle = Math::PI / 3
      expect(player.sin_angle).to be_within(1e-12).of(Math.sin(Math::PI / 3))
      expect(player.cos_angle).to be_within(1e-12).of(Math.cos(Math::PI / 3))
    end

    it 'converts degrees on assignment' do
      player.angle_degrees = 90
      expect(player.angle).to be_within(1e-12).of(Math::PI / 2)
      expect(player.cos_angle).to be_within(1e-12).of(0.0)
    end

    it 'accumulates turns and refreshes the cache' do
      player.angle_degrees = 0
      player.turn(90)
      player.turn(90)
      expect(player.angle).to be_within(1e-12).of(Math::PI)
      expect(player.sin_angle).to be_within(1e-12).of(0.0)
    end
  end

  describe '#place' do
    it 'sets the pose, clears momentum and collapses interpolation history' do
      player.momx = 5.0
      player.momy = -3.0
      player.place(100, 200, 41, 180)

      expect([player.x, player.y, player.z]).to eq([100.0, 200.0, 41.0])
      expect(player.angle).to be_within(1e-12).of(Math::PI)
      expect([player.momx, player.momy]).to eq([0.0, 0.0])
      # A teleport must not make the camera sweep across the map.
      expect(player.view_pose(0.0)).to eq(player.view_pose(1.0))
    end
  end

  describe '#view_pose interpolation' do
    before do
      player.place(0, 0, 41, 0)
      player.snapshot!
      player.move_to(10, 20)
      player.z = 51.0
    end

    it 'returns the previous pose at alpha 0' do
      x, y, z, = player.view_pose(0.0)
      expect([x, y, z]).to eq([0.0, 0.0, 41.0])
    end

    it 'returns the current pose at alpha 1' do
      x, y, z, = player.view_pose(1.0)
      expect([x, y, z]).to eq([10.0, 20.0, 51.0])
    end

    it 'returns the midpoint at alpha 0.5' do
      x, y, z, = player.view_pose(0.5)
      expect([x, y, z]).to eq([5.0, 10.0, 46.0])
    end

    it 'clamps alpha outside 0..1' do
      expect(player.view_pose(-1.0)).to eq(player.view_pose(0.0))
      expect(player.view_pose(2.0)).to eq(player.view_pose(1.0))
    end

    it 'interpolates the angle along the shortest arc across the -PI/+PI seam' do
      player.angle = (-Math::PI) + 0.1
      player.snapshot!
      player.angle = Math::PI - 0.1

      _, _, _, a = player.view_pose(0.5)
      # Shortest path is backwards through the seam (0.2 rad), not forwards
      # through zero (6.08 rad), so the midpoint sits just outside the seam.
      expect(a.abs).to be > (Math::PI - 0.1)
    end

    it 'interpolates a normal turn without wrapping' do
      player.angle = 0.0
      player.snapshot!
      player.angle = 1.0
      _, _, _, a = player.view_pose(0.5)
      expect(a).to be_within(1e-12).of(0.5)
    end
  end

  describe 'identity and state' do
    it 'defaults to id 0 with its own PlayerState' do
      expect(player.id).to eq(0)
      expect(player.state).to be_a(Doom::Game::PlayerState)
    end

    it 'gives separate players separate state' do
      a = described_class.new(id: 0)
      b = described_class.new(id: 1)
      a.state.health = 10
      expect(b.state.health).to eq(100)
    end

    it 'reports death from its state' do
      expect(player).not_to be_dead
      player.state.dead = true
      expect(player).to be_dead
    end
  end
end
