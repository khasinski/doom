# frozen_string_literal: true

module Doom
  module Net
    # Wire format for both multiplayer stacks: the peer-to-peer lockstep mesh
    # (HELLO/SETUP/TICCMD/HASH/QUIT/PEERS) and the authoritative star server
    # (WELCOME/SNAPSHOT/INPUT/FRAME).
    #
    # Kept separate from the socket so it can be tested without one, and so
    # nothing that parses bytes off the network has any business touching a
    # file descriptor.
    #
    # Every decode path is defensive: these bytes come from the network, and a
    # truncated or malformed packet must produce nil, never an exception.
    # Anything unrecognised is simply dropped.
    module Protocol
      VERSION = 1

      HELLO  = 1  # I would like to join
      SETUP  = 2  # Here is the game you are joining, and who you are
      TICCMD = 3  # Input for one or more tics
      HASH   = 4  # State fingerprint for a checkpoint tic
      QUIT   = 5  # I am leaving
      PEERS  = 6  # Everyone else's address, so the mesh can form

      # Star-topology server packets (Net::GameServer). Separate from the peer
      # lockstep ones above: the server is authoritative and never waits, so
      # its packets carry finalized tics, not proposals.
      WELCOME  = 7  # server -> joiner: your id and the game, snapshot to follow
      SNAPSHOT = 8  # server -> joiner: one chunk of the world snapshot
      INPUT    = 9  # client -> server: my ticcmd for a future tic
      FRAME    = 10 # server -> clients: the finalized tics everyone must run

      MAX_CMDS_PER_PACKET = 32
      # Payload per snapshot chunk, kept well under a typical path MTU so a
      # chunk is never itself IP-fragmented.
      SNAPSHOT_CHUNK_BYTES = 1024

      module_function

      # HELLO carries nothing but "let me in": the server (or host) assigns the
      # id and tells the joiner everything else.
      def encode_hello
        [VERSION, HELLO].pack('CC')
      end

      def encode_setup(player_id:, num_players:, seed:, map:, mode:, skill:)
        [VERSION, SETUP, player_id, num_players, seed, mode_code(mode), skill].pack('CCCCCCC') +
          encode_string(map)
      end

      # `pairs` is [[tic, Ticcmd], ...]. Packets carry several commands so a
      # lost one is covered by the next packet: a ticcmd is 7 bytes, far
      # cheaper to repeat than to request again over a round trip.
      #
      # `ack` is the lowest tic the sender is still waiting for. Peers resend
      # from there, so a command cannot be lost for good by falling out of a
      # fixed-size window -- with real packet loss that eventually deadlocks
      # both sides, since lockstep never skips a tic.
      def encode_ticcmds(player_id, pairs, ack: 0)
        pairs = pairs.last(MAX_CMDS_PER_PACKET)
        body = pairs.map { |tic, cmd| [tic].pack('L<') + cmd.pack }.join
        [VERSION, TICCMD, player_id, pairs.size].pack('CCCC') + [ack].pack('L<') + body
      end

      def encode_hash(tic, player_id, sections)
        values = Game::StateHash::SECTIONS.map { |name| sections[name].to_i }
        [VERSION, HASH, player_id].pack('CCC') + [tic].pack('L<') + values.pack('L<*')
      end

      def encode_quit(player_id)
        [VERSION, QUIT, player_id].pack('CCC')
      end

      # `entries` is [[player_id, host, port], ...]. The host sends this so
      # clients can talk to each other directly instead of relaying everything
      # through it, which would add a hop of latency to every command.
      def encode_peers(entries)
        body = entries.map do |player_id, host, port|
          [player_id].pack('C') + encode_string(host) + [port].pack('S<')
        end.join
        [VERSION, PEERS, entries.size].pack('CCC') + body
      end

      # server -> joiner. Says who they are and what game this is; the world
      # itself follows as SNAPSHOT chunks for the same snapshot_tic. No RNG seed
      # is sent: the snapshot already carries the exact RNG state to resume from.
      def encode_welcome(player_id:, num_players:, mode:, skill:, snapshot_tic:, map:)
        [VERSION, WELCOME, player_id, num_players, mode_code(mode), skill].pack('CCCCCC') +
          [snapshot_tic].pack('L<') + encode_string(map)
      end

      def encode_snapshot_chunk(snapshot_tic, index, total, chunk_bytes)
        [VERSION, SNAPSHOT].pack('CC') + [snapshot_tic, index, total].pack('L<S<S<') + chunk_bytes.b
      end

      # Split a full snapshot into datagram-sized chunks for one tic.
      def snapshot_chunks(snapshot_tic, bytes)
        bytes = bytes.b
        total = [(bytes.bytesize + SNAPSHOT_CHUNK_BYTES - 1) / SNAPSHOT_CHUNK_BYTES, 1].max
        (0...total).map do |i|
          encode_snapshot_chunk(snapshot_tic, i, total, bytes.byteslice(i * SNAPSHOT_CHUNK_BYTES, SNAPSHOT_CHUNK_BYTES) || ''.b)
        end
      end

      # client -> server. `pairs` is [[tic, Ticcmd], ...]; recent inputs are
      # repeated so a lost packet is covered by the next, as with TICCMD.
      def encode_input(player_id, pairs)
        pairs = pairs.last(MAX_CMDS_PER_PACKET)
        body = pairs.map { |tic, cmd| [tic].pack('L<') + cmd.pack }.join
        [VERSION, INPUT, player_id, pairs.size].pack('CCCC') + body
      end

      # server -> clients. A batch of finalized tics, oldest first. Each tic
      # carries the membership changes to apply (joins and leaves are tic
      # events, because a deathmatch spawn draws the shared RNG and must happen
      # on the same tic everywhere) and then every player's command.
      def encode_frame(frames)
        frames = frames.last(MAX_CMDS_PER_PACKET)
        body = frames.map do |f|
          [f[:tic]].pack('L<') +
            [f[:joins].size].pack('C') + f[:joins].pack('C*') +
            [f[:leaves].size].pack('C') + f[:leaves].pack('C*') +
            [f[:cmds].size].pack('C') +
            f[:cmds].map { |id, cmd| [id].pack('C') + cmd.pack }.join
        end.join
        [VERSION, FRAME, frames.size].pack('CCC') + body
      end

      def decode(bytes)
        return nil if bytes.nil? || bytes.bytesize < 2

        bytes = bytes.b
        version, type = bytes.unpack('CC')
        return nil unless version == VERSION

        case type
        when HELLO    then decode_hello(bytes)
        when SETUP    then decode_setup(bytes)
        when TICCMD   then decode_ticcmds(bytes)
        when HASH     then decode_hash(bytes)
        when QUIT     then decode_quit(bytes)
        when PEERS    then decode_peers(bytes)
        when WELCOME  then decode_welcome(bytes)
        when SNAPSHOT then decode_snapshot_chunk(bytes)
        when INPUT    then decode_input(bytes)
        when FRAME    then decode_frame(bytes)
        end
      end

      def decode_welcome(bytes)
        return nil if bytes.bytesize < 10

        _, _, player_id, num_players, mode, skill = bytes.unpack('CCCCCC')
        snapshot_tic = bytes[6, 4].unpack1('L<')
        map, = decode_string(bytes, 10)
        return nil if map.nil? || map.empty?

        { type: WELCOME, player_id: player_id, num_players: num_players,
          mode: mode_name(mode), skill: skill, snapshot_tic: snapshot_tic, map: map }
      end

      def decode_snapshot_chunk(bytes)
        return nil if bytes.bytesize < 10

        snapshot_tic, index, total = bytes[2, 8].unpack('L<S<S<')
        { type: SNAPSHOT, snapshot_tic: snapshot_tic, index: index, total: total,
          chunk: bytes.byteslice(10, bytes.bytesize - 10) }
      end

      def decode_input(bytes)
        return nil if bytes.bytesize < 4

        _, _, player_id, count = bytes.unpack('CCCC')
        entry = 4 + Game::Ticcmd::PACKED_SIZE
        return nil if bytes.bytesize < 4 + (count * entry)

        cmds = Array.new(count) do |i|
          at = 4 + (i * entry)
          [bytes[at, 4].unpack1('L<'), Game::Ticcmd.unpack(bytes[at + 4, Game::Ticcmd::PACKED_SIZE])]
        end
        { type: INPUT, player_id: player_id, cmds: cmds }
      end

      def decode_frame(bytes)
        return nil if bytes.bytesize < 3

        count = bytes.unpack('CCC')[2]
        offset = 3
        frames = []
        entry = 1 + Game::Ticcmd::PACKED_SIZE

        count.times do
          return nil if bytes.bytesize < offset + 5

          tic = bytes[offset, 4].unpack1('L<')
          offset += 4
          njoins = bytes[offset].unpack1('C'); offset += 1
          return nil if bytes.bytesize < offset + njoins
          joins = bytes[offset, njoins].unpack('C*'); offset += njoins
          return nil if bytes.bytesize < offset + 1
          nleaves = bytes[offset].unpack1('C'); offset += 1
          return nil if bytes.bytesize < offset + nleaves
          leaves = bytes[offset, nleaves].unpack('C*'); offset += nleaves
          return nil if bytes.bytesize < offset + 1
          ncmds = bytes[offset].unpack1('C'); offset += 1
          return nil if bytes.bytesize < offset + (ncmds * entry)

          cmds = Array.new(ncmds) do |i|
            at = offset + (i * entry)
            [bytes[at].unpack1('C'), Game::Ticcmd.unpack(bytes[at + 1, Game::Ticcmd::PACKED_SIZE])]
          end
          offset += ncmds * entry
          frames << { tic: tic, joins: joins, leaves: leaves, cmds: cmds }
        end

        { type: FRAME, frames: frames }
      end

      def decode_peers(bytes)
        return nil if bytes.bytesize < 3

        count = bytes.unpack('CCC')[2]
        offset = 3
        entries = []

        count.times do
          return nil if bytes.bytesize < offset + 1

          player_id = bytes[offset].unpack1('C')
          host, offset = decode_string(bytes, offset + 1)
          return nil if host.nil?
          return nil if bytes.bytesize < offset + 2

          entries << [player_id, host, bytes[offset, 2].unpack1('S<')]
          offset += 2
        end

        { type: PEERS, peers: entries }
      end

      def decode_hello(_bytes)
        { type: HELLO }
      end

      def decode_setup(bytes)
        return nil if bytes.bytesize < 7

        _, _, player_id, num_players, seed, mode, skill = bytes.unpack('CCCCCCC')
        map, = decode_string(bytes, 7)
        return nil if map.nil? || map.empty?

        { type: SETUP, player_id: player_id, num_players: num_players, seed: seed,
          mode: mode_name(mode), skill: skill, map: map }
      end

      def decode_ticcmds(bytes)
        return nil if bytes.bytesize < 8

        _, _, player_id, count = bytes.unpack('CCCC')
        ack = bytes[4, 4].unpack1('L<')
        entry = 4 + Game::Ticcmd::PACKED_SIZE
        return nil if bytes.bytesize < 8 + (count * entry)

        cmds = Array.new(count) do |i|
          at = 8 + (i * entry)
          tic = bytes[at, 4].unpack1('L<')
          [tic, Game::Ticcmd.unpack(bytes[at + 4, Game::Ticcmd::PACKED_SIZE])]
        end

        { type: TICCMD, player_id: player_id, ack: ack, cmds: cmds }
      end

      def decode_hash(bytes)
        names = Game::StateHash::SECTIONS
        return nil if bytes.bytesize < 7 + (names.size * 4)

        _, _, player_id = bytes.unpack('CCC')
        tic = bytes[3, 4].unpack1('L<')
        values = bytes[7, names.size * 4].unpack('L<*')

        { type: HASH, player_id: player_id, tic: tic,
          sections: names.zip(values).to_h }
      end

      def decode_quit(bytes)
        return nil if bytes.bytesize < 3

        { type: QUIT, player_id: bytes.unpack('CCC')[2] }
      end

      # Length-prefixed so a name or map with odd bytes cannot run off the end.
      def encode_string(str)
        s = str.to_s.b[0, 255]
        [s.bytesize].pack('C') + s
      end

      def decode_string(bytes, offset)
        return [nil, offset] if bytes.bytesize < offset + 1

        len = bytes[offset].unpack1('C')
        return [nil, offset] if bytes.bytesize < offset + 1 + len

        [bytes[offset + 1, len], offset + 1 + len]
      end

      MODES = { 0 => :coop, 1 => :deathmatch }.freeze

      def mode_code(mode)
        MODES.key(mode.to_sym) || 0
      end

      def mode_name(code)
        MODES.fetch(code, :coop)
      end
    end
  end
end
