# frozen_string_literal: true

module Doom
  module Net
    # The client half of the authoritative-server game. Talks only to the
    # server (outbound UDP, so NAT is a non-issue), joins by restoring a
    # snapshot of the live world, then follows the server's finalized frame
    # stream -- applying joins, leaves and commands in tic order -- so its world
    # stays byte-identical to the server's. It runs no simulation of its own and
    # never predicts: the local player sees their own input after the round trip
    # to the server and back, which is the price of a model where a dead phone
    # can't stall anyone.
    #
    # Everything is polled, never blocking, so the game keeps rendering while a
    # join is still in flight or a resync is underway.
    #
    # A join is a small state machine: HELLO -> WELCOME (who you are, which map)
    # -> SNAPSHOT chunks (the world) -> playing. HELLO is resent until WELCOME
    # arrives; if the snapshot never completes, or the frame stream leaves a gap
    # too old for the server's redundancy to fill, the client asks again and the
    # server sends a fresh snapshot at the current tic.
    class Client
      HELLO_RESEND_SECONDS = 0.25
      SYNC_TIMEOUT_SECONDS = 1.5   # No completed snapshot this long -> ask again
      # If the newest frame we've heard of is this far past the one we still
      # need, the missing one has aged out of the server's resend window and is
      # gone for good -- only a fresh snapshot recovers us.
      RESYNC_GAP_TICS = 12

      attr_reader :world, :local_id, :synced_tic

      # `load_map` is a callable name -> Map::MapData; the client learns which
      # map from WELCOME and has no other way to reach the WAD.
      def initialize(host:, port:, sprites:, load_map:, sound: nil,
                     clock: -> { Time.now }, transport: nil)
        @host = host
        @port = port
        @sprites = sprites
        @load_map = load_map
        @sound = sound
        @clock = clock
        @transport = transport || Transport.new
        reset_join
        @last_hello_at = nil
      end

      def local_port = @transport.local_port
      def connected? = !@local_id.nil?   # WELCOME received
      def playing? = !@world.nil?        # snapshot restored, following frames

      # Pump the network: chase the join if not yet playing, then drain and
      # apply whatever has arrived. Safe every frame.
      def poll
        send_hello_if_due
        @transport.poll.each { |msg, _host, _port| handle(msg) }
        resync_if_stuck
      end

      # Send this frame's input for future tics. `pairs` is [[tic, Ticcmd], ...];
      # recent inputs are repeated by the caller so a lost packet is covered.
      def send_input(pairs)
        return unless @local_id

        send_packet(Protocol.encode_input(@local_id, pairs))
      end

      def quit
        send_packet(Protocol.encode_quit(@local_id)) if @local_id && !@transport.closed?
        @transport.close
      end

      private

      def reset_join
        @local_id = nil
        @map_name = nil
        @snapshot_tic = nil
        @chunks = {}
        @chunk_total = nil
        @world = nil
        @synced_tic = nil
        @pending_frames = {}
        @synced_at = nil
      end

      def send_packet(bytes) = @transport.send_to_addr(@host, @port, bytes)

      def send_hello_if_due
        return if playing?

        now = @clock.call
        return if @last_hello_at && (now - @last_hello_at) < HELLO_RESEND_SECONDS

        @last_hello_at = now
        send_packet(Protocol.encode_hello)
      end

      def handle(msg)
        case msg[:type]
        when Protocol::WELCOME  then on_welcome(msg)
        when Protocol::SNAPSHOT then on_chunk(msg)
        when Protocol::FRAME    then on_frame(msg)
        end
      end

      # WELCOME may be the first one (join) or a fresh one answering a resync
      # request; either way we start reassembling the snapshot it names and drop
      # any stale in-progress reassembly for an older snapshot tic.
      def on_welcome(msg)
        return if @snapshot_tic == msg[:snapshot_tic] && @map_name

        @local_id = msg[:player_id]
        @map_name = msg[:map]
        @snapshot_tic = msg[:snapshot_tic]
        @map = @load_map.call(@map_name)
        @chunks = {}
        @chunk_total = nil
        @last_hello_at = @clock.call # a WELCOME resets the hello clock
      end

      def on_chunk(msg)
        return unless @snapshot_tic == msg[:snapshot_tic] && @map

        @chunk_total = msg[:total]
        @chunks[msg[:index]] = msg[:chunk]
        return unless @chunks.size == @chunk_total

        bytes = (0...@chunk_total).map { |i| @chunks[i] }.join
        @world = Game::Snapshot.load(bytes, map: @map, sprites: @sprites, sound: @sound)
        @synced_tic = @snapshot_tic
        @synced_at = @clock.call
        # Frames at or before the snapshot are already baked into it.
        @pending_frames.reject! { |tic, _| tic <= @synced_tic }
        drain_pending
      end

      def on_frame(msg)
        msg[:frames].each { |f| @pending_frames[f[:tic]] ||= f }
        drain_pending
      end

      # Apply every consecutive frame we have, in tic order. A missing tic stops
      # the drain -- lockstep can't skip -- and we wait for it to arrive (or for
      # resync_if_stuck to give up on it).
      def drain_pending
        return unless @synced_tic

        while (f = @pending_frames.delete(@synced_tic + 1))
          f[:joins].each { |id| @world.add_player(id: id) }
          f[:leaves].each { |id| @world.remove_player(id) }
          @world.run_tic(f[:cmds].to_h)
          @synced_tic += 1
          @synced_at = @clock.call
        end
        prune_pending
      end

      def prune_pending
        @pending_frames.reject! { |tic, _| tic <= @synced_tic }
      end

      # Ask for a fresh snapshot when the join stalls or an unfillable frame gap
      # opens. Re-sending HELLO is the request; the server answers an existing
      # client with a new WELCOME plus a snapshot at the current tic.
      def resync_if_stuck
        now = @clock.call

        if playing?
          newest = @pending_frames.keys.max
          gap = newest && (newest - @synced_tic) > RESYNC_GAP_TICS
          request_resync(now) if gap
        elsif connected? && @synced_at.nil?
          # WELCOME arrived but the snapshot never finished reassembling.
          request_resync(now) if @last_hello_at && (now - @last_hello_at) >= SYNC_TIMEOUT_SECONDS
        end
      end

      def request_resync(now)
        reset_join
        @last_hello_at = now
        send_packet(Protocol.encode_hello)
      end
    end
  end
end
