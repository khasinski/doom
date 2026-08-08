# frozen_string_literal: true

module Doom
  module Net
    # The authoritative game server for large, chaotic sessions.
    #
    # Peer-to-peer lockstep does not survive a conference: with mobile clients
    # behind CGNAT they cannot reach each other, and lockstep makes everyone
    # wait for the slowest, so the first person to close their laptop freezes
    # the match. This server fixes both. Clients speak only to it (outbound
    # UDP, so NAT is a non-issue), and it never waits: on every tic it takes
    # whatever input has arrived, fills the gaps with neutral commands, runs
    # the tic, and broadcasts the finalized result. A player whose phone dies
    # simply stops acting -- nobody else is held up.
    #
    # It is still deterministic underneath: it holds the one canonical world,
    # every client runs the identical command stream, and joins and leaves are
    # tic events (a deathmatch spawn draws the shared RNG, so it must happen on
    # the same tic everywhere). Because it holds the canonical world, it can
    # hand a late joiner a snapshot of the exact current state instead of
    # making them replay the match from the start.
    #
    # Nothing here blocks. `poll` drains the socket, `advance` runs whatever
    # tics are due against an injected clock; a host loops them.
    class GameServer
      TICRATE = 35
      TIC_SECONDS = 1.0 / TICRATE
      FRAME_REDUNDANCY = 6   # Recent frames repeated per packet against loss
      CLIENT_TIMEOUT = 5.0   # Drop a client silent this long

      Client = Struct.new(:player_id, :host, :port, :last_seen, :joined) do
        def key = "#{host}:#{port}"
      end

      attr_reader :world, :transport, :tic, :clients

      def initialize(world:, transport:, max_players: 16, clock: -> { Time.now },
                     client_timeout: CLIENT_TIMEOUT)
        @world = world
        @transport = transport
        @max_players = max_players
        @clock = clock
        @client_timeout = client_timeout
        @tic = world.leveltime
        @start_tic = world.leveltime
        @start_time = @clock.call

        @clients = {}                 # addr key => Client
        @by_id = {}                   # player_id => Client
        @inputs = Hash.new { |h, k| h[k] = {} } # tic => { player_id => Ticcmd }
        @pending_joins = []           # player ids to add on the next tic
        @pending_leaves = []          # player ids to remove on the next tic
        @frame_log = []               # recent finalized frames, for redundancy
      end

      # Drain and dispatch whatever has arrived. Safe every loop iteration.
      def poll
        @transport.poll.each { |msg, host, port| handle(msg, host, port) }
      end

      # Drop clients that have gone silent, so their stale bodies stop being
      # simulated and stop holding a player slot. Called from the host loop.
      # A leave is a tic event like a join, applied on the next tic.
      def reap(now = @clock.call)
        @clients.values.each do |c|
          next unless c.joined
          next if now - c.last_seen < @client_timeout

          @clients.delete(c.key)
          @by_id.delete(c.player_id)
          @pending_leaves << c.player_id
        end
      end

      # Run every tic whose deadline has passed, capping the catch-up so one
      # long stall cannot make a single call run thousands of tics. Returns how
      # many ran.
      def advance(now = @clock.call, limit: 8)
        target = @start_tic + ((now - @start_time) * TICRATE).floor
        ran = 0
        while @tic < target && ran < limit
          step_one_tic
          ran += 1
        end
        ran
      end

      def player_count = @world.players.size

      private

      # Advance exactly one tic: apply membership, gather input, simulate,
      # then tell everyone what happened.
      def step_one_tic
        this_tic = @tic + 1

        joins = @pending_joins.dup
        leaves = @pending_leaves.dup
        @pending_joins.clear
        @pending_leaves.clear

        apply_joins(joins)
        apply_leaves(leaves)

        cmds = finalize_cmds(this_tic)
        @world.run_tic(cmds)
        @tic = this_tic
        @inputs.delete(this_tic)

        frame = { tic: this_tic, joins: joins, leaves: leaves,
                  cmds: cmds.map { |id, c| [id, c] } }
        record_and_broadcast(frame)
        send_welcomes(joins, this_tic)
      end

      # Missing players coast on a neutral command rather than stalling the tic.
      # That is the whole point of the deadline: nobody waits.
      def finalize_cmds(tic)
        have = @inputs[tic]
        @world.players.each_with_object({}) do |p, h|
          h[p.id] = have[p.id] || Game::Ticcmd.none
        end
      end

      def apply_joins(ids)
        ids.each do |id|
          @world.add_player(id: id)
          client = @by_id[id]
          client.joined = true if client
        end
      end

      def apply_leaves(ids)
        ids.each { |id| @world.remove_player(id) }
      end

      def record_and_broadcast(frame)
        @frame_log << frame
        @frame_log.shift while @frame_log.size > FRAME_REDUNDANCY
        packet = Protocol.encode_frame(@frame_log)
        @clients.each_value { |c| @transport.send_to_addr(c.host, c.port, packet) }
      end

      def handle(msg, host, port)
        case msg[:type]
        when Protocol::HELLO then on_hello(host, port)
        when Protocol::INPUT then on_input(msg, host, port)
        when Protocol::QUIT  then on_quit(host, port)
        end
      end

      def on_hello(host, port)
        existing = @clients["#{host}:#{port}"]
        if existing
          # A repeated hello: their welcome was probably lost. Re-send it once
          # they are actually in the world.
          send_welcome(existing) if existing.joined
          return
        end
        return if @world.players.size + @pending_joins.size >= @max_players

        id = next_free_id
        return unless id

        client = Client.new(id, host, port, @clock.call, false)
        @clients[client.key] = client
        @by_id[id] = client
        @pending_joins << id
      end

      def on_input(msg, host, port)
        client = @clients["#{host}:#{port}"]
        return unless client

        client.last_seen = @clock.call
        # A client may only speak for the id it was assigned. The check does not
        # vary per command, so reject the whole packet up front rather than
        # re-testing it inside the loop.
        return unless msg[:player_id] == client.player_id

        msg[:cmds].each do |tic, cmd|
          next if tic <= @tic # already simulated; too late to matter

          @inputs[tic][client.player_id] = cmd
        end
      end

      def on_quit(host, port)
        client = @clients.delete("#{host}:#{port}")
        return unless client

        @by_id.delete(client.player_id)
        @pending_leaves << client.player_id if client.joined
      end

      def next_free_id
        taken = @by_id.keys + @pending_joins
        (0...@max_players).find { |id| !taken.include?(id) }
      end

      # Hand each new joiner a snapshot of the world at the tic they joined,
      # split into datagram-sized chunks. They restore it and follow the frame
      # stream from the next tic.
      def send_welcomes(join_ids, tic)
        return if join_ids.empty?

        bytes = Game::Snapshot.dump(@world)
        chunks = Protocol.snapshot_chunks(tic, bytes)
        join_ids.each do |id|
          client = @by_id[id]
          next unless client

          send_welcome(client)
          chunks.each { |c| @transport.send_to_addr(client.host, client.port, c) }
        end
      end

      def send_welcome(client)
        @transport.send_to_addr(client.host, client.port, Protocol.encode_welcome(
          player_id: client.player_id, num_players: @world.players.size,
          mode: @world.mode, skill: Session::DEFAULT_SKILL,
          snapshot_tic: @tic, map: @world.map.name
        ))
      end
    end
  end
end
