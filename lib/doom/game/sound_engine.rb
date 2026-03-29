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
        PlayerState::WEAPON_PLASMA => 'DSPLASMA',
        PlayerState::WEAPON_BFG => 'DSBFG',
        PlayerState::WEAPON_CHAINSAW => 'DSSAWIDL',
      }.freeze

      # Monster see/activation sounds (from mobjinfo seesound)
      MONSTER_SEE = {
        3004 => 'DSPOSIT1',  # Zombieman
        9    => 'DSSGTSIT',  # Shotgun Guy
        3001 => 'DSBGSIT1',  # Imp
        3002 => 'DSSGTSIT',  # Demon
        58   => 'DSSGTSIT',  # Spectre
        3003 => 'DSBRSSIT',  # Baron
        69   => 'DSBRSSIT',  # Hell Knight
        3005 => 'DSCACSIT',  # Cacodemon
        3006 => 'DSSKLATK',  # Lost Soul
        65   => 'DSPOSIT2',  # Heavy Weapon Dude
        16   => 'DSCYBSIT',  # Cyberdemon
        7    => 'DSSPISIT',  # Spider Mastermind
      }.freeze

      # Monster death sounds (from mobjinfo deathsound)
      MONSTER_DEATH = {
        3004 => 'DSPODTH1',  # Zombieman
        9    => 'DSSGTDTH',  # Shotgun Guy
        3001 => 'DSBGDTH1',  # Imp
        3002 => 'DSSGTDTH',  # Demon
        58   => 'DSSGTDTH',  # Spectre
        3003 => 'DSBRSDTH',  # Baron
        69   => 'DSBRSDTH',  # Hell Knight
        3005 => 'DSCACDTH',  # Cacodemon
        3006 => 'DSFIRXPL',  # Lost Soul
        65   => 'DSPODTH2',  # Heavy Weapon Dude
        16   => 'DSCYBDTH',  # Cyberdemon
        7    => 'DSSPIDTH',  # Spider Mastermind
      }.freeze

      # Monster pain sounds (from mobjinfo painsound)
      MONSTER_PAIN = {
        3004 => 'DSPOPAIN',  # Zombieman
        9    => 'DSPOPAIN',  # Shotgun Guy
        3001 => 'DSDMPAIN',  # Imp
        3002 => 'DSDMPAIN',  # Demon
        58   => 'DSDMPAIN',  # Spectre
        3003 => 'DSDMPAIN',  # Baron
        69   => 'DSDMPAIN',  # Hell Knight
        3005 => 'DSDMPAIN',  # Cacodemon
        3006 => 'DSDMPAIN',  # Lost Soul
        65   => 'DSPOPAIN',  # Heavy Weapon Dude
      }.freeze

      # Monster attack sounds (from mobjinfo attacksound)
      MONSTER_ATTACK = {
        3004 => 'DSPISTOL',  # Zombieman: pistol
        9    => 'DSSHOTGN',  # Shotgun Guy: shotgun
        3001 => 'DSFIRSHT',  # Imp: fireball launch
        3002 => 'DSSGTATK',  # Demon: bite
        58   => 'DSSGTATK',  # Spectre: bite
        3003 => 'DSFIRSHT',  # Baron: fireball
        69   => 'DSFIRSHT',  # Hell Knight: fireball
        3005 => 'DSFIRSHT',  # Cacodemon: fireball
        65   => 'DSSHOTGN',  # Heavy Weapon Dude: chaingun burst
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

      # --- Menu sounds ---
      def menu_move
        play('DSPSTOP', throttle: 0.05)
      end

      def menu_select
        play('DSPISTOL')
      end

      def menu_back
        play('DSSWTCHX')
      end

      # --- Weapon events ---
      def weapon_fire(weapon)
        sound = WEAPON_SOUNDS[weapon]
        play(sound, throttle: 0.05) if sound
      end

      def shotgun_cock
        play('DSSGCOCK', throttle: 0.3)
      end

      def chainsaw_hit
        play('DSSAWFUL', throttle: 0.1)
      end

      # --- Player events ---
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

      def oof
        play('DSOOF', throttle: 0.3)
      end

      def noway
        play('DSNOWAY', throttle: 0.3)
      end

      # --- Door/environment sounds ---
      def door_open
        play('DSDOROPN', throttle: 0.2)
      end

      def door_close
        play('DSDORCLS', throttle: 0.2)
      end

      def switch_activate
        play('DSSWTCHN')
      end

      def platform_start
        play('DSPSTART', throttle: 0.2)
      end

      def platform_stop
        play('DSPSTOP', throttle: 0.2)
      end

      # --- Monster sounds ---
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

      # --- Explosions / impacts ---
      def explosion
        play('DSBAREXP')
      end

      def rocket_explode
        play('DSRXPLOD')
      end

      def fireball_hit
        play('DSFIRXPL', throttle: 0.1)
      end
    end
  end
end
