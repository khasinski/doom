# frozen_string_literal: true

require_relative '../spec_helper'

# These talk over a real loopback socket rather than a stubbed one: the point
# of this class is that datagrams actually arrive, which a double cannot show.
RSpec.describe Doom::Net::Transport do
  let(:a) { described_class.new(host: '127.0.0.1') }
  let(:b) { described_class.new(host: '127.0.0.1') }

  after do
    a.close
    b.close
  end

  # UDP gives no delivery guarantee even on loopback, so wait briefly rather
  # than assuming the packet is already there.
  def poll_until(transport, timeout: 2.0)
    deadline = Time.now + timeout
    loop do
      msgs = transport.poll
      return msgs unless msgs.empty?
      return [] if Time.now > deadline
      sleep 0.005
    end
  end

  def cmd(f = 1.0)
    Doom::Game::Ticcmd.new(f, 0.0, 0.0, 0)
  end

  describe 'binding' do
    it 'picks a free port when asked for zero' do
      expect(a.local_port).to be > 0
    end

    it 'reports being closed' do
      t = described_class.new(host: '127.0.0.1')
      expect(t).not_to be_closed
      t.close
      expect(t).to be_closed
    end

    it 'tolerates being closed twice' do
      t = described_class.new(host: '127.0.0.1')
      t.close
      expect { t.close }.not_to raise_error
    end
  end

  describe 'peers' do
    it 'registers and finds a peer' do
      peer = a.add_peer('127.0.0.1', 5029, player_id: 1)
      expect(a.peer_for('127.0.0.1', 5029)).to equal(peer)
      expect(peer.player_id).to eq(1)
    end

    it 'does not duplicate the same address' do
      a.add_peer('127.0.0.1', 5029)
      a.add_peer('127.0.0.1', 5029)
      expect(a.peers.size).to eq(1)
    end
  end

  describe 'delivery' do
    it 'delivers ticcmds between two sockets' do
      peer = a.add_peer('127.0.0.1', b.local_port, player_id: 1)
      a.send_to(peer, Doom::Net::Protocol.encode_ticcmds(0, [[7, cmd(1.0)], [8, cmd(-1.0)]]))

      msgs = poll_until(b)
      expect(msgs.size).to eq(1)

      msg, host, port = msgs.first
      expect(msg[:type]).to eq(Doom::Net::Protocol::TICCMD)
      expect(msg[:player_id]).to eq(0)
      expect(msg[:cmds].map(&:first)).to eq([7, 8])
      expect(host).to eq('127.0.0.1')
      expect(port).to eq(a.local_port)
    end

    it 'reports the sender so a peer can be learned from its first packet' do
      peer = a.add_peer('127.0.0.1', b.local_port)
      a.send_to(peer, Doom::Net::Protocol.encode_hello)

      _, host, port = poll_until(b).first
      expect(b.peer_for(host, port)).to be_nil
      learned = b.add_peer(host, port, player_id: 0)
      expect(learned.port).to eq(a.local_port)
    end

    it 'broadcasts to every peer' do
      c = described_class.new(host: '127.0.0.1')
      a.add_peer('127.0.0.1', b.local_port)
      a.add_peer('127.0.0.1', c.local_port)
      a.broadcast(Doom::Net::Protocol.encode_quit(0))

      expect(poll_until(b).size).to eq(1)
      expect(poll_until(c).size).to eq(1)
      c.close
    end

    it 'returns nothing when idle instead of blocking' do
      expect(a.poll).to eq([])
    end

    it 'drains several packets in one poll' do
      peer = a.add_peer('127.0.0.1', b.local_port)
      5.times { |i| a.send_to(peer, Doom::Net::Protocol.encode_ticcmds(0, [[i, cmd]])) }

      received = []
      deadline = Time.now + 2.0
      received.concat(b.poll) while received.size < 5 && Time.now < deadline
      expect(received.size).to eq(5)
    end

    it 'bounds how much it takes in one poll' do
      peer = a.add_peer('127.0.0.1', b.local_port)
      10.times { |i| a.send_to(peer, Doom::Net::Protocol.encode_ticcmds(0, [[i, cmd]])) }
      sleep 0.05

      expect(b.poll(max: 3).size).to be <= 3
    end
  end

  describe 'robustness' do
    it 'drops undecodable datagrams without raising' do
      raw = UDPSocket.new
      raw.send('not a doom packet', 0, '127.0.0.1', b.local_port)
      raw.close
      sleep 0.05

      expect(b.poll).to eq([])
    end

    it 'keeps working after receiving junk' do
      raw = UDPSocket.new
      raw.send("\x00\xFF garbage", 0, '127.0.0.1', b.local_port)
      raw.close
      sleep 0.05
      b.poll

      peer = a.add_peer('127.0.0.1', b.local_port)
      a.send_to(peer, Doom::Net::Protocol.encode_quit(1))
      expect(poll_until(b).first.first[:type]).to eq(Doom::Net::Protocol::QUIT)
    end

    it 'reports failure instead of raising when a send cannot go out' do
      peer = a.add_peer('127.0.0.1', b.local_port)
      a.close
      expect { a.send_to(peer, Doom::Net::Protocol.encode_quit(0)) }.not_to raise_error
    end

    it 'returns no messages once closed' do
      a.close
      expect(a.poll).to eq([])
    end
  end
end
