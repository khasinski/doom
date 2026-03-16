# frozen_string_literal: true

module Doom
  module Game
    # Hitscan weapon firing and monster state tracking.
    # Matches Chocolate Doom's P_LineAttack / P_AimLineAttack from p_map.c.
    class Combat
      # Monster starting HP (from mobjinfo[] in info.c)
      MONSTER_HP = {
        3004 => 20,   # Zombieman
        9    => 30,   # Shotgun Guy
        3001 => 60,   # Imp
        3002 => 150,  # Demon
        58   => 150,  # Spectre
        3003 => 1000, # Baron of Hell
        69   => 500,  # Hell Knight
        3005 => 400,  # Cacodemon
        3006 => 100,  # Lost Soul
        16   => 4000, # Cyberdemon
        7    => 3000, # Spider Mastermind
        65   => 70,   # Heavy Weapon Dude
        64   => 700,  # Archvile
        71   => 400,  # Pain Elemental
        84   => 20,   # Wolfenstein SS
      }.freeze

      MONSTER_RADIUS = {
        3004 => 20, 9 => 20, 3001 => 20, 3002 => 30, 58 => 30,
        3003 => 24, 69 => 24, 3005 => 31, 3006 => 16, 16 => 40,
        7 => 128, 65 => 20, 64 => 20, 71 => 31, 84 => 20,
      }.freeze

      # Normal death frame sequences per sprite prefix (rotation 0 only)
      # Identified by sprite heights: frames go from standing height to flat on ground
      DEATH_FRAMES = {
        'POSS' => %w[H I J K L],       # Zombieman: 55→46→34→27→17
        'SPOS' => %w[H I J K L],       # Shotgun Guy: 60→50→35→27→17
        'TROO' => %w[I J K L M],       # Imp: 62→59→54→46→22
        'SARG' => %w[I J K L M N],     # Demon/Spectre: 56→56→53→57→46→32
        'BOSS' => %w[H I J K L M N],   # Baron
        'BOS2' => %w[H I J K L M N],   # Hell Knight
        'HEAD' => %w[G H I J K L],     # Cacodemon
        'SKUL' => %w[G H I J K],       # Lost Soul
        'CYBR' => %w[I J],             # Cyberdemon
        'SPID' => %w[I J K],           # Spider Mastermind
        'CPOS' => %w[H I J K L M N],   # Heavy Weapon Dude
        'PAIN' => %w[H I J K L M],     # Pain Elemental
        'SSWV' => %w[I J K L M],       # Wolfenstein SS
      }.freeze

      DEATH_ANIM_TICS = 6  # Tics per death frame

      # Weapon damage: DOOM does (P_Random()%3 + 1) * multiplier
      # Pistol/chaingun: 1*5..3*5 = 5-15 per bullet
      # Shotgun: 7 pellets, each 1*5..3*5 = 5-15
      # Fist/chainsaw: 1*2..3*2 = 2-10

      def initialize(map, player_state, sprites)
        @map = map
        @player = player_state
        @sprites = sprites
        @monster_hp = {}     # thing_idx => current HP
        @dead_things = {}    # thing_idx => { tic: death_start_tic, prefix: sprite_prefix }
        @tic = 0
      end

      attr_reader :dead_things

      def dead?(thing_idx)
        @dead_things.key?(thing_idx)
      end

      # Get the current death frame sprite for a dead monster
      def death_sprite(thing_idx, thing_type, viewer_angle, thing_angle)
        info = @dead_things[thing_idx]
        return nil unless info

        frames = DEATH_FRAMES[info[:prefix]]
        return nil unless frames

        elapsed = @tic - info[:tic]
        frame_idx = (elapsed / DEATH_ANIM_TICS).clamp(0, frames.size - 1)
        frame_letter = frames[frame_idx]

        @sprites.get_frame(thing_type, frame_letter, viewer_angle, thing_angle)
      end

      # Called each game tic
      def update
        @tic += 1
      end

      # Fire the current weapon
      def fire(px, py, pz, cos_a, sin_a, weapon)
        case weapon
        when PlayerState::WEAPON_PISTOL, PlayerState::WEAPON_CHAINGUN
          hitscan(px, py, cos_a, sin_a, 1, 0.0, 5)
        when PlayerState::WEAPON_SHOTGUN
          hitscan(px, py, cos_a, sin_a, 7, Math::PI / 32, 5)
        when PlayerState::WEAPON_FIST
          melee(px, py, cos_a, sin_a, 2, 64)
        when PlayerState::WEAPON_CHAINSAW
          melee(px, py, cos_a, sin_a, 2, 64)
        end
      end

      private

      def hitscan(px, py, cos_a, sin_a, pellets, spread, multiplier)
        pellets.times do
          # Add random spread
          if spread > 0
            angle = Math.atan2(sin_a, cos_a) + (rand - 0.5) * spread * 2
            ca = Math.cos(angle)
            sa = Math.sin(angle)
          else
            # Slight pistol/chaingun spread
            angle = Math.atan2(sin_a, cos_a) + (rand - 0.5) * 0.04
            ca = Math.cos(angle)
            sa = Math.sin(angle)
          end

          wall_dist = trace_wall(px, py, ca, sa)

          best_idx = nil
          best_dist = wall_dist

          @map.things.each_with_index do |thing, idx|
            next unless MONSTER_HP[thing.type]
            next if @dead_things[idx]

            radius = MONSTER_RADIUS[thing.type] || 20
            hit_dist = ray_circle_hit(px, py, ca, sa, thing.x, thing.y, radius)
            if hit_dist && hit_dist > 0 && hit_dist < best_dist
              best_dist = hit_dist
              best_idx = idx
            end
          end

          if best_idx
            damage = (rand(3) + 1) * multiplier
            apply_damage(best_idx, damage)
          end
        end
      end

      def melee(px, py, cos_a, sin_a, multiplier, range)
        best_idx = nil
        best_dist = range.to_f

        @map.things.each_with_index do |thing, idx|
          next unless MONSTER_HP[thing.type]
          next if @dead_things[idx]

          dx = thing.x - px
          dy = thing.y - py
          dist = Math.sqrt(dx * dx + dy * dy)
          next if dist > range + (MONSTER_RADIUS[thing.type] || 20)

          # Check if roughly facing the monster
          dot = dx * cos_a + dy * sin_a
          next if dot < 0

          if dist < best_dist
            best_dist = dist
            best_idx = idx
          end
        end

        if best_idx
          damage = (rand(3) + 1) * multiplier
          apply_damage(best_idx, damage)
        end
      end

      def apply_damage(thing_idx, damage)
        thing = @map.things[thing_idx]
        @monster_hp[thing_idx] ||= MONSTER_HP[thing.type] || 20

        @monster_hp[thing_idx] -= damage

        if @monster_hp[thing_idx] <= 0
          prefix = @sprites.prefix_for(thing.type)
          @dead_things[thing_idx] = { tic: @tic, prefix: prefix } if prefix
        end
      end

      def trace_wall(px, py, cos_a, sin_a)
        best_t = 4096.0  # Max hitscan range

        @map.linedefs.each do |ld|
          v1 = @map.vertices[ld.v1]
          v2 = @map.vertices[ld.v2]

          # One-sided always blocks; two-sided only if impassable
          blocks = (ld.sidedef_left == 0xFFFF) || (ld.flags & 0x0001 != 0)
          unless blocks
            next unless ld.sidedef_left < 0xFFFF
            front = @map.sidedefs[ld.sidedef_right]
            back = @map.sidedefs[ld.sidedef_left]
            fs = @map.sectors[front.sector]
            bs = @map.sectors[back.sector]
            # Blocks if opening is too small (step or low ceiling)
            max_floor = [fs.floor_height, bs.floor_height].max
            min_ceil = [fs.ceiling_height, bs.ceiling_height].min
            blocks = (min_ceil - max_floor) < 56
          end
          next unless blocks

          t = ray_segment_intersect(px, py, cos_a, sin_a,
                                     v1.x, v1.y, v2.x, v2.y)
          best_t = t if t && t > 0 && t < best_t
        end

        best_t
      end

      def ray_segment_intersect(px, py, dx, dy, x1, y1, x2, y2)
        sx = x2 - x1
        sy = y2 - y1
        denom = dx * sy - dy * sx
        return nil if denom.abs < 0.001

        t = ((x1 - px) * sy - (y1 - py) * sx) / denom
        u = ((x1 - px) * dy - (y1 - py) * dx) / denom

        (t > 0 && u >= 0.0 && u <= 1.0) ? t : nil
      end

      def ray_circle_hit(px, py, cos_a, sin_a, cx, cy, radius)
        dx = cx - px
        dy = cy - py
        proj = dx * cos_a + dy * sin_a
        return nil if proj < 0

        perp_sq = dx * dx + dy * dy - proj * proj
        return nil if perp_sq > radius * radius

        chord_half = Math.sqrt([radius * radius - perp_sq, 0].max)
        proj - chord_half
      end
    end
  end
end
