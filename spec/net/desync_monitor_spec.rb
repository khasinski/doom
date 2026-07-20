# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Net::DesyncMonitor do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  def new_world(seed = 0)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    w = Doom::Game::World.new(map, sprites: @sprites, random: Doom::Game::Random.new(seed))
    w.add_player
    w
  end

  let(:caught) { [] }
  subject(:monitor) { described_class.new { |d| caught << d } }

  describe 'checkpoints' do
    it 'checks on the interval and not between' do
      expect(monitor.check_due?(35)).to be true
      expect(monitor.check_due?(70)).to be true
      expect(monitor.check_due?(34)).to be false
    end

    it 'returns section hashes on a checkpoint tic and nil otherwise' do
      w = new_world
      expect(monitor.record(34, w)).to be_nil
      expect(monitor.record(35, w)).to include(*Doom::Game::StateHash::SECTIONS)
    end
  end

  describe 'agreeing peers' do
    it 'reports nothing when the fingerprints match' do
      a = new_world(1)
      b = new_world(1)

      sections = monitor.record(35, a)
      monitor.remote_report(35, 1, b.state_hash_sections)

      expect(sections).to eq(b.state_hash_sections)
      expect(monitor).not_to be_desynced
      expect(caught).to be_empty
    end
  end

  describe 'diverging peers' do
    def diverged_pair
      a = new_world(1)
      b = new_world(1)
      b.monster_ai.monsters.first.x += 1.0
      [a, b]
    end

    it 'fires as soon as the pair completes' do
      a, b = diverged_pair
      monitor.record(35, a)
      monitor.remote_report(35, 1, b.state_hash_sections)

      expect(monitor).to be_desynced
      expect(caught.size).to eq(1)
      expect(caught.first.tic).to eq(35)
      expect(caught.first.peer_id).to eq(1)
    end

    it 'names the section that drifted' do
      a, b = diverged_pair
      monitor.record(35, a)
      monitor.remote_report(35, 1, b.state_hash_sections)

      expect(caught.first.sections).to eq([:monsters])
      expect(caught.first.message).to include('tic 35', 'peer 1', 'monsters')
    end

    it 'fires when the remote report arrives first' do
      # Ordering is not guaranteed over UDP.
      a, b = diverged_pair
      monitor.remote_report(35, 1, b.state_hash_sections)
      expect(monitor).not_to be_desynced

      monitor.record(35, a)
      expect(monitor).to be_desynced
    end

    it 'reports a given tic and peer only once' do
      a, b = diverged_pair
      monitor.record(35, a)
      3.times { monitor.remote_report(35, 1, b.state_hash_sections) }

      expect(caught.size).to eq(1)
    end

    it 'reports each diverging peer separately' do
      a, b = diverged_pair
      c = new_world(1)
      c.player(0).x += 1.0

      monitor.record(35, a)
      monitor.remote_report(35, 1, b.state_hash_sections)
      monitor.remote_report(35, 2, c.state_hash_sections)

      expect(caught.map(&:peer_id)).to contain_exactly(1, 2)
      expect(caught.find { |d| d.peer_id == 2 }.sections).to eq([:players])
    end

    it 'stays quiet for a peer that still agrees' do
      a, b = diverged_pair
      good = new_world(1)

      monitor.record(35, a)
      monitor.remote_report(35, 1, b.state_hash_sections)
      monitor.remote_report(35, 2, good.state_hash_sections)

      expect(caught.map(&:peer_id)).to eq([1])
    end
  end

  describe 'a run that diverges partway' do
    it 'names the first tic that disagreed' do
      a = new_world(2)
      b = new_world(2)
      cmd = Doom::Game::Ticcmd.new(1.0, 0.0, 0.0, 0)

      210.times do |i|
        tic = i + 1
        a.run_tic(0 => cmd)
        b.run_tic(0 => cmd)
        # Knock b off course midway through.
        b.player(0).y = b.player(0).y.next_float if tic == 100

        monitor.record(tic, a)
        monitor.remote_report(tic, 1, b.state_hash_sections) if monitor.check_due?(tic)
      end

      expect(monitor).to be_desynced
      expect(caught.first.tic).to eq(105)  # first checkpoint after the drift
      expect(caught.first.sections).to include(:players)
    end
  end

  describe 'memory' do
    it 'does not grow without bound over a long session' do
      w = new_world
      (1..2000).each { |tic| monitor.record(tic, w) }

      kept = monitor.instance_variable_get(:@local).size
      expect(kept).to be <= (described_class::HISTORY_TICS / described_class::CHECK_INTERVAL) + 2
    end
  end
end
