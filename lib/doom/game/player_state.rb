# frozen_string_literal: true

module Doom
  module Game
    # Tracks player state for HUD display and weapon rendering
    class PlayerState
      # Weapons
      WEAPON_FIST = 0
      WEAPON_PISTOL = 1
      WEAPON_SHOTGUN = 2
      WEAPON_CHAINGUN = 3
      WEAPON_ROCKET = 4
      WEAPON_PLASMA = 5
      WEAPON_BFG = 6
      WEAPON_CHAINSAW = 7

      # Weapon symbols for graphics lookup
      WEAPON_NAMES = {
        WEAPON_FIST => :fist,
        WEAPON_PISTOL => :pistol,
        WEAPON_SHOTGUN => :shotgun,
        WEAPON_CHAINGUN => :chaingun,
        WEAPON_ROCKET => :rocket,
        WEAPON_PLASMA => :plasma,
        WEAPON_BFG => :bfg,
        WEAPON_CHAINSAW => :chainsaw
      }.freeze

      # Attack durations (in frames at 35fps)
      ATTACK_DURATIONS = {
        WEAPON_FIST => 12,
        WEAPON_PISTOL => 8,
        WEAPON_SHOTGUN => 20,
        WEAPON_CHAINGUN => 4,
        WEAPON_ROCKET => 16,
        WEAPON_PLASMA => 6,
        WEAPON_BFG => 40,
        WEAPON_CHAINSAW => 4
      }.freeze

      attr_accessor :health, :armor, :max_health, :max_armor
      attr_accessor :ammo_bullets, :ammo_shells, :ammo_rockets, :ammo_cells
      attr_accessor :max_bullets, :max_shells, :max_rockets, :max_cells
      attr_accessor :weapon, :has_weapons
      attr_accessor :keys
      attr_accessor :attacking, :attack_frame, :attack_tics
      attr_accessor :bob_angle, :bob_amount
      attr_accessor :is_moving

      # View bob (camera bounce when walking, matching Chocolate Doom's
      # P_CalcHeight + P_XYMovement + P_Thrust from p_user.c / p_mobj.c)
      MAXBOB = 16.0           # Maximum bob amplitude (0x100000 in fixed-point = 16 map units)
      STOPSPEED = 0.0625      # Snap-to-zero threshold (0x1000 in fixed-point)
      # Continuous-time equivalents of DOOM's per-tic constants (35 fps tic rate):
      #   FRICTION = 0xE800/0x10000 = 0.90625 per tic
      #   decay_rate = -ln(0.90625) * 35 = 3.44/sec
      #   walk thrust = forwardmove(25) * 2048 / 65536 = 0.78 map units/tic = 27.3/sec
      #   terminal velocity = 27.3 / 3.44 = 7.56 -> bob = 7.56^2/4 = 14.3 (89% of MAXBOB)
      BOB_DECAY_RATE = 3.44   # Friction as continuous decay rate (1/sec)
      BOB_THRUST = 26.0       # Walk thrust (map units/sec), gives terminal ~7.5
      BOB_FREQUENCY = 11.0    # Bob cycle frequency (rad/sec): FINEANGLES/20 * 35 / 8192 * 2*PI
      attr_reader :view_bob_offset

      def initialize
        reset
      end

      def reset
        @health = 100
        @armor = 0
        @max_health = 100
        @max_armor = 200

        # Ammo
        @ammo_bullets = 50
        @ammo_shells = 0
        @ammo_rockets = 0
        @ammo_cells = 0

        @max_bullets = 200
        @max_shells = 50
        @max_rockets = 50
        @max_cells = 300

        # Start with fist and pistol
        @weapon = WEAPON_PISTOL
        @has_weapons = [true, true, false, false, false, false, false, false]

        # No keys
        @keys = {
          blue_card: false,
          yellow_card: false,
          red_card: false,
          blue_skull: false,
          yellow_skull: false,
          red_skull: false
        }

        # Attack state
        @attacking = false
        @attack_frame = 0
        @attack_tics = 0

        # Weapon bob
        @bob_angle = 0.0
        @bob_amount = 0.0
        @is_moving = false

        # View bob (camera bounce) - simulated momentum for P_CalcHeight
        @view_bob_offset = 0.0
        @momx = 0.0        # Simulated X momentum (map units/sec, not actual movement)
        @momy = 0.0        # Simulated Y momentum
        @thrust_x = 0.0    # Per-frame thrust input (raw, before normalization)
        @thrust_y = 0.0
        @view_bob_angle = 0.0
      end

      def weapon_name
        WEAPON_NAMES[@weapon]
      end

      def current_ammo
        case @weapon
        when WEAPON_PISTOL, WEAPON_CHAINGUN
          @ammo_bullets
        when WEAPON_SHOTGUN
          @ammo_shells
        when WEAPON_ROCKET
          @ammo_rockets
        when WEAPON_PLASMA, WEAPON_BFG
          @ammo_cells
        else
          nil # Fist/chainsaw don't use ammo
        end
      end

      def max_ammo_for_weapon
        case @weapon
        when WEAPON_PISTOL, WEAPON_CHAINGUN
          @max_bullets
        when WEAPON_SHOTGUN
          @max_shells
        when WEAPON_ROCKET
          @max_rockets
        when WEAPON_PLASMA, WEAPON_BFG
          @max_cells
        else
          nil
        end
      end

      def can_attack?
        return true if @weapon == WEAPON_FIST || @weapon == WEAPON_CHAINSAW

        ammo = current_ammo
        ammo && ammo > 0
      end

      def start_attack
        return unless can_attack?
        return if @attacking

        @attacking = true
        @attack_frame = 0
        @attack_tics = 0

        # Consume ammo
        case @weapon
        when WEAPON_PISTOL
          @ammo_bullets -= 1 if @ammo_bullets > 0
        when WEAPON_SHOTGUN
          @ammo_shells -= 1 if @ammo_shells > 0
        when WEAPON_CHAINGUN
          @ammo_bullets -= 1 if @ammo_bullets > 0
        when WEAPON_ROCKET
          @ammo_rockets -= 1 if @ammo_rockets > 0
        when WEAPON_PLASMA
          @ammo_cells -= 1 if @ammo_cells > 0
        when WEAPON_BFG
          @ammo_cells -= 40 if @ammo_cells >= 40
        end
      end

      def update_attack
        return unless @attacking

        @attack_tics += 1

        # Calculate which frame we're on based on tics
        duration = ATTACK_DURATIONS[@weapon] || 8
        frame_count = @weapon == WEAPON_FIST ? 3 : 4

        tics_per_frame = duration / frame_count
        @attack_frame = (@attack_tics / tics_per_frame).to_i

        # Attack finished?
        if @attack_tics >= duration
          @attacking = false
          @attack_frame = 0
          @attack_tics = 0
        end
      end

      def update_bob(delta_time)
        if @is_moving
          # Increase bob while moving
          @bob_angle += delta_time * 10.0
          @bob_amount = [@bob_amount + delta_time * 16.0, 6.0].min
        else
          # Decay bob when stopped
          @bob_amount = [@bob_amount - delta_time * 12.0, 0.0].max
        end
      end

      # Set per-frame thrust direction (called from GosuWindow with raw input velocity).
      def set_thrust(tx, ty)
        @thrust_x = tx
        @thrust_y = ty
      end

      # Simulate Chocolate Doom's momentum and view bob, frame-rate independently.
      #
      # In Chocolate Doom (per tic at 35 fps):
      #   P_Thrust:       momx += forwardmove * 2048 * cos(angle)   [additive]
      #   P_XYMovement:   momx *= FRICTION (0.90625)                [multiplicative]
      #   P_CalcHeight:   bob = (momx*momx + momy*momy) >> 2        [capped at MAXBOB]
      #                   viewz += finesine[angle] * bob/2
      #
      # We use continuous-time equivalents so the bob feels identical regardless
      # of frame rate: dv/dt = thrust - decay_rate * v
      def update_view_bob(delta_time)
        dt = delta_time.clamp(0.001, 0.05)

        # P_Thrust: normalize input direction, apply constant walk thrust
        speed = Math.sqrt(@thrust_x * @thrust_x + @thrust_y * @thrust_y)
        if speed > 0
          @momx += (@thrust_x / speed) * BOB_THRUST * dt
          @momy += (@thrust_y / speed) * BOB_THRUST * dt
        end
        @thrust_x = 0.0
        @thrust_y = 0.0

        # P_XYMovement: exponential friction decay (continuous equivalent of *= 0.90625 per tic)
        decay = Math.exp(-BOB_DECAY_RATE * dt)
        @momx *= decay
        @momy *= decay

        # P_XYMovement STOPSPEED: snap to zero when slow and no input
        if @momx.abs < STOPSPEED && @momy.abs < STOPSPEED && speed == 0
          @momx = 0.0
          @momy = 0.0
        end

        # P_CalcHeight: bob = (momx^2 + momy^2) / 4, capped at MAXBOB
        bob = (@momx * @momx + @momy * @momy) / 4.0
        bob = MAXBOB if bob > MAXBOB

        # Advance bob sine wave (FINEANGLES/20 per tic = ~11 rad/sec)
        @view_bob_angle += BOB_FREQUENCY * dt

        # viewz offset: sin(angle) * bob/2
        @view_bob_offset = Math.sin(@view_bob_angle) * bob / 2.0
      end

      def weapon_bob_x
        Math.cos(@bob_angle) * @bob_amount
      end

      def weapon_bob_y
        Math.sin(@bob_angle * 2) * @bob_amount * 0.5
      end

      def health_level
        # 0 = dying, 4 = full health
        case @health
        when 80..200 then 4
        when 60..79 then 3
        when 40..59 then 2
        when 20..39 then 1
        else 0
        end
      end

      def switch_weapon(weapon_num)
        return unless weapon_num >= 0 && weapon_num < 8
        return unless @has_weapons[weapon_num]
        return if @attacking

        @weapon = weapon_num
      end
    end
  end
end
