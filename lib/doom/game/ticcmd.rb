# frozen_string_literal: true

module Doom
  module Game
    # One tic's worth of player intent, as in DOOM's ticcmd_t.
    #
    # This is the only thing that travels between peers in lockstep
    # multiplayer: never positions, never health. Each peer feeds identical
    # ticcmds to an identical simulation and arrives at an identical world, so
    # the wire format stays tiny and cheating by position injection is
    # impossible by construction.
    #
    #   forwardmove  -1.0..1.0  (negative = backward)
    #   sidemove     -1.0..1.0  (positive = strafe right)
    #   angleturn    degrees to turn this tic (positive = left, as DOOM)
    #   buttons      bitmask, see constants below
    # Subclassed rather than built with a Struct.new block: constants assigned
    # inside a block land in the enclosing lexical scope (Doom::Game), not on
    # the struct class, so Ticcmd::BTN_FIRE would not resolve.
    class Ticcmd < Struct.new(:forwardmove, :sidemove, :angleturn, :buttons)
      BTN_FIRE = 1
      BTN_USE  = 2
      PACKED_SIZE = 7

      def self.none
        new(0.0, 0.0, 0.0, 0)
      end

      def fire?
        (buttons & BTN_FIRE) != 0
      end

      def use?
        (buttons & BTN_USE) != 0
      end

      def moving?
        forwardmove != 0.0 || sidemove != 0.0
      end

      # Fixed 8 bytes on the wire: three signed shorts plus a byte of buttons
      # (padded). Movement is quantised to 1/1000 and the turn to 1/100 of a
      # degree -- both far finer than any input device resolves, and identical
      # on every peer, which matters more than the precision itself.
      def pack
        [
          (forwardmove * 1000).round.clamp(-32_768, 32_767),
          (sidemove * 1000).round.clamp(-32_768, 32_767),
          (angleturn * 100).round.clamp(-32_768, 32_767),
          buttons & 0xff,
        ].pack('s>s>s>C')
      end

      def self.unpack(bytes)
        f, s, a, b = bytes.unpack('s>s>s>C')
        new(f / 1000.0, s / 1000.0, a / 100.0, b)
      end
    end
  end
end
