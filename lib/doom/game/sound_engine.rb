# frozen_string_literal: true

module Doom
  module Game
    # Plays sound effects for game events.
    class SoundEngine
      # Weapon fire sounds
      WEAPON_SOUNDS = {
        PlayerState::WEAPON_FIST => 'DSPUNCH',
        PlayerState::WEAPON_PISTOL => 'DSPISTOL',
        PlayerState::WEAPON_SHOTGUN => 'DSSHOTGN',
        PlayerState::WEAPON_CHAINGUN => 'DSPISTOL',
        PlayerState::WEAPON_ROCKET => 'DSRLAUNC',
        PlayerState::WEAPON_PLASMA => 'DSFIRSHT',
        PlayerState::WEAPON_BFG => 'DSFIRSHT',
        PlayerState::WEAPON_CHAINSAW => 'DSSAWIDL',
      }.freeze

      # Monster sounds
      MONSTER_SEE = {
        3004 => 'DSPOSIT1',  # Zombieman
        9    => 'DSSGTSIT',  # Shotgun Guy
        3001 => 'DSBGSIT1',  # Imp
        3002 => 'DSSGTSIT',  # Demon
        3003 => 'DSBRSSIT',  # Baron
      }.freeze

      MONSTER_DEATH = {
        3004 => 'DSPODTH1',  # Zombieman
        9    => 'DSSGTDTH',  # Shotgun Guy
        3001 => 'DSBGDTH1',  # Imp
        3002 => 'DSSGTDTH',  # Demon
        3003 => 'DSBRSDTH',  # Baron
      }.freeze

      MONSTER_PAIN = {
        3004 => 'DSPOPAIN',  # Zombieman
        9    => 'DSPOPAIN',  # Shotgun Guy
        3001 => 'DSDMPAIN',  # Imp
        3002 => 'DSDMPAIN',  # Demon
      }.freeze

      MONSTER_ATTACK = {
        3004 => 'DSPOSIT1',  # Zombieman fires
        9    => 'DSSGTATK',  # Shotgun Guy fires
        3001 => 'DSFIRSHT',  # Imp fireball
      }.freeze

      def initialize(sound_manager)
        @sounds = sound_manager
        @last_played = {}  # Throttle rapid repeats
      end

      def play(name, volume: 1.0, throttle: 0)
        now = Time.now.to_f
        if throttle > 0
          return if @last_played[name] && (now - @last_played[name]) < throttle
        end
        sample = @sounds[name]
        sample&.play(volume)
        @last_played[name] = now
      end

      # Game event hooks
      def weapon_fire(weapon)
        sound = WEAPON_SOUNDS[weapon]
        play(sound, throttle: 0.05) if sound
      end

      def player_pain
        play('DSPLPAIN', throttle: 0.3)
      end

      def player_death
        play('DSPLDETH')
      end

      def item_pickup
        play('DSITEMUP', throttle: 0.1)
      end

      def weapon_pickup
        play('DSWPNUP')
      end

      def door_open
        play('DSDOROPN', throttle: 0.2)
      end

      def door_close
        play('DSDORCLS', throttle: 0.2)
      end

      def switch_activate
        play('DSSWTCHN')
      end

      def monster_see(type)
        sound = MONSTER_SEE[type]
        play(sound, throttle: 0.5) if sound
      end

      def monster_death(type)
        sound = MONSTER_DEATH[type]
        play(sound) if sound
      end

      def monster_pain(type)
        sound = MONSTER_PAIN[type]
        play(sound, throttle: 0.2) if sound
      end

      def monster_attack(type)
        sound = MONSTER_ATTACK[type]
        play(sound, throttle: 0.1) if sound
      end

      def explosion
        play('DSBAREXP')
      end

      def rocket_explode
        play('DSRXPLOD')
      end

      def oof
        play('DSOOF', throttle: 0.3)
      end
    end
  end
end
