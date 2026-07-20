# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe Doom::Net::Protocol do
  def cmd(f = 1.0, s = -0.5, a = 2.25, b = Doom::Game::Ticcmd::BTN_FIRE)
    Doom::Game::Ticcmd.new(f, s, a, b)
  end

  describe 'hello' do
    it 'round-trips' do
      msg = described_class.decode(described_class.encode_hello('chris'))
      expect(msg[:type]).to eq(described_class::HELLO)
      expect(msg[:name]).to eq('chris')
    end

    it 'handles an empty name' do
      expect(described_class.decode(described_class.encode_hello)[:name]).to eq('')
    end
  end

  describe 'setup' do
    let(:packet) do
      described_class.encode_setup(player_id: 2, num_players: 4, seed: 77,
                                   map: 'E1M7', mode: :deathmatch, skill: 3)
    end

    it 'round-trips every field' do
      msg = described_class.decode(packet)
      expect(msg).to include(type: described_class::SETUP, player_id: 2, num_players: 4,
                             seed: 77, map: 'E1M7', mode: :deathmatch, skill: 3)
    end

    it 'defaults an unknown mode code to coop rather than failing' do
      expect(described_class.mode_name(200)).to eq(:coop)
    end

    it 'round-trips coop' do
      p = described_class.encode_setup(player_id: 0, num_players: 2, seed: 1,
                                       map: 'E1M1', mode: :coop, skill: 2)
      expect(described_class.decode(p)[:mode]).to eq(:coop)
    end
  end

  describe 'ticcmds' do
    it 'round-trips a batch with its tic numbers' do
      pairs = [[100, cmd(1.0)], [101, cmd(-1.0)], [102, cmd(0.0)]]
      msg = described_class.decode(described_class.encode_ticcmds(1, pairs))

      expect(msg[:type]).to eq(described_class::TICCMD)
      expect(msg[:player_id]).to eq(1)
      expect(msg[:cmds].map(&:first)).to eq([100, 101, 102])
      expect(msg[:cmds][0][1].forwardmove).to be_within(1e-3).of(1.0)
      expect(msg[:cmds][1][1].forwardmove).to be_within(1e-3).of(-1.0)
    end

    it 'preserves buttons' do
      msg = described_class.decode(described_class.encode_ticcmds(0, [[5, cmd]]))
      expect(msg[:cmds][0][1]).to be_fire
    end

    it 'handles an empty batch' do
      msg = described_class.decode(described_class.encode_ticcmds(0, []))
      expect(msg[:cmds]).to eq([])
    end

    it 'carries the ack so peers know where to resend from' do
      msg = described_class.decode(described_class.encode_ticcmds(0, [[9, cmd]], ack: 7))
      expect(msg[:ack]).to eq(7)
    end

    it 'defaults the ack to zero' do
      expect(described_class.decode(described_class.encode_ticcmds(0, []))[:ack]).to eq(0)
    end

    it 'survives a large ack' do
      msg = described_class.decode(described_class.encode_ticcmds(0, [], ack: 4_000_000_000))
      expect(msg[:ack]).to eq(4_000_000_000)
    end

    it 'survives a large tic number' do
      msg = described_class.decode(described_class.encode_ticcmds(0, [[4_000_000_000, cmd]]))
      expect(msg[:cmds][0][0]).to eq(4_000_000_000)
    end

    it 'caps the batch so a packet cannot grow without bound' do
      pairs = Array.new(500) { |i| [i, cmd] }
      packet = described_class.encode_ticcmds(0, pairs)

      expect(packet.bytesize).to be <= described_class::MAX_PACKET_SIZE
      expect(described_class.decode(packet)[:cmds].size).to eq(described_class::MAX_CMDS_PER_PACKET)
    end

    it 'keeps the most recent commands when capping' do
      pairs = Array.new(100) { |i| [i, cmd] }
      cmds = described_class.decode(described_class.encode_ticcmds(0, pairs))[:cmds]
      expect(cmds.last.first).to eq(99)
    end
  end

  describe 'hash' do
    let(:sections) { Doom::Game::StateHash::SECTIONS.each_with_index.to_h { |s, i| [s, i * 1000] } }

    it 'round-trips every section' do
      msg = described_class.decode(described_class.encode_hash(350, 1, sections))
      expect(msg[:type]).to eq(described_class::HASH)
      expect(msg[:tic]).to eq(350)
      expect(msg[:player_id]).to eq(1)
      expect(msg[:sections]).to eq(sections)
    end

    it 'survives full 32-bit section values' do
      big = Doom::Game::StateHash::SECTIONS.to_h { |s| [s, 4_294_967_295] }
      expect(described_class.decode(described_class.encode_hash(1, 0, big))[:sections]).to eq(big)
    end

    it 'carries a real world fingerprint' do
      skip_without_wad
      wad = Doom::Wad::Reader.new(wad_path)
      map = Doom::Map::MapData.load(wad, 'E1M1')
      world = Doom::Game::World.new(map, sprites: Doom::Wad::SpriteManager.new(wad))
      world.add_player

      msg = described_class.decode(described_class.encode_hash(35, 0, world.state_hash_sections))
      expect(msg[:sections]).to eq(world.state_hash_sections)
      wad.close
    end
  end

  describe 'peers' do
    let(:entries) { [[0, '192.168.1.10', 5029], [2, '10.0.0.3', 40_000]] }

    it 'round-trips the address list' do
      msg = described_class.decode(described_class.encode_peers(entries))
      expect(msg[:type]).to eq(described_class::PEERS)
      expect(msg[:peers]).to eq(entries)
    end

    it 'handles an empty list' do
      expect(described_class.decode(described_class.encode_peers([]))[:peers]).to eq([])
    end

    it 'survives a high port number' do
      msg = described_class.decode(described_class.encode_peers([[1, '127.0.0.1', 65_535]]))
      expect(msg[:peers].first.last).to eq(65_535)
    end

    it 'drops a truncated list' do
      packet = described_class.encode_peers(entries)
      expect(described_class.decode(packet[0, packet.bytesize - 3])).to be_nil
    end

    it 'never raises on truncation at any length' do
      packet = described_class.encode_peers(entries)
      (0..packet.bytesize).each do |n|
        expect { described_class.decode(packet[0, n]) }.not_to raise_error
      end
    end
  end

  describe 'quit' do
    it 'round-trips' do
      msg = described_class.decode(described_class.encode_quit(3))
      expect(msg).to eq(type: described_class::QUIT, player_id: 3)
    end
  end

  # These bytes arrive from the network. Nothing here may raise.
  describe 'hostile input' do
    it 'drops nil and empty input' do
      expect(described_class.decode(nil)).to be_nil
      expect(described_class.decode('')).to be_nil
    end

    it 'drops a wrong protocol version' do
      packet = described_class.encode_quit(1).dup
      packet[0] = [described_class::VERSION + 1].pack('C')
      expect(described_class.decode(packet)).to be_nil
    end

    it 'drops an unknown packet type' do
      expect(described_class.decode([described_class::VERSION, 99].pack('CC'))).to be_nil
    end

    it 'drops a ticcmd packet whose body is short of its stated count' do
      packet = described_class.encode_ticcmds(0, [[1, cmd], [2, cmd]])
      expect(described_class.decode(packet[0, packet.bytesize - 4])).to be_nil
    end

    it 'drops a truncated hash packet' do
      packet = described_class.encode_hash(1, 0, Doom::Game::StateHash::SECTIONS.to_h { |s| [s, 1] })
      expect(described_class.decode(packet[0, 8])).to be_nil
    end

    it 'drops a setup packet with a truncated map name' do
      packet = described_class.encode_setup(player_id: 0, num_players: 2, seed: 1,
                                            map: 'E1M1', mode: :coop, skill: 2)
      expect(described_class.decode(packet[0, packet.bytesize - 2])).to be_nil
    end

    it 'never raises on arbitrary bytes' do
      rng = Random.new(1234)
      500.times do
        junk = Array.new(rng.rand(0..64)) { rng.rand(256) }.pack('C*')
        expect { described_class.decode(junk) }.not_to raise_error
      end
    end

    it 'never raises on corrupted valid packets' do
      rng = Random.new(99)
      base = described_class.encode_ticcmds(1, [[10, cmd], [11, cmd]])
      300.times do
        bytes = base.dup
        bytes[rng.rand(bytes.bytesize)] = [rng.rand(256)].pack('C')
        expect { described_class.decode(bytes) }.not_to raise_error
      end
    end

    it 'never raises on truncation at any length' do
      base = described_class.encode_setup(player_id: 1, num_players: 2, seed: 3,
                                          map: 'E1M1', mode: :coop, skill: 2)
      (0..base.bytesize).each do |n|
        expect { described_class.decode(base[0, n]) }.not_to raise_error
      end
    end
  end
end
