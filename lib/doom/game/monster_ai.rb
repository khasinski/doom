# frozen_string_literal: true

module Doom
  module Game
    # Basic monster AI: idle until seeing player, then chase.
    # Matches Chocolate Doom's A_Look / A_Chase / P_NewChaseDir from p_enemy.c.
    class MonsterAI
      # 8 movement directions + no direction
      DI_EAST = 0; DI_NORTHEAST = 1; DI_NORTH = 2; DI_NORTHWEST = 3
      DI_WEST = 4; DI_SOUTHWEST = 5; DI_SOUTH = 6; DI_SOUTHEAST = 7
      DI_NODIR = 8

      # Movement deltas per direction (map units, 1.0 = FRACUNIT)
      XSPEED = [1.0, 0.7071, 0.0, -0.7071, -1.0, -0.7071, 0.0, 0.7071].freeze
      YSPEED = [0.0, 0.7071, 1.0, 0.7071, 0.0, -0.7071, -1.0, -0.7071].freeze

      OPPOSITE = [DI_WEST, DI_SOUTHWEST, DI_SOUTH, DI_SOUTHEAST,
                  DI_EAST, DI_NORTHEAST, DI_NORTH, DI_NORTHWEST, DI_NODIR].freeze

      # Monster speeds (from mobjinfo)
      MONSTER_SPEED = {
        3004 => 8, 9 => 8, 3001 => 8, 3002 => 10, 58 => 10,
        3003 => 8, 69 => 8, 3005 => 8, 3006 => 8, 16 => 16,
        7 => 12, 65 => 8, 64 => 15, 71 => 8, 84 => 8,
      }.freeze

      CHASE_TICS = 4       # Steps between A_Chase calls
      SIGHT_RANGE = 768.0  # Max distance for sight check
      MELEE_RANGE = 64.0
      MISSILE_RANGE = 768.0
      KEEP_DISTANCE = 196.0  # Ranged monsters prefer to stay this far from player

      # Direction to angle (for sprite facing)
      DIR_ANGLES = [0, 45, 90, 135, 180, 225, 270, 315].freeze

      # Monster attack definitions (from mobjinfo / A_Chase)
      # Cooldown = attack_anim_tics + avg_movecount(7.5) * chase_tics(4)
      # In DOOM, monsters only attempt attacks when movecount reaches 0,
      # then play full attack animation before returning to chase.
      MONSTER_ATTACK = {
        3004 => { type: :hitscan, damage: [3, 15], cooldown: 56 },     # Zombieman
        9    => { type: :hitscan, damage: [3, 15], cooldown: 56 },     # Shotgun Guy
        3001 => { type: :projectile, cooldown: 52 },                    # Imp: fireball
        3002 => { type: :melee,  damage: [4, 40], cooldown: 42 },      # Demon
        58   => { type: :melee,  damage: [4, 40], cooldown: 42 },      # Spectre
        3003 => { type: :projectile, cooldown: 54 },                    # Baron: fireball
        69   => { type: :projectile, cooldown: 54 },                    # Hell Knight
        3005 => { type: :projectile, cooldown: 56 },                    # Cacodemon
        65   => { type: :hitscan, damage: [3, 15], cooldown: 40 },     # Heavy Weapon Dude
      }.freeze

      REACTIONTIME = 8  # Tics before first attack after activation (from mobjinfo)

      # Hitscan hit probability by distance (DOOM's P_AimLineAttack has bullet spread)
      # Close = ~85%, mid = ~60%, far = ~35%
      HITSCAN_ACCURACY = 0.85

      # Attack animation frames per sprite prefix (E, F, G typically)
      ATTACK_FRAMES = {
        'POSS' => %w[E F],       # Zombieman: raise, fire
        'SPOS' => %w[E F],       # Shotgun Guy
        'TROO' => %w[E F G H],   # Imp: raise, fireball, throw, recover
        'SARG' => %w[E F G],     # Demon: bite
        'HEAD' => %w[E F],       # Cacodemon
        'BOSS' => %w[E F G],     # Baron
        'BOS2' => %w[E F G],     # Hell Knight
        'CPOS' => %w[E F],       # Heavy Weapon Dude
      }.freeze

      ATTACK_FRAME_TICS = 8  # Tics per attack animation frame

      # Which frame index the actual attack happens on (matching Chocolate Doom)
      # Zombieman: A_PosAttack on frame F (index 1)
      # Imp: A_TroopAttack on frame G (index 2)
      # Demon: A_SargAttack on frame F (index 1)
      FIRE_FRAME_INDEX = {
        'POSS' => 1,  # Zombieman: E=raise, F=fire
        'SPOS' => 1,  # Shotgun Guy: E=raise, F=fire
        'TROO' => 2,  # Imp: E=raise, F=aim, G=throw, H=recover
        'SARG' => 1,  # Demon: E=open, F=bite, G=close
        'HEAD' => 1,  # Cacodemon: E=charge, F=fire
        'BOSS' => 1,  # Baron: E=raise, F=throw, G=recover
        'BOS2' => 1,  # Hell Knight
        'CPOS' => 1,  # Heavy Weapon Dude
      }.freeze

      MonsterState = Struct.new(:thing_idx, :x, :y, :movedir, :movecount,
                                :active, :chase_timer, :type, :attack_cooldown,
                                :reactiontime, :last_saw_player,
                                :attacking, :attack_frame_tic, :fired)

      def initialize(map, combat, player_state, sprites_mgr = nil)
        @map = map
        @combat = combat
        @player = player_state
        @sprites_mgr = sprites_mgr
        @monsters = []
        @aggression = true  # Monsters fight back (toggle with C)
        @damage_multiplier = 1.0
        @tic_counter = 0
        @monster_by_thing_idx = {}

        map.things.each_with_index do |thing, idx|
          next unless Combat::MONSTER_HP[thing.type]
          next if thing.type == Combat::BARREL_TYPE  # Barrels are damageable but not monsters
          mon = MonsterState.new(
            idx, thing.x.to_f, thing.y.to_f,
            DI_NODIR, 0, false, 0, thing.type, 0, REACTIONTIME, 0,
            false, 0, false
          )
          @monsters << mon
          @monster_by_thing_idx[idx] = mon
        end
      end

      attr_reader :monsters, :monster_by_thing_idx
      attr_accessor :aggression, :damage_multiplier

      # Called each game tic
      def update(player_x, player_y)
        @tic_counter += 1
        @monsters.each do |mon|
          next if @combat.dead?(mon.thing_idx)

          # Pain state: monster is stunned, skip movement and attacks
          next if @combat.in_pain?(mon.thing_idx)

          if mon.active
            # Attack animation in progress: freeze movement, tick animation
            if mon.attacking
              mon.attack_frame_tic += 1
              prefix = @sprites_mgr&.prefix_for(mon.type)
              frames = ATTACK_FRAMES[prefix]
              total_tics = (frames&.size || 2) * ATTACK_FRAME_TICS

              # Fire on the correct frame (matching Chocolate Doom)
              fire_idx = FIRE_FRAME_INDEX[prefix] || 1
              fire_tic = fire_idx * ATTACK_FRAME_TICS
              if !mon.fired && mon.attack_frame_tic >= fire_tic
                execute_attack(mon, player_x, player_y)
                mon.fired = true
              end

              if mon.attack_frame_tic >= total_tics
                mon.attacking = false
                mon.attack_frame_tic = 0
                mon.fired = false
              end
              next
            end

            mon.chase_timer -= 1
            if mon.chase_timer <= 0
              mon.chase_timer = CHASE_TICS
              chase(mon, player_x, player_y)
            end
          else
            look(mon, player_x, player_y)
          end
        end
      end

      private

      def look(mon, player_x, player_y)
        dx = player_x - mon.x
        dy = player_y - mon.y
        dist = Math.sqrt(dx * dx + dy * dy)
        return if dist > SIGHT_RANGE

        # DOOM A_Look: monster only sees in ~180-degree forward arc
        # unless player is very close (melee range)
        if dist > MELEE_RANGE
          thing = @map.things[mon.thing_idx]
          face_angle = thing.angle * Math::PI / 180.0
          to_player = Math.atan2(dy, dx)
          angle_diff = ((to_player - face_angle + Math::PI) % (2 * Math::PI) - Math::PI).abs
          return if angle_diff > Math::PI / 2  # 90 degrees each side = 180 arc
        end

        if has_line_of_sight?(mon.x, mon.y, player_x, player_y)
          mon.active = true
          mon.chase_timer = CHASE_TICS
        end
      end

      def chase(mon, player_x, player_y)
        speed = MONSTER_SPEED[mon.type] || 8

        # Tick down attack cooldown
        mon.attack_cooldown -= CHASE_TICS if mon.attack_cooldown > 0

        dx = player_x - mon.x
        dy = player_y - mon.y
        dist = Math.sqrt(dx * dx + dy * dy)

        # Track if monster can see the player
        can_see = dist < SIGHT_RANGE && has_line_of_sight?(mon.x, mon.y, player_x, player_y)
        if can_see
          mon.last_saw_player = @tic_counter
        elsif @tic_counter - (mon.last_saw_player || 0) > 105  # ~3 seconds without LOS
          # Monster gives up and goes idle (like DOOM's A_Chase returning to spawnstate)
          mon.active = false
          mon.reactiontime = REACTIONTIME
          return
        end

        # Only attempt attacks when: movecount == 0, has LOS, and in range
        if @aggression && mon.attack_cooldown <= 0 && mon.movecount <= 0 && can_see && !@player.dead
          attacked = try_attack(mon, player_x, player_y, dist)
        end

        # Move -- but ranged monsters stop advancing when they have LOS and are close enough
        # In DOOM, A_Chase skips movement when P_CheckMissileRange succeeds
        unless attacked
          atk = MONSTER_ATTACK[mon.type]
          ranged = atk && (atk[:type] == :hitscan || atk[:type] == :projectile)
          skip_move = ranged && can_see && dist < KEEP_DISTANCE

          if skip_move
            # Still tick movecount down so attack condition can trigger
            mon.movecount -= 1 if mon.movecount > 0
          else
            mon.movecount -= 1
            if mon.movecount < 0 || !try_move(mon, speed)
              new_chase_dir(mon, player_x, player_y)
            end
          end
        end

        # Update the thing's position and facing angle in the map for rendering
        thing = @map.things[mon.thing_idx]
        thing.x = mon.x.to_i
        thing.y = mon.y.to_i

        # Face toward the player
        target_angle = Math.atan2(player_y - mon.y, player_x - mon.x) * 180.0 / Math::PI
        thing.angle = target_angle.round.to_i
      end

      # Decide whether to start an attack (does NOT apply damage yet)
      def try_attack(mon, player_x, player_y, dist)
        if mon.reactiontime > 0
          mon.reactiontime -= 1
          return false
        end

        atk = MONSTER_ATTACK[mon.type]
        return false unless atk

        case atk[:type]
        when :melee
          return false if dist > MELEE_RANGE + (Combat::MONSTER_RADIUS[mon.type] || 20)
        when :hitscan, :projectile
          return false if dist > MISSILE_RANGE
          return false unless has_line_of_sight?(mon.x, mon.y, player_x, player_y)
          return false if rand(256) < dist
          if (mon.type == 3004 || mon.type == 9) && dist > 196
            return false if rand(2) == 0
          end
        end

        # Start attack animation (damage applied later on fire frame)
        mon.attacking = true
        mon.attack_frame_tic = 0
        mon.fired = false
        mon.attack_cooldown = atk[:cooldown]
        true
      end

      # Called on the fire frame of the attack animation
      def execute_attack(mon, player_x, player_y)
        atk = MONSTER_ATTACK[mon.type]
        return unless atk

        dx = player_x - mon.x
        dy = player_y - mon.y
        dist = Math.sqrt(dx * dx + dy * dy)

        case atk[:type]
        when :melee
          min_dmg, max_dmg = atk[:damage]
          damage = (rand(min_dmg..max_dmg) * @damage_multiplier).to_i
          @player.take_damage(damage) if damage > 0

        when :hitscan
          hit_chance = HITSCAN_ACCURACY * (1.0 - dist / (MISSILE_RANGE * 2))
          hit_chance = [hit_chance, 0.15].max
          if rand < hit_chance
            min_dmg, max_dmg = atk[:damage]
            damage = (rand(min_dmg..max_dmg) * @damage_multiplier).to_i
            @player.take_damage(damage) if damage > 0
          end

        when :projectile
          # P_SpawnMissile: z = source->z + 32 (chest height)
          sector = @map.sector_at(mon.x, mon.y)
          spawn_z = (sector ? sector.floor_height : 0) + 32
          @combat.spawn_monster_projectile(mon.x, mon.y, spawn_z, mon.type, @damage_multiplier)
        end
      end

      def try_move(mon, speed)
        return false if mon.movedir == DI_NODIR

        new_x = mon.x + speed * XSPEED[mon.movedir]
        new_y = mon.y + speed * YSPEED[mon.movedir]

        # Check if the position is valid (inside a sector, not blocked by walls)
        sector = @map.sector_at(new_x, new_y)
        return false unless sector

        # Check wall collision
        blocked = false
        @map.linedefs.each do |ld|
          v1 = @map.vertices[ld.v1]
          v2 = @map.vertices[ld.v2]

          # Simple line-circle intersection
          radius = Combat::MONSTER_RADIUS[mon.type] || 20
          next unless line_circle_intersect?(v1.x, v1.y, v2.x, v2.y, new_x, new_y, radius)

          # One-sided walls always block
          if ld.sidedef_left == 0xFFFF
            blocked = true
            break
          end

          # Two-sided: check step height and headroom
          if ld.sidedef_left < 0xFFFF
            front = @map.sectors[@map.sidedefs[ld.sidedef_right].sector]
            back = @map.sectors[@map.sidedefs[ld.sidedef_left].sector]
            step = (back.floor_height - front.floor_height).abs
            min_ceil = [front.ceiling_height, back.ceiling_height].min
            max_floor = [front.floor_height, back.floor_height].max
            if step > 24 || (min_ceil - max_floor) < 56
              blocked = true
              break
            end
          end
        end
        return false if blocked

        mon.x = new_x
        mon.y = new_y
        true
      end

      def new_chase_dir(mon, player_x, player_y)
        deltax = player_x - mon.x
        deltay = player_y - mon.y
        old_dir = mon.movedir

        # Determine preferred directions
        dir_x = if deltax > 10 then DI_EAST
                elsif deltax < -10 then DI_WEST
                else DI_NODIR
                end

        dir_y = if deltay > 10 then DI_NORTH
                elsif deltay < -10 then DI_SOUTH
                else DI_NODIR
                end

        # Try diagonal
        if dir_x != DI_NODIR && dir_y != DI_NODIR
          diag = diagonal_dir(dir_x, dir_y)
          if diag != OPPOSITE[old_dir]
            mon.movedir = diag
            if try_walk(mon)
              return
            end
          end
        end

        # Randomly swap X/Y priority
        if rand > 0.22 || deltay.abs > deltax.abs
          dir_x, dir_y = dir_y, dir_x
        end

        # Try primary direction
        if dir_x != DI_NODIR && dir_x != OPPOSITE[old_dir]
          mon.movedir = dir_x
          return if try_walk(mon)
        end

        # Try secondary direction
        if dir_y != DI_NODIR && dir_y != OPPOSITE[old_dir]
          mon.movedir = dir_y
          return if try_walk(mon)
        end

        # Try old direction
        if old_dir != DI_NODIR
          mon.movedir = old_dir
          return if try_walk(mon)
        end

        # Try all other directions
        start = rand(8)
        8.times do |i|
          d = (start + i) % 8
          next if d == OPPOSITE[old_dir]
          mon.movedir = d
          return if try_walk(mon)
        end

        # Last resort: turnaround
        if old_dir != DI_NODIR
          mon.movedir = OPPOSITE[old_dir]
          return if try_walk(mon)
        end

        mon.movedir = DI_NODIR
      end

      def try_walk(mon)
        speed = MONSTER_SPEED[mon.type] || 8
        if try_move(mon, speed)
          mon.movecount = rand(16)
          true
        else
          false
        end
      end

      def diagonal_dir(dx, dy)
        case [dx, dy]
        when [DI_EAST, DI_NORTH] then DI_NORTHEAST
        when [DI_EAST, DI_SOUTH] then DI_SOUTHEAST
        when [DI_WEST, DI_NORTH] then DI_NORTHWEST
        when [DI_WEST, DI_SOUTH] then DI_SOUTHWEST
        else DI_NODIR
        end
      end

      def has_line_of_sight?(x1, y1, x2, y2)
        # Check if any wall blocks the line of sight
        @map.linedefs.each do |ld|
          v1 = @map.vertices[ld.v1]
          v2 = @map.vertices[ld.v2]

          next unless segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)

          # One-sided walls always block
          return false if ld.sidedef_left == 0xFFFF

          # Two-sided: check if opening is big enough to see through
          if ld.sidedef_left < 0xFFFF
            front = @map.sectors[@map.sidedefs[ld.sidedef_right].sector]
            back = @map.sectors[@map.sidedefs[ld.sidedef_left].sector]
            max_floor = [front.floor_height, back.floor_height].max
            min_ceil = [front.ceiling_height, back.ceiling_height].min
            # Block sight if the opening is too small
            return false if (min_ceil - max_floor) < 1
          end
        end
        true
      end

      def segments_intersect?(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
        d1x = ax2 - ax1; d1y = ay2 - ay1
        d2x = bx2 - bx1; d2y = by2 - by1
        denom = d1x * d2y - d1y * d2x
        return false if denom.abs < 0.001
        dx = bx1 - ax1; dy = by1 - ay1
        t = (dx * d2y - dy * d2x).to_f / denom
        u = (dx * d1y - dy * d1x).to_f / denom
        t > 0.0 && t < 1.0 && u >= 0.0 && u <= 1.0
      end

      def line_circle_intersect?(x1, y1, x2, y2, cx, cy, radius)
        dx = cx - x1; dy = cy - y1
        line_dx = x2 - x1; line_dy = y2 - y1
        line_len_sq = line_dx * line_dx + line_dy * line_dy
        return false if line_len_sq == 0
        t = ((dx * line_dx) + (dy * line_dy)) / line_len_sq
        t = [[t, 0.0].max, 1.0].min
        closest_x = x1 + t * line_dx; closest_y = y1 + t * line_dy
        dist_sq = (cx - closest_x) ** 2 + (cy - closest_y) ** 2
        dist_sq < radius * radius
      end
    end
  end
end
