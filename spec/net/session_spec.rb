# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Net::Session do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  after { @sessions&.each(&:quit) }

  def track(*sessions)
    (@sessions ||= []).concat(sessions)
    sessions.size == 1 ? sessions.first : sessions
  end

  # Pump everyone until the block is satisfied, or give up.
  def pump_until(sessions, timeout: 5.0)
    deadline = Time.now + timeout
    until yield
      raise 'timed out' if Time.now > deadline

      sessions.each(&:poll)
      sleep 0.005
    end
  end

  def world_for(session)
    map = Doom::Map::MapData.load(@wad, session.map_name)
    w = Doom::Game::World.new(map, sprites: @sprites, mode: session.mode,
                                   random: Doom::Game::Random.new(session.seed))
    session.player_ids.each { |id| w.add_player(id: id) }
    w
  end

  describe 'a solo host' do
    it 'starts immediately with one player' do
      s = track(described_class.host(port: 0, players: 1))
      expect(s).to be_started
      expect(s.local_id).to eq(0)
      expect(s.player_ids).to eq([0])
    end

    it 'picks a seed so the simulation has one' do
      s = track(described_class.host(port: 0, players: 1))
      expect(s.seed).to be_a(Integer)
    end
  end

  describe 'handshake' do
    let(:host) { described_class.host(port: 0, players: 2, map: 'E1M2', mode: :deathmatch, skill: 4, seed: 88) }
    let(:client) { described_class.connect(host: '127.0.0.1', port: host.local_port) }

    before { track(host, client) }

    it 'does not start the host until everyone has joined' do
      expect(host).not_to be_started
    end

    it 'completes and starts both sides' do
      pump_until([host, client]) { host.started? && client.started? }

      expect(host.local_id).to eq(0)
      expect(client.local_id).to eq(1)
    end

    it 'hands the client the game settings, so nobody guesses them locally' do
      pump_until([host, client]) { client.started? }

      expect(client.seed).to eq(88)
      expect(client.map_name).to eq('E1M2')
      expect(client.mode).to eq(:deathmatch)
      expect(client.skill).to eq(4)
      expect(client.num_players).to eq(2)
    end

    it 'gives both sides the same player list' do
      pump_until([host, client]) { client.started? }
      expect(client.player_ids).to eq(host.player_ids)
    end

    it 'leaves each side knowing how to reach the other' do
      pump_until([host, client]) { host.started? && client.started? }

      expect(host.transport.peers.values.map(&:player_id)).to eq([1])
      expect(client.transport.peers.values.map(&:player_id)).to include(0)
    end

    it 'survives a repeated hello without allocating a second slot' do
      pump_until([host, client]) { client.started? }
      3.times { client.send(:send_hello_if_waiting) }
      5.times { host.poll; sleep 0.005 }

      expect(host.transport.peers.size).to eq(1)
    end
  end

  describe 'three players' do
    it 'forms a full mesh rather than relaying through the host' do
      host = described_class.host(port: 0, players: 3)
      c1 = described_class.connect(host: '127.0.0.1', port: host.local_port)
      c2 = described_class.connect(host: '127.0.0.1', port: host.local_port)
      track(host, c1, c2)

      pump_until([host, c1, c2]) { [host, c1, c2].all?(&:started?) }

      expect([c1.local_id, c2.local_id]).to contain_exactly(1, 2)
      # Each client must know the host and the other client.
      expect(c1.transport.peers.values.map(&:player_id)).to contain_exactly(0, c2.local_id)
      expect(c2.transport.peers.values.map(&:player_id)).to contain_exactly(0, c1.local_id)
    end
  end

  describe 'play' do
    let(:host) { described_class.host(port: 0, players: 2, seed: 12) }
    let(:client) { described_class.connect(host: '127.0.0.1', port: host.local_port) }

    before do
      track(host, client)
      pump_until([host, client]) { host.started? && client.started? }
    end

    def cmd(id, i)
      Doom::Game::Ticcmd.new(id.zero? ? 1.0 : -1.0, 0.0, (i % 9) - 4.0,
                             (i % 5).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)
    end

    it 'reaches identical worlds through the session API alone' do
      sessions = [host, client]
      worlds = sessions.map { |s| world_for(s) }

      deadline = Time.now + 20
      i = 0
      until worlds.all? { |w| w.leveltime >= 150 }
        raise "stalled at #{worlds.map(&:leveltime).inspect}" if Time.now > deadline

        sessions.each_with_index do |s, idx|
          s.submit(cmd(s.local_id, i)) if s.lockstep.make_tic <= 150
          s.transmit
          s.poll
          s.run(worlds[idx], limit: 20)
        end
        i += 1
        sleep 0.001
      end

      expect(worlds[0].state_hash).to eq(worlds[1].state_hash)
      expect(sessions.map(&:desyncs)).to all(be_empty)
    end

    it 'says who it is waiting for when a peer goes quiet' do
      world = world_for(host)
      20.times { |i| host.submit(cmd(0, i)) }
      host.run(world)

      expect(host).to be_stalled
      expect(host.waiting_on).to eq([1])
    end

    it 'reports nobody to wait for before it stalls' do
      expect(host.waiting_on).to eq([])
    end

    describe 'stall duration' do
      # waiting_on is true almost all the time during healthy play: once the
      # ready tics have run, the next one lacks a command by definition. Only
      # the duration separates normal play from a peer in trouble, and without
      # it the on-screen warning is permanent.
      it 'stays below the warning threshold for the momentary waits of normal play' do
        world = world_for(host)
        host.submit(cmd(0, 0))
        host.run(world)

        # This is the healthy steady state: nothing left to run this instant.
        # It must not read as a problem.
        expect(host.stalled_seconds)
          .to be < described_class::STALL_WARNING_SECONDS
      end

      it 'starts counting only once nothing can advance' do
        world = world_for(host)
        20.times { |i| host.submit(cmd(0, i)) }
        host.run(world)  # runs the primed tics, then hits the gap

        expect(host).to be_stalled
        expect(host.stalled_seconds).to be >= 0.0

        sleep 0.05
        expect(host.stalled_seconds).to be > 0.02
      end

      it 'resets once the missing commands arrive' do
        world = world_for(host)
        20.times { |i| host.submit(cmd(0, i)) }
        host.run(world)
        sleep 0.05
        expect(host.stalled_seconds).to be > 0.0

        # Let the client catch up and deliver, then run again.
        deadline = Time.now + 5
        until host.stalled_seconds.zero? || Time.now > deadline
          20.times { |i| client.submit(cmd(1, i)) }
          client.transmit
          host.poll
          host.run(world)
          sleep 0.005
        end

        expect(host.stalled_seconds).to eq(0.0)
      end
    end
  end

  describe 'leaving' do
    it 'drops a peer that says goodbye' do
      host = described_class.host(port: 0, players: 2)
      client = described_class.connect(host: '127.0.0.1', port: host.local_port)
      track(host)
      pump_until([host, client]) { host.started? && client.started? }

      client.quit
      pump_until([host]) { host.transport.peers.empty? }
      expect(host.transport.peers).to be_empty
    end
  end
end
