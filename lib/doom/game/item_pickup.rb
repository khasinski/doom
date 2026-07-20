# frozen_string_literal: true

module Doom
  module Game
    # Handles item pickup when player touches things.
    # Matches Chocolate Doom's P_TouchSpecialThing from p_inter.c.
    class ItemPickup
      PLAYER_RADIUS = 16.0
      THING_RADIUS = 20.0
      PICKUP_DIST = PLAYER_RADIUS + THING_RADIUS  # 36 units (bounding box overlap)

      # Item definitions: type => { category, value, ... }
      ITEMS = {
        # Weapons (give weapon + some ammo)
        2001 => { cat: :weapon, weapon: 2, ammo: :shells, amount: 8 },    # Shotgun
        2002 => { cat: :weapon, weapon: 3, ammo: :bullets, amount: 20 },  # Chaingun
        2003 => { cat: :weapon, weapon: 4, ammo: :rockets, amount: 2 },   # Rocket launcher
        2004 => { cat: :weapon, weapon: 5, ammo: :cells, amount: 40 },    # Plasma rifle
        2006 => { cat: :weapon, weapon: 6, ammo: :cells, amount: 40 },    # BFG9000
        2005 => { cat: :weapon, weapon: 7, ammo: :bullets, amount: 0 },   # Chainsaw

        # Ammo
        2007 => { cat: :ammo, ammo: :bullets, amount: 10 },   # Clip
        2048 => { cat: :ammo, ammo: :bullets, amount: 50 },   # Box of bullets
        2008 => { cat: :ammo, ammo: :shells, amount: 4 },     # 4 shells
        2049 => { cat: :ammo, ammo: :shells, amount: 20 },    # Box of shells
        2010 => { cat: :ammo, ammo: :rockets, amount: 1 },    # Rocket
        2046 => { cat: :ammo, ammo: :rockets, amount: 5 },    # Box of rockets
        17   => { cat: :ammo, ammo: :cells, amount: 20 },     # Cell charge
        2047 => { cat: :ammo, ammo: :cells, amount: 100 },    # Cell pack
        8    => { cat: :backpack },                             # Backpack (doubles max ammo + some ammo)

        # Health
        2014 => { cat: :health, amount: 1, max: 200 },        # Health bonus (+1, up to 200)
        2011 => { cat: :health, amount: 10, max: 100 },       # Stimpack
        2012 => { cat: :health, amount: 25, max: 100 },       # Medikit
        2013 => { cat: :health, amount: 100, max: 200 },      # Soul sphere

        # Armor
        2015 => { cat: :armor, amount: 1, max: 200 },         # Armor bonus (+1, up to 200)
        2018 => { cat: :armor, amount: 100, armor_type: 1 },   # Green armor (100%, absorbs 1/3)
        2019 => { cat: :armor, amount: 200, armor_type: 2 },   # Blue armor (200%, absorbs 1/2)

        # Keys
        5  => { cat: :key, key: :blue_card },
        6  => { cat: :key, key: :yellow_card },
        13 => { cat: :key, key: :red_card },
        40 => { cat: :key, key: :blue_skull },
        39 => { cat: :key, key: :yellow_skull },
        38 => { cat: :key, key: :red_skull },
      }.freeze

      MESSAGETICS = 140    # 4 * TICRATE (4 seconds, matching Chocolate Doom)
      FLASH_TICS = 8       # Yellow palette flash duration

      attr_reader :picked_up, :pickup_message, :pickup_flash, :message_tics
      attr_accessor :ammo_multiplier, :hidden_things

      def initialize(map, _player_state = nil, hidden_things = {})
        @map = map
        @picked_up = {}
        @hidden_things = hidden_things
        @ammo_multiplier = 1
        @pickup_message = nil
        @pickup_flash = 0     # Yellow screen flash (short)
        @message_tics = 0     # Message display timer (long)
      end

      # Decay timers each tic
      def update_flash
        @pickup_flash -= 1 if @pickup_flash > 0
        @message_tics -= 1 if @message_tics > 0
      end

      # Pick up for one player. `picked_up` stays global on purpose: in coop an
      # item taken by anyone is gone for everyone, as in DOOM. Deathmatch
      # respawning is a separate concern.
      def update(player)
        state = player.state
        @map.things.each_with_index do |thing, idx|
          next if @hidden_things[idx]
          next if @picked_up[idx]
          item = ITEMS[thing.type]
          next unless item

          dx = (player.x - thing.x).abs
          dy = (player.y - thing.y).abs
          next if dx >= PICKUP_DIST || dy >= PICKUP_DIST

          if try_pickup(item, state)
            @picked_up[idx] = true
            @pickup_message = PICKUP_MESSAGES[thing.type]
            @pickup_flash = FLASH_TICS
            @message_tics = MESSAGETICS
          end
        end
      end

      PICKUP_MESSAGES = {
        2001 => "A SHOTGUN!", 2002 => "A CHAINGUN!", 2003 => "A ROCKET LAUNCHER!",
        2004 => "A PLASMA RIFLE!", 2005 => "A CHAINSAW!", 2006 => "A BFG9000!",
        2007 => "PICKED UP A CLIP.", 2048 => "PICKED UP A BOX OF BULLETS.",
        2008 => "PICKED UP 4 SHOTGUN SHELLS.", 2049 => "PICKED UP A BOX OF SHELLS.",
        2010 => "PICKED UP A ROCKET.", 2046 => "PICKED UP A BOX OF ROCKETS.",
        17 => "PICKED UP AN ENERGY CELL.", 2047 => "PICKED UP AN ENERGY CELL PACK.",
        8 => "PICKED UP A BACKPACK FULL OF AMMO!",
        2011 => "PICKED UP A STIMPACK.", 2012 => "PICKED UP A MEDIKIT.",
        2014 => "PICKED UP A HEALTH BONUS.", 2015 => "PICKED UP AN ARMOR BONUS.",
        2018 => "PICKED UP THE ARMOR.", 2019 => "PICKED UP THE MEGAARMOR!",
        2013 => "SUPERCHARGE!",
        5 => "PICKED UP A BLUE KEYCARD.", 6 => "PICKED UP A YELLOW KEYCARD.",
        13 => "PICKED UP A RED KEYCARD.", 40 => "PICKED UP A BLUE SKULL KEY.",
        39 => "PICKED UP A YELLOW SKULL KEY.", 38 => "PICKED UP A RED SKULL KEY.",
      }.freeze

      private

      def try_pickup(item, state)
        case item[:cat]
        when :weapon
          give_weapon(item, state)
        when :ammo
          give_ammo(item[:ammo], item[:amount], state)
        when :backpack
          give_backpack(state)
        when :health
          give_health(item[:amount], item[:max], state)
        when :armor
          give_armor(item, state)
        when :key
          give_key(item[:key], state)
        else
          false
        end
      end

      def give_weapon(item, state)
        weapon_idx = item[:weapon]
        had_weapon = state.has_weapons[weapon_idx]

        state.has_weapons[weapon_idx] = true
        ammo_given = item[:ammo] ? give_ammo(item[:ammo], item[:amount], state) : false

        unless had_weapon
          state.switch_weapon(weapon_idx) unless state.attacking
          return true
        end

        ammo_given
      end

      def give_ammo(type, amount, state)
        amount = amount * @ammo_multiplier
        case type
        when :bullets
          return false if state.ammo_bullets >= state.max_bullets
          state.ammo_bullets = [state.ammo_bullets + amount, state.max_bullets].min
        when :shells
          return false if state.ammo_shells >= state.max_shells
          state.ammo_shells = [state.ammo_shells + amount, state.max_shells].min
        when :rockets
          return false if state.ammo_rockets >= state.max_rockets
          state.ammo_rockets = [state.ammo_rockets + amount, state.max_rockets].min
        when :cells
          return false if state.ammo_cells >= state.max_cells
          state.ammo_cells = [state.ammo_cells + amount, state.max_cells].min
        end
        true
      end

      def give_backpack(state)
        state.max_bullets = 400
        state.max_shells = 100
        state.max_rockets = 100
        state.max_cells = 600
        give_ammo(:bullets, 10, state)
        give_ammo(:shells, 4, state)
        give_ammo(:rockets, 1, state)
        give_ammo(:cells, 20, state)
        true
      end

      def give_health(amount, max, state)
        return false if state.health >= max
        state.health = [state.health + amount, max].min
        true
      end

      def give_armor(item, state)
        if item[:armor_type]
          # Green/blue armor: only pick up if better than current
          return false if state.armor >= item[:amount]
          state.armor = item[:amount]
        else
          # Armor bonus: +1, up to max
          return false if state.armor >= item[:max]
          state.armor = [state.armor + item[:amount], item[:max]].min
        end
        true
      end

      def give_key(key, state)
        return false if state.keys[key]
        state.keys[key] = true
        true
      end
    end
  end
end
