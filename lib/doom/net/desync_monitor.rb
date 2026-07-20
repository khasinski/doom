# frozen_string_literal: true

module Doom
  module Net
    # Watches for lockstep divergence.
    #
    # Each peer fingerprints its world every CHECK_INTERVAL tics and broadcasts
    # the result. When two peers report different fingerprints for the same
    # tic, their simulations have already diverged and every tic after it is
    # meaningless. The job here is to say so at the tic it happened, with
    # enough detail to diagnose it, instead of letting the games drift apart
    # while both players wonder why the other is shooting at nothing.
    #
    # Peers exchange per-section hashes, not just the folded one: five extra
    # numbers a second is nothing on the wire, and it turns "something
    # diverged" into "the monsters diverged", which is the difference between
    # an alarming report and a useful one.
    #
    # Reports can arrive before or after the local check for the same tic, so
    # both directions are buffered and compared whenever a pair completes.
    class DesyncMonitor
      CHECK_INTERVAL = 35   # One second at DOOM's tic rate
      HISTORY_TICS = 350    # Keep ~10s; enough to pair up late reports

      Desync = Struct.new(:tic, :peer_id, :local, :remote, :sections, keyword_init: true) do
        def message
          where = sections.nil? || sections.empty? ? 'unknown section' : sections.join(', ')
          "desync at tic #{tic} with peer #{peer_id}: " \
            "local #{format('%08x', local)} != remote #{format('%08x', remote)} (#{where})"
        end
      end

      attr_reader :desyncs

      # `on_desync` is called with a Desync the moment one is detected.
      def initialize(interval: CHECK_INTERVAL, &on_desync)
        @interval = interval
        @on_desync = on_desync
        @local = {}    # tic => section hashes
        @remote = {}   # tic => { peer_id => section hashes }
        @desyncs = []
      end

      def check_due?(tic)
        (tic % @interval).zero?
      end

      # Fingerprint the world if this tic is a checkpoint. Returns the section
      # hashes to broadcast, or nil on a tic that is not checked.
      def record(tic, world)
        return nil unless check_due?(tic)

        sections = world.state_hash_sections
        @local[tic] = sections
        compare(tic)
        prune(tic)
        sections
      end

      # Section hashes received from another peer.
      def remote_report(tic, peer_id, sections)
        (@remote[tic] ||= {})[peer_id] = sections
        compare(tic)
      end

      def desynced?
        !@desyncs.empty?
      end

      private

      def compare(tic)
        local = @local[tic]
        peers = @remote[tic]
        return unless local && peers

        peers.each do |peer_id, remote|
          local_hash = Game::StateHash.fold(local)
          remote_hash = Game::StateHash.fold(remote)
          next if local_hash == remote_hash
          next if @desyncs.any? { |d| d.tic == tic && d.peer_id == peer_id }

          differing = Game::StateHash::SECTIONS.reject { |s| local[s] == remote[s] }
          desync = Desync.new(tic: tic, peer_id: peer_id,
                              local: local_hash, remote: remote_hash, sections: differing)
          @desyncs << desync
          @on_desync&.call(desync)
        end
      end

      # Bound memory: a long session would otherwise keep every checkpoint.
      def prune(tic)
        cutoff = tic - HISTORY_TICS
        return if cutoff <= 0

        @local.delete_if { |t, _| t < cutoff }
        @remote.delete_if { |t, _| t < cutoff }
      end
    end
  end
end
