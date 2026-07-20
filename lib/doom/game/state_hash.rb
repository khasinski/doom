# frozen_string_literal: true

require 'zlib'

module Doom
  module Game
    # A fingerprint of the simulation, for catching lockstep desync.
    #
    # Peers exchange this every so often. If two peers disagree at the same
    # tic their worlds have diverged, and we want to say so loudly at the tic
    # it happened rather than let the games drift silently apart.
    #
    # Deliberately NOT built on Object#hash: Ruby randomises string and array
    # hashing per process, so two peers would disagree on identical state and
    # every session would look like a desync. Zlib.crc32 over an explicitly
    # packed byte string is stable across processes and machines.
    #
    # Floats are packed as raw IEEE754 ('E', little-endian), not rounded. In
    # lockstep a one-ULP difference is a real divergence -- it compounds -- so
    # the check must see it.
    module StateHash
      # Sections are hashed separately as well as folded together. When a
      # desync fires, the section that differs says where to look.
      SECTIONS = %i[rng players monsters combat sectors].freeze

      module_function

      def of(world)
        fold(sections(world))
      end

      def sections(world)
        {
          rng: crc([world.leveltime, world.random.index].pack('q<q<')),
          players: crc(pack_players(world.players)),
          monsters: crc(pack_monsters(world.monster_ai)),
          combat: crc(pack_combat(world.combat)),
          sectors: crc(world.map.sectors.map(&:light_level).pack('q<*')),
        }
      end

      def fold(sections)
        crc(SECTIONS.map { |name| sections[name] }.pack('L<*'))
      end

      def crc(bytes)
        Zlib.crc32(bytes)
      end

      def pack_players(players)
        players.flat_map do |p|
          s = p.state
          [
            p.id, s.health, s.armor, s.weapon, (s.dead ? 1 : 0),
            s.ammo_bullets, s.ammo_shells, s.ammo_rockets, s.ammo_cells,
            s.keys.count { |_, v| v },
            # Frags are simulation state: peers that disagree on the score
            # disagree on who won, and that must show up as a desync.
            p.frags,
          ].pack('q<*') +
            [p.x, p.y, p.z, p.angle, p.momx, p.momy].pack('E*')
        end.join
      end

      def pack_monsters(monster_ai)
        return '' unless monster_ai

        monster_ai.monsters.flat_map do |m|
          [
            m.thing_idx, m.movedir, m.movecount, (m.active ? 1 : 0),
            (m.attacking ? 1 : 0), m.target&.id || -1,
          ].pack('q<*') + [m.x, m.y].pack('E*')
        end.join
      end

      def pack_combat(combat)
        return '' unless combat

        hp = combat.instance_variable_get(:@monster_hp) || {}
        parts = [
          hp.sort.flatten.pack('q<*'),
          combat.dead_things.keys.sort.pack('q<*'),
        ]
        parts << combat.projectiles.flat_map { |pr| [pr.x, pr.y, pr.z, pr.dx, pr.dy] }.pack('E*')
        parts.join
      end
    end
  end
end
