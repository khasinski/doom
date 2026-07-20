# frozen_string_literal: true

module Doom
  module Net
    # A multiplayer session: handshake, then lockstep play.
    #
    # The host coordinates only the handshake -- it hands out player ids, the
    # RNG seed and the map, then tells everyone about everyone. After that
    # there is no authority: every peer runs the same simulation from the same
    # commands, and traffic goes peer to peer rather than through the host,
    # which would add a hop of latency to every command.
    #
    # Everything here is driven by polling, never by blocking, so the game loop
    # keeps rendering while a session is still forming.
    class Session
      HELLO_RESEND_SECONDS = 0.25
      DEFAULT_PORT = 5029
      REDUNDANCY = 8  # Commands per packet; loss is covered by resending

      # How long a stall must last before it is worth telling the player about.
      # Well under a second so a real problem shows up promptly, but far longer
      # than the sub-tic waits that healthy play produces constantly.
      STALL_WARNING_SECONDS = 0.35

      attr_reader :transport, :lockstep, :monitor, :local_id, :player_ids
      attr_reader :seed, :map_name, :mode, :skill, :num_players

      # Skill is a plain number here rather than Game::Menu::SKILL_MEDIUM: the
      # network layer has no business depending on the menu.
      DEFAULT_SKILL = 2

      def self.host(port: DEFAULT_PORT, players: 2, map: 'E1M1', mode: :coop,
                    skill: DEFAULT_SKILL, seed: nil, delay: Lockstep::DEFAULT_DELAY)
        new(role: :host, port: port, num_players: players, map_name: map, mode: mode,
            skill: skill, seed: seed, delay: delay)
      end

      def self.connect(host:, port: DEFAULT_PORT, delay: Lockstep::DEFAULT_DELAY)
        new(role: :client, remote_host: host, remote_port: port, delay: delay)
      end

      def initialize(role:, port: 0, num_players: 2, map_name: 'E1M1', mode: :coop,
                     skill: 2, seed: nil, delay: Lockstep::DEFAULT_DELAY,
                     remote_host: nil, remote_port: nil, clock: -> { Time.now })
        @role = role
        @delay = delay
        @clock = clock
        @transport = Transport.new(port: role == :host ? port : 0)
        @started = false
        @peer_acks = Hash.new(0)
        @joined = {}   # player_id => [host, port]
        @last_hello = nil

        if host?
          @local_id = 0
          @num_players = num_players
          @map_name = map_name
          @mode = mode
          @skill = skill
          # The seed is part of the simulation, so it is chosen once and told
          # to everyone rather than derived locally by each peer.
          @seed = seed || ::Random.new_seed % 256
          start if solo?
        else
          @remote = @transport.add_peer(remote_host, remote_port, player_id: 0)
        end
      end

      def host? = @role == :host
      def started? = @started
      def local_port = @transport.local_port
      def solo? = host? && @num_players <= 1

      def player_ids
        @player_ids ||= (0...(@num_players || 1)).to_a
      end

      # Pump the network. Safe to call every frame, before and after the
      # session starts.
      def poll
        send_hello_if_waiting
        @transport.poll.each { |msg, host, port| handle(msg, host, port) }
      end

      # Schedule this frame's input and tell the peers about it.
      def submit(cmd)
        return unless @started

        @lockstep.submit_local(cmd)
        transmit
      end

      # Resend without sampling. A peer stalled on a command we already ran can
      # only be freed by us sending it again, so this must keep happening even
      # when there is no new input to report.
      def transmit
        return unless @started

        @transport.peers.each_value do |peer|
          pairs = @lockstep.local_since(@peer_acks[peer.player_id], REDUNDANCY)
          @transport.send_to(peer, Protocol.encode_ticcmds(@local_id, pairs,
                                                           ack: @lockstep.ack_tic))
        end
      end

      # Advance the world by whatever tics are ready, then fingerprint on
      # checkpoints and tell the peers.
      def run(world, limit: 10)
        return 0 unless @started

        ran = @lockstep.run_ready(world, limit: limit)
        report_hash(world) if ran.positive?

        # Track how long we have been unable to advance. Every healthy peer is
        # "waiting" almost all the time: once the ready tics have run, the next
        # one by definition lacks a command, or it would have run too. Only the
        # duration distinguishes normal play from a peer in trouble.
        if @lockstep.ready?
          @stalled_since = nil
        else
          @stalled_since ||= @clock.call
        end

        ran
      end

      def waiting_on
        @started ? @lockstep.waiting_on - [@local_id] : []
      end

      def stalled?
        @started && !@lockstep.ready?
      end

      # Seconds spent unable to advance, 0 when running normally.
      def stalled_seconds
        return 0.0 unless @stalled_since

        @clock.call - @stalled_since
      end

      def desyncs
        @monitor&.desyncs || []
      end

      # Leaving before the handshake finishes is ordinary -- someone pressing
      # Escape while still connecting -- and there is no id to say goodbye
      # with yet, so just go.
      def quit
        @transport.broadcast(Protocol.encode_quit(@local_id)) if @local_id && !@transport.closed?
        @transport.close
      end

      private

      def handle(msg, host, port)
        case msg[:type]
        when Protocol::HELLO  then on_hello(host, port)
        when Protocol::SETUP  then on_setup(msg)
        when Protocol::PEERS  then on_peers(msg)
        when Protocol::TICCMD then on_ticcmds(msg)
        when Protocol::HASH   then on_hash(msg)
        when Protocol::QUIT   then on_quit(msg)
        end
      end

      # Host side: hand the newcomer an id and, once everyone is in, tell them
      # all what game they are playing and who else is here.
      def on_hello(host, port)
        return unless host?

        existing = @transport.peer_for(host, port)
        if existing
          # A resent hello: their SETUP was probably lost, so send it again.
          send_setup(existing) if @started
          return
        end

        return if @joined.size + 1 >= @num_players && !@started

        id = next_free_id
        return unless id

        peer = @transport.add_peer(host, port, player_id: id)
        @joined[id] = [host, port]
        start if @joined.size + 1 == @num_players
        send_setup(peer) if @started
      end

      def next_free_id
        (1...@num_players).find { |id| !@joined.key?(id) }
      end

      def on_setup(msg)
        return if host? || @started

        @local_id = msg[:player_id]
        @num_players = msg[:num_players]
        @seed = msg[:seed]
        @map_name = msg[:map]
        @mode = msg[:mode]
        @skill = msg[:skill]
        start
      end

      def on_peers(msg)
        msg[:peers].each do |player_id, host, port|
          next if player_id == @local_id

          @transport.add_peer(host, port, player_id: player_id)
        end
      end

      def on_ticcmds(msg)
        return unless @started

        @peer_acks[msg[:player_id]] = msg[:ack].to_i
        msg[:cmds].each { |tic, cmd| @lockstep.receive(tic, msg[:player_id], cmd) }
      end

      def on_hash(msg)
        @monitor&.remote_report(msg[:tic], msg[:player_id], msg[:sections])
      end

      def on_quit(msg)
        @transport.peers.delete_if { |_, peer| peer.player_id == msg[:player_id] }
      end

      def start
        @started = true
        @lockstep = Lockstep.new(local_id: @local_id, player_ids: player_ids, delay: @delay)
        @monitor = DesyncMonitor.new
        return unless host?

        @transport.peers.each_value do |peer|
          send_setup(peer)
          send_peers(peer)
        end
      end

      def send_setup(peer)
        @transport.send_to(peer, Protocol.encode_setup(
          player_id: peer.player_id, num_players: @num_players, seed: @seed,
          map: @map_name, mode: @mode, skill: @skill
        ))
      end

      # Everyone except the recipient, so the mesh can form without the host
      # relaying play traffic.
      def send_peers(peer)
        entries = [[0, host_address_for(peer), @transport.local_port]]
        @joined.each do |id, (host, port)|
          next if id == peer.player_id

          entries << [id, host, port]
        end
        @transport.send_to(peer, Protocol.encode_peers(entries))
      end

      # Tell each client to reach us on the address they already reached us on.
      def host_address_for(peer)
        peer.host
      end

      def send_hello_if_waiting
        return if host? || @started

        now = @clock.call
        return if @last_hello && (now - @last_hello) < HELLO_RESEND_SECONDS

        @last_hello = now
        @transport.send_to(@remote, Protocol.encode_hello)
      end

      def report_hash(world)
        sections = @monitor.record(world.leveltime, world)
        return unless sections

        @transport.broadcast(Protocol.encode_hash(world.leveltime, @local_id, sections))
      end
    end
  end
end
