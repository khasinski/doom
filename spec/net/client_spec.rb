# frozen_string_literal: true

require_relative '../spec_helper'

# Net::Client driven against a real Net::GameServer over loopback UDP. The one
# property that matters: a client's world, reached only by restoring a snapshot
# and following the server's frame stream, stays byte-identical to the server's.
RSpec.describe Doom::Net::Client do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  after { @closeables&.each { |t| t.close rescue nil } }

  def track(t)
    (@closeables ||= []) << t
    t
  end

  def clock
    @t ||= 0.0
    -> { @t }
  end

  def tick_clock(seconds) = @t += seconds

  def new_server(seed: 1, max_players: 8)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    world = Doom::Game::World.new(map, sprites: @sprites, mode: :deathmatch,
                                       random: Doom::Game::Random.new(seed))
    transport = track(Doom::Net::Transport.new(host: '127.0.0.1'))
    Doom::Net::GameServer.new(world: world, transport: transport,
                              max_players: max_players, clock: clock)
  end

  def new_client(server)
    transport = track(Doom::Net::Transport.new(host: '127.0.0.1'))
    described_class.new(host: '127.0.0.1', port: server.transport.local_port,
                        sprites: @sprites, clock: clock, transport: transport,
                        load_map: ->(name) { Doom::Map::MapData.load(@wad, name) })
  end

  # Advance the whole system `tics` tics of wall clock, pumping each side.
  def run(server, clients, tics:, input: nil)
    tics.times do |i|
      clients.each do |c|
        next unless input && c.local_id

        c.send_input([[server.tic + Doom::Net::GameServer::FRAME_REDUNDANCY,
                       input.call(c, i)]])
      end
      server.poll
      tick_clock(Doom::Net::GameServer::TIC_SECONDS)
      server.advance(limit: 4)
      clients.each(&:poll)
    end
    settle(server, clients)
  end

  # Let in-flight frames land so a client isn't compared a tic behind the server.
  def settle(server, clients, rounds: 40)
    rounds.times do
      break if clients.all? { |c| c.synced_tic == server.tic }

      server.poll
      clients.each(&:poll)
      sleep 0.002
    end
  end

  describe 'joining' do
    it 'restores the world from the snapshot and starts playing' do
      server = new_server
      client = new_client(server)
      run(server, [client], tics: 20)

      expect(client).to be_playing
      expect(client.local_id).to be_a(Integer)
      expect(client.world.state_hash).to eq(server.world.state_hash)
    end

    it 'is registered as a player on the server' do
      server = new_server
      client = new_client(server)
      run(server, [client], tics: 15)

      expect(server.world.players.map(&:id)).to include(client.local_id)
    end
  end

  describe 'following the frame stream' do
    it 'stays byte-identical to the server through scripted play' do
      server = new_server
      client = new_client(server)
      script = ->(_c, i) { Doom::Game::Ticcmd.new(1.0, 0.0, (i % 5) - 2.0, 0) }
      run(server, [client], tics: 80, input: script)

      expect(client.synced_tic).to eq(server.tic)
      expect(client.world.state_hash).to eq(server.world.state_hash)
    end

    it 'keeps several clients all identical to the server' do
      server = new_server
      clients = Array.new(3) { new_client(server) }
      script = lambda do |c, i|
        move = c.local_id.even? ? 1.0 : -1.0
        Doom::Game::Ticcmd.new(move, 0.0, (i % 7) - 3.0,
                               (i % 6).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)
      end
      run(server, clients, tics: 90, input: script)

      clients.each do |c|
        expect(c).to be_playing
        expect(c.world.state_hash).to eq(server.world.state_hash), "client #{c.local_id} diverged"
      end
    end
  end

  describe 'joining a match already in progress' do
    it 'catches a late client up via snapshot, synced with the server' do
      server = new_server
      early = new_client(server)
      run(server, [early], tics: 100,
          input: ->(_c, i) { Doom::Game::Ticcmd.new(1.0, 0, (i % 5) - 2.0, 0) })

      late = new_client(server)
      run(server, [early, late], tics: 60,
          input: ->(_c, i) { Doom::Game::Ticcmd.new(-1.0, 0, 0, 0) })

      expect(late).to be_playing
      expect(late.world.state_hash).to eq(server.world.state_hash)
      expect(early.world.state_hash).to eq(server.world.state_hash)
    end
  end

  describe 'leaving' do
    it 'is dropped from the server on quit' do
      server = new_server
      a = new_client(server)
      b = new_client(server)
      run(server, [a, b], tics: 30)
      left_id = a.local_id

      a.quit
      run(server, [b], tics: 30)

      expect(server.world.players.map(&:id)).not_to include(left_id)
      expect(b.world.state_hash).to eq(server.world.state_hash)
    end
  end

  describe 'recovering from an unfillable gap' do
    # A frame lost long enough to age out of the server's resend window can't
    # be filled by waiting; the client asks for a fresh snapshot and resumes.
    it 're-hellos and re-syncs when frames skip past the resync gap' do
      server = new_server
      client = new_client(server)
      run(server, [client], tics: 30)
      expect(client).to be_playing
      synced_before = client.synced_tic

      # Server runs on without the client hearing any frames.
      run(server, [], tics: 40)
      expect(server.tic).to be > synced_before + described_class::RESYNC_GAP_TICS

      # Feed the client a frame far ahead of where it stalled: the gap is
      # unrecoverable, so its next poll must trigger a re-hello (resync).
      far = server.tic
      client.send(:on_frame, { frames: [{ tic: far, joins: [], leaves: [], cmds: [] }] })
      client.send(:resync_if_stuck)

      # The re-hello reaches the server; it answers with a fresh snapshot and
      # the client catches back up.
      run(server, [client], tics: 30)

      expect(client).to be_playing
      expect(client.synced_tic).to eq(server.tic)
      expect(client.world.state_hash).to eq(server.world.state_hash)
    end
  end
end
