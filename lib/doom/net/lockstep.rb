# frozen_string_literal: true

module Doom
  module Net
    # Lockstep tic scheduling, with no socket attached.
    #
    # Every peer simulates every player. Only ticcmds travel, and a tic runs
    # only once the commands of all players for that tic are in hand. Two peers
    # feeding equal commands to equal worlds stay equal; nothing else needs to
    # be synchronised.
    #
    # Local input is scheduled `delay` tics into the future, which is what buys
    # the network time to deliver it: input sampled now is consumed a few tics
    # from now, by which point everyone has it. The first `delay` tics run on
    # neutral commands, so the game starts without waiting for anybody.
    #
    # When a command is missing the simulation stalls rather than guessing.
    # That is the deal lockstep makes: everyone waits for the slowest peer, and
    # nobody ever has to take back something that already happened.
    class Lockstep
      DEFAULT_DELAY = 2  # ~57ms at 35Hz

      attr_reader :local_id, :player_ids, :delay, :next_tic, :sample_tic

      def initialize(local_id:, player_ids:, delay: DEFAULT_DELAY)
        raise ArgumentError, 'delay must be >= 1' if delay < 1
        raise ArgumentError, 'local_id must be one of player_ids' unless player_ids.include?(local_id)

        @local_id = local_id
        @player_ids = player_ids.dup.freeze
        @delay = delay
        @buffer = {}       # tic => { player_id => Ticcmd }
        @peer_acks = {}    # player_id => lowest tic they still need
        @local_sent = {}   # tic => Ticcmd, kept for retransmission padding
        @next_tic = 1      # next tic to simulate
        @sample_tic = delay + 1  # tic the next local sample is for

        # Prime the opening tics so play starts immediately instead of waiting
        # a delay's worth of round trips for commands nobody has sent yet.
        (1..delay).each do |tic|
          @player_ids.each { |id| store(tic, id, Game::Ticcmd.none) }
        end
      end

      # Schedule this frame's input. Returns the tic it was scheduled for, which
      # is what the sender must label the outgoing packet with.
      def submit_local(cmd)
        tic = @sample_tic
        @sample_tic += 1
        store(tic, @local_id, cmd)
        @local_sent[tic] = cmd
        # Prune here too, not only when tics run: a stalled peer keeps sampling
        # input while unable to advance, which is exactly when the history
        # would otherwise grow without bound.
        prune
        tic
      end

      # A command from a peer. Commands for tics already simulated are dropped;
      # duplicates are ignored rather than overwriting, since the transport
      # deliberately resends recent commands and a late copy must not change a
      # tic that is already decided.
      def receive(tic, player_id, cmd)
        return false if tic < @next_tic
        return false unless @player_ids.include?(player_id)
        return false if @buffer.dig(tic, player_id)

        store(tic, player_id, cmd)
        true
      end

      def ready?
        missing_for(@next_tic).empty?
      end

      # Players holding up the current tic. Worth surfacing: a stall with no
      # explanation looks like a freeze.
      def waiting_on
        missing_for(@next_tic)
      end

      def stalled?
        !ready?
      end

      # Commands for the current tic, advancing to the next. Returns nil if the
      # tic is not ready.
      def take_cmds
        return nil unless ready?

        cmds = @buffer.delete(@next_tic)
        @next_tic += 1
        prune
        cmds
      end

      # Run every tic whose commands have arrived. Returns how many ran, so a
      # caller can tell a stall from an idle moment.
      def run_ready(world, limit: 10)
        ran = 0
        while ran < limit && (cmds = take_cmds)
          world.run_tic(cmds)
          ran += 1
        end
        ran
      end

      # Local commands to put in a packet for a peer that is waiting on `ack`.
      #
      # Resending from the peer's own position, rather than just the newest
      # few, is what makes loss survivable: a fixed window drops a command for
      # good once it slides past, and lockstep never skips a tic, so both sides
      # would deadlock on it. `count` still bounds the packet.
      def local_since(ack, count)
        tics = @local_sent.keys.sort
        pending = tics.select { |tic| tic >= ack }
        pending = tics.last(count) if pending.empty?
        pending.first(count).map { |tic| [tic, @local_sent[tic]] }
      end

      # The lowest tic still missing locally: what peers should resend from.
      def ack_tic
        @next_tic
      end

      # Where a peer says it has got to. Recorded so we never discard a command
      # that somebody still needs.
      def note_ack(player_id, tic)
        return unless @player_ids.include?(player_id) && player_id != @local_id

        current = @peer_acks[player_id]
        @peer_acks[player_id] = tic if current.nil? || tic > current
      end

      private

      def store(tic, player_id, cmd)
        (@buffer[tic] ||= {})[player_id] = cmd
      end

      def missing_for(tic)
        have = @buffer[tic] || {}
        @player_ids.reject { |id| have.key?(id) }
      end

      # Sent commands are kept until every peer has acknowledged them, not for a
      # fixed number of tics. A peer stalled on a tic we already ran is freed
      # only by us resending it, and if we have thrown it away it exists
      # nowhere: they wait forever. That is what a paused peer looks like --
      # it stops acknowledging, and a fixed window of 64 tics meant any pause
      # longer than two seconds permanently broke the session.
      #
      # LOCAL_HISTORY is now only a backstop against a peer that is never
      # coming back, at roughly a minute of tics rather than two seconds.
      LOCAL_HISTORY = 2048

      def prune
        @buffer.delete_if { |tic, _| tic < @next_tic }

        # Anything at or above the least-caught-up peer must be kept.
        floor = @peer_acks.values.min
        @local_sent.delete_if { |tic, _| floor && tic < floor }
        return if @local_sent.size <= LOCAL_HISTORY

        keep = @local_sent.keys.sort.last(LOCAL_HISTORY)
        @local_sent.select! { |tic, _| keep.include?(tic) }
      end
    end
  end
end
