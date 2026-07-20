# frozen_string_literal: true

module Doom
  module Net
    # Wire format for lockstep play.
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

      MAX_CMDS_PER_PACKET = 32
      MAX_PACKET_SIZE = 512

      module_function

      def encode_hello(name = '')
        [VERSION, HELLO].pack('CC') + encode_string(name)
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

      def decode(bytes)
        return nil if bytes.nil? || bytes.bytesize < 2

        bytes = bytes.b
        version, type = bytes.unpack('CC')
        return nil unless version == VERSION

        case type
        when HELLO  then decode_hello(bytes)
        when SETUP  then decode_setup(bytes)
        when TICCMD then decode_ticcmds(bytes)
        when HASH   then decode_hash(bytes)
        when QUIT   then decode_quit(bytes)
        when PEERS  then decode_peers(bytes)
        end
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

      def decode_hello(bytes)
        { type: HELLO, name: decode_string(bytes, 2).first.to_s }
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
