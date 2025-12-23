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
