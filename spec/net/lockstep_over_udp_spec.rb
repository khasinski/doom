# frozen_string_literal: true

require_relative '../spec_helper'

# The whole point of the stack, exercised together over real sockets: two
# peers exchanging nothing but ticcmds must end up with identical worlds.
RSpec.describe 'lockstep over UDP' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  SEED = 21
  IDS = [0, 1].freeze

  # One peer: its socket, its copy of the world, and its tic scheduler.
  class Peer
    attr_reader :id, :world, :lockstep, :transport, :monitor

    def initialize(id, world, delay: 2)
      @id = id
      @world = world
      @transport = Doom::Net::Transport.new(host: '127.0.0.1')
      @lockstep = Doom::Net::Lockstep.new(local_id: id, player_ids: IDS, delay: delay)
      @monitor = Doom::Net::DesyncMonitor.new(interval: 35)
      @drop = 0.0
      @rng = Random.new(id + 1)
      @peer_ack = Hash.new(0)
    end

    attr_accessor :drop

    def connect(other)
      @transport.add_peer('127.0.0.1', other.transport.local_port, player_id: other.id)
    end

    def submit(cmd)
      @lockstep.submit_local(cmd)
    end

    # Transmit is separate from sampling on purpose: a peer that has finished
    # sampling still has to keep resending, or a peer stalled on a lost command
    # would never be freed.
    def transmit(redundancy: 8)
      return if @rng.rand < @drop  # simulated packet loss

      @transport.peers.each_value do |peer|
        @transport.send_to(peer, Doom::Net::Protocol.encode_ticcmds(
          @id, @lockstep.local_since(@peer_ack[peer.player_id], redundancy),
          ack: @lockstep.ack_tic
        ))
      end
    end

    def send_input(cmd)
      submit(cmd)
      transmit
    end

    def receive
      @transport.poll.each do |msg, _host, _port|
        case msg[:type]
        when Doom::Net::Protocol::TICCMD
          @peer_ack[msg[:player_id]] = msg[:ack].to_i
          msg[:cmds].each { |tic, cmd| @lockstep.receive(tic, msg[:player_id], cmd) }
        when Doom::Net::Protocol::HASH
          @monitor.remote_report(msg[:tic], msg[:player_id], msg[:sections])
        end
      end
    end

    def run
      @lockstep.run_ready(@world, limit: 20)
    end

    # Fingerprint on checkpoint tics and tell the others.
    def report_hash
      sections = @monitor.record(@world.leveltime, @world)
      return unless sections

      @transport.broadcast(Doom::Net::Protocol.encode_hash(@world.leveltime, @id, sections))
    end

    def close
      @transport.close
    end
  end

  def new_world
    map = Doom::Map::MapData.load(@wad, 'E1M1')
    w = Doom::Game::World.new(map, sprites: @sprites, random: Doom::Game::Random.new(SEED))
    IDS.each { |id| w.add_player(id: id) }
    w
  end

  def scripted_cmd(player_id, i)
    if player_id.zero?
      Doom::Game::Ticcmd.new(1.0, 0.0, (i % 9) - 4.0,
                             (i % 5).zero? ? Doom::Game::Ticcmd::BTN_FIRE : 0)
    else
      Doom::Game::Ticcmd.new(-1.0, 1.0, 3.0 - (i % 7),
                             (i % 8).zero? ? Doom::Game::Ticcmd::BTN_USE : 0)
    end
  end

  # Drive both peers until they have simulated `target` tics, or give up.
  def play(peers, target:, timeout: 20.0)
    deadline = Time.now + timeout
    i = 0
    until peers.all? { |p| p.world.leveltime >= target }
      raise "stalled at #{peers.map { |p| p.world.leveltime }.inspect}" if Time.now > deadline

      peers.each { |p| p.submit(scripted_cmd(p.id, i)) if p.lockstep.make_tic <= target }
      peers.each(&:transmit)  # always, even once sampling is done
      peers.each(&:receive)
      peers.each(&:run)
      peers.each(&:report_hash)
      i += 1
      sleep 0.001
    end
  end

  around do |example|
    @peers = [Peer.new(0, new_world), Peer.new(1, new_world)]
    @peers[0].connect(@peers[1])
    @peers[1].connect(@peers[0])
    example.run
  ensure
    @peers&.each(&:close)
  end

  it 'keeps both worlds identical over a real socket' do
    play(@peers, target: 200)

    a, b = @peers
    expect(a.world.leveltime).to eq(b.world.leveltime)
    expect(a.world.state_hash).to eq(b.world.state_hash)
  end

  it 'moves both players, so the comparison is not of two idle worlds' do
    play(@peers, target: 120)

    a = @peers.first.world
    IDS.each do |id|
      start = a.map.player_start_for(id)
      moved = Math.hypot(a.player(id).x - start.x, a.player(id).y - start.y)
      expect(moved).to be > 10
    end
  end

  it 'reports no desync during a clean session' do
    play(@peers, target: 150)
    expect(@peers.map(&:monitor)).to all(satisfy { |m| !m.desynced? })
  end

  it 'survives heavy packet loss, because commands are resent' do
    # Each peer drops 30% of its outgoing packets. Lockstep carries the last
    # few commands in every packet, so a loss costs latency, not correctness.
    @peers.each { |p| p.drop = 0.3 }
    play(@peers, target: 150, timeout: 30.0)

    a, b = @peers
    expect(a.world.state_hash).to eq(b.world.state_hash)
    expect(a.monitor).not_to be_desynced
  end

  it 'stalls rather than diverging when a peer goes silent' do
    a, b = @peers
    play(@peers, target: 40)
    before = a.world.leveltime

    b.drop = 1.0  # b stops transmitting entirely
    20.times do |i|
      a.send_input(scripted_cmd(0, i))
      b.send_input(scripted_cmd(1, i))
      a.receive
      a.run
      sleep 0.001
    end

    # a runs out the commands it already has, then waits for b -- it must not
    # invent them.
    expect(a.world.leveltime).to be < before + 20
    expect(a.lockstep.waiting_on).to eq([1])
  end
end
