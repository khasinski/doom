# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Net::GameServer do
  # How far ahead a client labels its input. The server does not care what this
  # value is (it just files input under whatever future tic arrives), so it
  # lives here in the fake client rather than in the server.
  INPUT_LEAD = 2

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

  def new_world(seed: 1)
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    Doom::Game::World.new(map, sprites: @sprites, mode: :deathmatch,
                               random: Doom::Game::Random.new(seed))
  end

  # A hand-driven clock, so tics advance exactly when the test says.
  def clock
    @t ||= 0.0
    -> { @t }
  end

  def tick_clock(seconds)
    @t += seconds
  end

  def new_server(world: new_world, max_players: 8, client_timeout: 5.0)
    transport = track(Doom::Net::Transport.new(host: '127.0.0.1'))
    described_class.new(world: world, transport: transport, max_players: max_players,
                        clock: clock, client_timeout: client_timeout)
  end

  # A minimal client: exactly what the real one will do -- reassemble the
  # snapshot, then follow the frame stream, applying joins and leaves as the
  # tic events they are. Its world must stay identical to the server's.
  class Follower
    attr_reader :world, :player_id, :synced_tic

    def initialize(server, sprites, wad)
      @server = server
      @sprites = sprites
      @wad = wad
      @transport = Doom::Net::Transport.new(host: '127.0.0.1')
      @chunks = {}
      @pending_frames = {}
      @synced_tic = nil
    end

    attr_reader :transport

    def hello
      @transport.send_to_addr('127.0.0.1', @server.transport.local_port,
                              Doom::Net::Protocol.encode_hello)
    end

    def input(pairs)
      return unless @player_id

      @transport.send_to_addr('127.0.0.1', @server.transport.local_port,
                              Doom::Net::Protocol.encode_input(@player_id, pairs))
    end

    def poll
      @transport.poll.each do |msg, _h, _p|
        case msg[:type]
        when Doom::Net::Protocol::WELCOME  then on_welcome(msg)
        when Doom::Net::Protocol::SNAPSHOT then on_chunk(msg)
        when Doom::Net::Protocol::FRAME    then on_frame(msg)
        end
      end
    end

    def synced? = !@synced_tic.nil?
    def close = @transport.close

    private

    def on_welcome(msg)
      @player_id = msg[:player_id]
      @snapshot_tic = msg[:snapshot_tic]
      @map = Doom::Map::MapData.load(@wad, msg[:map])
    end

    def on_chunk(msg)
      return unless @snapshot_tic == msg[:snapshot_tic]

      @chunks[msg[:index]] = msg[:chunk]
      return unless @chunks.size == msg[:total] && @map

      bytes = (0...msg[:total]).map { |i| @chunks[i] }.join
      @world = Doom::Game::Snapshot.load(bytes, map: @map, sprites: @sprites)
      @synced_tic = @snapshot_tic
      drain_pending
    end

    def on_frame(msg)
      msg[:frames].each do |f|
        @pending_frames[f[:tic]] ||= f
      end
      drain_pending
    end

    def drain_pending
      return unless @synced_tic

      while (f = @pending_frames.delete(@synced_tic + 1))
        f[:joins].each { |id| @world.add_player(id: id) }
        f[:leaves].each { |id| @world.remove_player(id) }
        cmds = f[:cmds].to_h
        @world.run_tic(cmds)
        @synced_tic += 1
      end
    end
  end

  def new_follower(server)
    f = Follower.new(server, @sprites, @wad)
    track(f)
    f
  end

  # Run the server and a set of followers forward `tics` tics of wall clock,
  # pumping the network each step.
  def run(server, followers, tics:, input: nil)
    tics.times do |i|
      followers.each { |f| f.input(input.call(f, i)) if input && f.player_id }
      server.poll
      tick_clock(described_class::TIC_SECONDS)
      server.advance(limit: 4)
      followers.each(&:poll)
    end
    settle(server, followers)
  end

  # Let in-flight frames land so a follower is not compared one tic behind the
  # server purely because the last broadcast had not arrived when the loop
  # ended. Bounded, so a genuine desync still shows up as a stuck follower.
  def settle(server, followers, rounds: 20)
    rounds.times do
      break if followers.all? { |f| f.synced_tic == server.tic }

      server.poll
      followers.each(&:poll)
      sleep 0.002
    end
  end

  describe 'the deadline, without a socket' do
    it 'runs a tic per elapsed tic interval and no more' do
      server = new_server
      tick_clock(described_class::TIC_SECONDS * 3)
      expect(server.advance).to eq(3)
      expect(server.tic).to eq(3)
    end

    it 'fills a missing player command with neutral rather than stalling' do
      world = new_world
      world.add_player(id: 0)
      server = new_server(world: world)

      # Nobody sent input. The tic still runs.
      tick_clock(described_class::TIC_SECONDS)
      expect { server.advance }.to change(server, :tic).by(1)
    end

    it 'caps catch-up so a long pause cannot run unbounded tics at once' do
      server = new_server
      tick_clock(described_class::TIC_SECONDS * 100)
      expect(server.advance(limit: 5)).to eq(5)
    end
  end

  describe 'a client joining and following' do
    it 'reaches and holds the server world byte-for-byte' do
      server = new_server
      follower = new_follower(server)
      follower.hello

      # Let the join complete, then play a while with scripted input.
      script = lambda do |f, i|
        [[server.tic + INPUT_LEAD + 1,
          Doom::Game::Ticcmd.new(1.0, 0.0, (i % 5) - 2.0, 0)]]
      end
      run(server, [follower], tics: 60, input: script)

      expect(follower).to be_synced
      expect(follower.world.state_hash).to eq(server.world.state_hash)
      expect(follower.synced_tic).to eq(server.tic)
    end

    it 'spawns the joiner in the server world' do
      server = new_server
      follower = new_follower(server)
      follower.hello
      run(server, [follower], tics: 10)

      expect(server.world.players.map(&:id)).to include(follower.player_id)
    end
  end

  describe 'several clients' do
    it 'keeps every follower identical to the server' do
      server = new_server
      followers = Array.new(3) { new_follower(server) }
      followers.each(&:hello)

      script = lambda do |f, i|
        move = f.player_id.even? ? 1.0 : -1.0
        [[server.tic + INPUT_LEAD + 1,
          Doom::Game::Ticcmd.new(move, 0.0, (i % 7) - 3.0, (i % 6).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)]]
      end
      run(server, followers, tics: 80, input: script)

      followers.each do |f|
        expect(f).to be_synced
        expect(f.world.state_hash).to eq(server.world.state_hash), "follower #{f.player_id} diverged"
      end
    end

    it 'assigns distinct player ids' do
      server = new_server
      followers = Array.new(3) { new_follower(server) }
      followers.each(&:hello)
      run(server, followers, tics: 15)

      ids = followers.map(&:player_id)
      expect(ids.uniq).to eq(ids)
      expect(ids).to all(be_a(Integer))
    end
  end

  describe 'joining midway through a running match' do
    it 'catches a late joiner up via snapshot, synced with the server' do
      server = new_server
      early = new_follower(server)
      early.hello
      run(server, [early], tics: 100,
          input: ->(_f, i) { [[server.tic + 3, Doom::Game::Ticcmd.new(1.0, 0, (i % 5) - 2.0, 0)]] })

      late = new_follower(server)
      late.hello
      run(server, [early, late], tics: 60,
          input: ->(_f, i) { [[server.tic + 3, Doom::Game::Ticcmd.new(-1.0, 0, 0, 0)]] })

      expect(late).to be_synced
      expect(late.world.state_hash).to eq(server.world.state_hash)
      expect(early.world.state_hash).to eq(server.world.state_hash)
    end
  end

  describe 'a client leaving' do
    it 'removes a client that quits and keeps the rest synced' do
      server = new_server
      a = new_follower(server)
      b = new_follower(server)
      [a, b].each(&:hello)
      run(server, [a, b], tics: 30)

      a.transport.send_to_addr('127.0.0.1', server.transport.local_port,
                               Doom::Net::Protocol.encode_quit(a.player_id))
      run(server, [b], tics: 30)

      expect(server.world.players.map(&:id)).not_to include(a.player_id)
      expect(server.world.players.map(&:id)).to include(b.player_id)
      expect(b.world.state_hash).to eq(server.world.state_hash)
    end

    it 'reaps a client that has gone silent, without stalling anyone' do
      server = new_server(client_timeout: 0.3)
      a = new_follower(server)
      b = new_follower(server)
      [a, b].each(&:hello)
      run(server, [a, b], tics: 20)

      # a goes silent; only b keeps talking. Push the clock past the timeout.
      before = server.player_count
      40.times do
        b.input([[server.tic + 3, Doom::Game::Ticcmd.new(1.0, 0, 0, 0)]])
        sleep 0.002       # let b's packet actually arrive on loopback
        server.poll       # ...so the server refreshes b's last_seen
        tick_clock(described_class::TIC_SECONDS)
        server.reap       # a has been silent long enough; b has not
        server.advance(limit: 4)
        b.poll
      end
      settle(server, [b])

      expect(server.player_count).to eq(before - 1)
      expect(server.world.players.map(&:id)).to include(b.player_id)
      expect(b.world.state_hash).to eq(server.world.state_hash)
    end
  end

  describe 'a full roster' do
    it 'refuses a join once max_players is reached' do
      server = new_server(max_players: 2)
      a = new_follower(server)
      b = new_follower(server)
      [a, b].each(&:hello)
      run(server, [a, b], tics: 10)

      expect(server.player_count).to eq(2)

      late = new_follower(server)
      late.hello
      run(server, [late], tics: 10)

      # The server never welcomed the extra client, so it has no id, and the
      # roster is unchanged.
      expect(late.player_id).to be_nil
      expect(server.player_count).to eq(2)
    end
  end

  describe 'input spoofing' do
    it 'ignores commands carrying an id the client was not assigned' do
      server = new_server
      f = new_follower(server)
      f.hello
      run(server, [f], tics: 10)

      future = server.tic + 5
      spoof_id = f.player_id + 1
      real = Doom::Game::Ticcmd.new(1.0, 0, 0, 0)
      spoof = Doom::Game::Ticcmd.new(-1.0, 0, 0, 0)

      # A legitimate command for the client's own id, and a spoofed one claiming
      # to be another player, in separate packets from the same address.
      f.transport.send_to_addr('127.0.0.1', server.transport.local_port,
                               Doom::Net::Protocol.encode_input(f.player_id, [[future, real]]))
      f.transport.send_to_addr('127.0.0.1', server.transport.local_port,
                               Doom::Net::Protocol.encode_input(spoof_id, [[future, spoof]]))
      sleep 0.002
      server.poll

      inputs = server.instance_variable_get(:@inputs)
      expect(inputs[future]).to have_key(f.player_id)   # the honest one landed
      expect(inputs[future]).not_to have_key(spoof_id)  # the spoof was dropped
    end
  end
end
