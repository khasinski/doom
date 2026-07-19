# frozen_string_literal: true

module Doom
  module Game
    # DOOM's P_Random -- a fixed 256-entry table walked by an index, not a PRNG.
    #
    # The point is determinism: two peers running the same tics with the same
    # starting index observe identical results, which is what lockstep
    # networking requires. Kernel#rand cannot give us that.
    #
    # Matches m_random.c. Only the game-state RNG lives here; presentation-only
    # randomness (screen melt) stays on Kernel#rand since it never feeds the
    # simulation.
    class Random
      RNDTABLE = [
        0,   8, 109, 220, 222, 241, 149, 107,  75, 248, 254, 140,  16,  66,
        74,  21, 211,  47,  80, 242, 154,  27, 205, 128, 161,  89,  77,  36,
        95, 110,  85,  48, 212, 140, 211, 249,  22,  79, 200,  50,  28, 188,
        52, 140, 202, 120,  68, 145,  62,  70, 184, 190,  91, 197, 152, 224,
        149, 104,  25, 178, 252, 182, 202, 182, 141, 197,   4,  81, 181, 242,
        145,  42,  39, 227, 156, 198, 225, 193, 219,  93, 122, 175, 249,   0,
        175, 143,  70, 239,  46, 246, 163,  53, 163, 109, 168, 135,   2, 235,
        25,  92,  20, 145, 138,  77,  69, 166,  78, 176, 173, 212, 166, 113,
        94, 161,  41,  50, 239,  49, 111, 164,  70,  60,   2,  37, 171,  75,
        136, 156,  11,  56,  42, 146, 138, 229,  73, 146,  77,  61,  98, 196,
        135, 106,  63, 197, 195,  86,  96, 203, 113, 101, 170, 247, 181, 113,
        80, 250, 108,   7, 255, 237, 129, 226,  79, 107, 112, 166, 103, 241,
        24, 223, 239, 120, 198,  58,  60,  82, 128,   3, 184,  66, 143, 224,
        145, 224,  81, 206, 163,  45,  63,  90, 168, 114,  59,  33, 159,  95,
        28, 139, 123,  98, 125, 196,  15,  70, 194, 253,  54,  14, 109, 226,
        71,  17, 161,  93, 186,  87, 244, 138,  20,  52, 123, 251,  26,  36,
        17,  46,  52, 231, 232,  76,  31, 221,  84,  37, 216, 165, 212, 106,
        197, 242,  98,  43,  39, 175, 254, 145, 190,  84, 118, 222, 187, 136,
        120, 163, 236, 249
      ].freeze

      # Index into RNDTABLE. Part of the game state -- include it in desync
      # hashes, and save/restore it alongside player positions.
      attr_accessor :index

      def initialize(seed = 0)
        reset(seed)
      end

      def reset(seed = 0)
        @index = seed & 0xff
      end

      # P_Random(): next table entry, 0-255.
      def byte
        @index = (@index + 1) & 0xff
        RNDTABLE[@index]
      end

      # Signed difference of two draws, -255..255. DOOM uses this shape a lot
      # (P_Random() - P_Random()) for spread and jitter.
      def diff
        byte - byte
      end

      # Kernel#rand-compatible surface so call sites read the same as before.
      #
      #   rand       -> Float in [0, 1)
      #   rand(n)    -> Integer in 0...n     (DOOM's P_Random()%n)
      #   rand(a..b) -> Integer in a..b
      def rand(arg = nil)
        case arg
        when nil
          byte / 256.0
        when ::Range
          lo = arg.begin
          hi = arg.exclude_end? ? arg.end - 1 : arg.end
          span = hi - lo + 1
          span <= 0 ? lo : lo + (byte % span)
        else
          n = arg.to_i
          n <= 0 ? 0 : byte % n
        end
      end
    end
  end
end
