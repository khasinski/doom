# frozen_string_literal: true

require 'socket'

module Doom
  module Net
    # Non-blocking UDP for both multiplayer stacks: the peer-to-peer lockstep
    # mesh (send_to/broadcast over the peer table) and the authoritative star
    # server (send_to_addr, replying straight to whoever a packet came from).
    #
    # UDP rather than TCP because a late ticcmd is worthless: head-of-line
    # blocking would make one lost packet stall everything behind it, which is
    # the opposite of what we want when the payload is already resent by the
    # next packet anyway.
    #
    # Nothing here retries or acknowledges. Loss is handled a layer up, by
    # Lockstep resending recent commands, and ordering is handled by the tic
    # numbers inside the packets.
    class Transport
      Peer = Struct.new(:host, :port, :player_id) do
        def key
          "#{host}:#{port}"
        end
      end

      MAX_DATAGRAM = 2048

      attr_reader :peers

      def initialize(port: 0, host: '0.0.0.0')
        @socket = UDPSocket.new
        @socket.bind(host, port)
        @peers = {}
      end

      def local_port
        @socket.addr[1]
      end

      def add_peer(host, port, player_id: nil)
        peer = Peer.new(host, port, player_id)
        @peers[peer.key] = peer
        peer
      end

      def peer_for(host, port)
        @peers["#{host}:#{port}"]
      end

      def send_to(peer, bytes)
        return false if closed?

        @socket.send(bytes, 0, peer.host, peer.port)
        true
      rescue SystemCallError, IOError
        # A peer that has gone away must not take the session down with it;
        # the lockstep layer already notices them by stalling.
        false
      end

      # Send to a bare address, without registering it as a peer. The game
      # server tracks its clients itself and replies to wherever a packet came
      # from, so it does not want the peer table.
      def send_to_addr(host, port, bytes)
        return false if closed?

        @socket.send(bytes, 0, host, port)
        true
      rescue SystemCallError, IOError
        false
      end

      def broadcast(bytes)
        @peers.each_value { |peer| send_to(peer, bytes) }
      end

      # Drain what has arrived, decoded. Returns [[message, host, port], ...].
      # `max` bounds the work per frame so a flood cannot starve rendering.
      #
      # Undecodable packets are dropped silently: on an open port anyone can
      # send anything, and it is not worth a log line per stray datagram.
      def poll(max: 64)
        return [] if closed?

        messages = []
        max.times do
          begin
            data, addr = @socket.recvfrom_nonblock(MAX_DATAGRAM)
          rescue IO::WaitReadable, Errno::EWOULDBLOCK, Errno::EAGAIN
            break
          rescue SystemCallError, IOError
            break
          end

          msg = Protocol.decode(data)
          messages << [msg, addr[3], addr[1]] if msg
        end
        messages
      end

      def close
        @socket.close unless @socket.closed?
      end

      def closed?
        @socket.closed?
      end
    end
  end
end
