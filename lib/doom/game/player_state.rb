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

      # Attack durations in tics (at 35fps), matching DOOM's weapon state sequences
      ATTACK_DURATIONS = {
        WEAPON_FIST => 14,       # Punch windup + swing
        WEAPON_PISTOL => 16,     # S_PISTOL: 6+4+5+1 tics
        WEAPON_SHOTGUN => 40,    # Pump action cycle
        WEAPON_CHAINGUN => 8,    # Rapid fire (2 shots per cycle)
        WEAPON_ROCKET => 20,     # Rocket launch + recovery
        WEAPON_PLASMA => 8,      # Fast energy weapon
        WEAPON_BFG => 60,        # Long charge + fire
        WEAPON_CHAINSAW => 6     # Fast melee
      }.freeze

      attr_accessor :health, :armor, :max_health, :max_armor
      attr_accessor :ammo_bullets, :ammo_shells, :ammo_rockets, :ammo_cells
      attr_accessor :max_bullets, :max_shells, :max_rockets, :max_cells
      attr_accessor :weapon, :has_weapons
      attr_accessor :keys
      attr_accessor :attacking, :attack_frame, :attack_tics
      attr_accessor :bob_angle, :bob_amount
      attr_accessor :is_moving

      # Smooth step-up/down (matching Chocolate Doom's P_CalcHeight / P_ZMovement)
      VIEWHEIGHT = 41.0
      VIEWHEIGHT_HALF = VIEWHEIGHT / 2.0
      DELTA_ACCEL = 0.25        # deltaviewheight += FRACUNIT/4 per tic
      attr_reader :viewheight, :deltaviewheight

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

        # Smooth step height (P_CalcHeight viewheight/deltaviewheight)
        @viewheight = VIEWHEIGHT
        @deltaviewheight = 0.0

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

      # Called when player moves onto a different floor height.
      # Matches Chocolate Doom P_ZMovement: reduce viewheight by the step amount
      # so the camera doesn't snap, then let P_CalcHeight recover it smoothly.
      def notify_step(step_amount)
        return if step_amount == 0
        @viewheight -= step_amount
        @deltaviewheight = (VIEWHEIGHT - @viewheight) / 8.0
      end

      # Gradually restore viewheight to VIEWHEIGHT (called each tic).
      # Matches Chocolate Doom P_CalcHeight viewheight recovery loop.
      # For step-up: viewheight < 41, delta > 0, accelerates upward.
      # For step-down: viewheight > 41, delta < 0, decelerates then recovers.
      def update_viewheight
        @viewheight += @deltaviewheight

        if @viewheight > VIEWHEIGHT && @deltaviewheight >= 0
          @viewheight = VIEWHEIGHT
          @deltaviewheight = 0.0
        end

        if @viewheight < VIEWHEIGHT_HALF
          @viewheight = VIEWHEIGHT_HALF
          @deltaviewheight = 1.0 if @deltaviewheight <= 0
        end

        if @deltaviewheight != 0
          @deltaviewheight += DELTA_ACCEL
          @deltaviewheight = 0.0 if @deltaviewheight.abs < 0.01 && (@viewheight - VIEWHEIGHT).abs < 0.5
        end
      end

      # Set movement momentum directly (called from GosuWindow with actual
      # movement momentum, which already has thrust + friction applied).
      def set_movement_momentum(momx, momy)
        @momx = momx
        @momy = momy
      end

      # Compute view bob from actual movement momentum.
      # Matches Chocolate Doom P_CalcHeight:
      #   bob = (momx*momx + momy*momy) >> 2, capped at MAXBOB
      #   viewz += finesine[angle] * bob/2
      # Momentum is in units/sec; DOOM's bob uses units/tic (divide by 35).
      BOB_MOM_SCALE = 1.0 / (35.0 * 35.0 * 4.0)  # (mom/35)^2 / 4

      def update_view_bob(delta_time)
        dt = delta_time.clamp(0.001, 0.05)

        # P_CalcHeight: bob = (momx_per_tic^2 + momy_per_tic^2) / 4, capped at MAXBOB
        bob = (@momx * @momx + @momy * @momy) * BOB_MOM_SCALE
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
