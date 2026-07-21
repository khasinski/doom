# frozen_string_literal: true

module Doom
  module Game
    # The simulation, with no dependency on Gosu or any window.
    #
    # Everything that decides what happens in the game lives here and advances
    # only through run_tic. The platform layer is reduced to two jobs: turn
    # input into ticcmds, and draw the result. That split is what makes
    # lockstep multiplayer possible -- the netcode drives run_tic directly,
    # with no display attached, and two peers feeding equal ticcmds reach equal
    # worlds.
    #
    # Sound is emitted but never read back, so it cannot influence state.
    class World
      TIC_SECONDS = 1.0 / 35.0
      SECTOR_DAMAGE_INTERVAL = 32  # Tics between nukage/lava ticks
      USE_DISTANCE = 64.0          # Max distance to use a linedef

      # Sector specials that hurt the player, damage per interval.
      SECTOR_DAMAGE = {
        4 => 20, 5 => 10, 7 => 5, 16 => 20, 11 => 20,
      }.freeze

      MODES = %i[coop deathmatch].freeze

      attr_reader :map, :players, :random, :leveltime, :mode
      attr_reader :combat, :monster_ai, :item_pickup, :sector_actions, :sector_effects
      attr_reader :physics_by_id
      # Frags needed to win, or nil for an open-ended match.
      attr_reader :frag_limit
      attr_accessor :damage_multiplier, :skill_hidden

      def initialize(map, sprites:, sound: nil, random: Random.new, skill_hidden: {}, mode: :coop,
                     frag_limit: nil)
        raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

        @map = map
        @sprites = sprites
        @sound = sound
        @random = random
        @mode = mode
        @frag_limit = frag_limit
        @skill_hidden = skill_hidden
        @damage_multiplier = 1.0
        @leveltime = 0

        @players = []
        @physics_by_id = {}

        @sector_actions = SectorActions.new(map, sound)
        @sector_effects = SectorEffects.new(map, random: random)
        @item_pickup = ItemPickup.new(map, nil, skill_hidden)
        @combat = Combat.new(map, nil, sprites, skill_hidden, sound, random: random)
        @monster_ai = MonsterAI.new(map, @combat, nil, sprites, skill_hidden, sound, random: random)
      end

      def deathmatch?
        @mode == :deathmatch
      end

      # Spawn a player. With no explicit start, the world picks one for this
      # player id: its own co-op start in co-op, a random one in deathmatch.
      def add_player(start_thing = nil, id: @players.size)
        start_thing ||= spawn_point_for(id)
        raise ArgumentError, 'map has no player start' unless start_thing

        player = Player.new(id: id)
        player.place(start_thing.x, start_thing.y, PlayerState::VIEWHEIGHT, start_thing.angle)

        physics = PlayerPhysics.new(@map, player.state)
        physics.skill_hidden = @skill_hidden
        physics.item_pickup = @item_pickup
        physics.combat = @combat
        physics.settle(player, player.x, player.y)

        @players << player
        @physics_by_id[player.id] = physics
        @combat.players = @players
        player
      end

      def player(id = 0)
        @players.find { |p| p.id == id }
      end

      # Remove a player mid-match: someone left, or the server timed them out.
      # Pure bookkeeping, no RNG, so it stays deterministic across peers as long
      # as they all remove the same id on the same tic. Monsters targeting the
      # departed player re-pick next tic via MonsterAI's own dead/absent check.
      def remove_player(id)
        player = @players.find { |p| p.id == id }
        return unless player

        @players.delete(player)
        @physics_by_id.delete(id)
        @combat.players = @players
        @monster_ai.monsters.each { |m| m.target = nil if m.target&.id == id }
        player
      end

      # Where player `id` enters the map. Deathmatch draws from the map's DM
      # spawns through the shared RNG, so every peer picks the same one.
      def spawn_point_for(id)
        if @mode == :deathmatch
          starts = @map.deathmatch_starts
          return starts[@random.rand(starts.size)] unless starts.empty?
        end

        @map.player_start_for(id)
      end

      # Bring one player back to life at its spawn point, leaving the rest of
      # the world alone. This is what multiplayer death does: the others are
      # still playing, so monsters and items must not reset under them.
      def respawn(player = primary)
        return unless player

        player.state.reset
        start = spawn_point_for(player.id)
        return unless start

        physics = physics_for(player)
        physics.reset
        player.place(start.x, start.y, PlayerState::VIEWHEIGHT, start.angle)
        physics.settle(player, player.x, player.y)
      end

      # Single-player death: wipe monster/item/projectile state and start the
      # level over. Monsters are rebuilt rather than revived because their HP,
      # death and pain state live in Combat keyed by thing index.
      def restart_level(player = primary)
        return unless player

        rebuild_actor_subsystems
        physics = physics_for(player)
        physics.item_pickup = @item_pickup
        physics.combat = @combat
        respawn(player)
      end

      def physics_for(player)
        @physics_by_id[player.id]
      end

      # Deathmatch score, player id => frags.
      def frags
        @players.to_h { |p| [p.id, p.frags] }
      end

      # Who is winning. Ties break on the lowest player id rather than on
      # @players order, so every peer names the same leader.
      def frag_leader
        @players.min_by { |p| [-p.frags, p.id] }
      end

      def frag_limit_reached?
        return false unless @frag_limit

        @players.any? { |p| p.frags >= @frag_limit }
      end

      # The player who won, or nil while the match is still on.
      #
      # Note what this deliberately does not do: end run_tic. The frag limit is
      # local configuration and, unlike the mode and the seed, it does not
      # travel in the handshake, so a peer started with a different --frags
      # would stop simulating at a different tic and desync every other peer.
      # The world answers the question; the presentation layer says so on
      # screen.
      def match_winner
        frag_limit_reached? ? frag_leader : nil
      end

      def exit_triggered
        @sector_actions.exit_triggered
      end

      # Fingerprint of the whole simulation, for lockstep desync detection.
      def state_hash
        StateHash.of(self)
      end

      # Same fingerprint broken down by section, so a desync can say which part
      # of the world drifted rather than only that something did.
      def state_hash_sections
        StateHash.sections(self)
      end

      # Advance the whole simulation by one tic.
      #
      # `cmds` maps player id => Ticcmd; a player with no command coasts on a
      # neutral one rather than repeating its last input, which would make a
      # dropped packet look like a stuck key.
      def run_tic(cmds = {})
        @leveltime += 1

        @players.each(&:snapshot!)
        @sector_effects.update

        @players.each do |p|
          run_player_tic(p, cmds[p.id] || Ticcmd.none)
        end

        @combat.update
        @monster_ai.update(@players)

        @players.each { |p| post_tic_player(p) }

        update_sector_actions
        update_item_pickups
        @leveltime
      end

      private

      def rebuild_actor_subsystems
        @item_pickup = ItemPickup.new(@map, nil, @skill_hidden)
        @combat = Combat.new(@map, nil, @sprites, @skill_hidden, @sound, random: @random)
        @monster_ai = MonsterAI.new(@map, @combat, nil, @sprites, @skill_hidden, @sound, random: @random)
        @monster_ai.damage_multiplier = @damage_multiplier

        @players.each do |p|
          physics = physics_for(p)
          physics.item_pickup = @item_pickup
          physics.combat = @combat
        end
        @combat.players = @players
      end

      def primary
        @players.first
      end

      def run_player_tic(player, cmd)
        state = player.state
        physics = physics_for(player)

        # View bob feeds eye height, which feeds firing height and monster aim,
        # so it is simulation rather than decoration and runs on the tic clock.
        state.update_bob(TIC_SECONDS)
        state.update_view_bob(TIC_SECONDS)
        state.update_viewheight

        physics.run_tic(player, cmd)
        step_physics(player, physics)
        state.update_attack

        fire(player, cmd)
        use(player, cmd)
      end

      def step_physics(player, physics)
        return unless physics.floor_z
        physics.step(player.x, player.y)
        z = physics.eye_z
        player.z = z if z
      end

      def fire(player, cmd)
        return unless cmd.fire?

        state = player.state
        was_attacking = state.attacking
        state.start_attack
        return unless state.attacking && !was_attacking

        @combat.fire(player.x, player.y, player.z,
                     player.cos_angle, player.sin_angle, state.weapon, player)
        @sound&.weapon_fire(state.weapon)
      end

      # Use is edge-triggered per player, so holding the key cannot spam doors.
      def use(player, cmd)
        if cmd.use?
          unless player.use_held
            @sector_actions.update_player_position(player.x, player.y)
            try_use(player)
          end
          player.use_held = true
        else
          player.use_held = false
        end
      end

      # Cast forward for a usable linedef. Moved off the window because which
      # door a player opens is simulation, and with several players each needs
      # its own ray from its own position.
      def try_use(player)
        px = player.x
        py = player.y
        cos_angle = player.cos_angle
        sin_angle = player.sin_angle

        best_linedef = nil
        best_idx = nil
        best_dist = Float::INFINITY

        @map.linedefs.each_with_index do |linedef, idx|
          next if linedef.special == 0  # Skip non-special linedefs

          v1 = @map.vertices[linedef.v1]
          v2 = @map.vertices[linedef.v2]

          dist = point_to_line_distance(px, py, v1.x, v1.y, v2.x, v2.y)
          next if dist > USE_DISTANCE
          next if dist >= best_dist
          next unless facing_linedef?(px, py, cos_angle, sin_angle, v1, v2)

          best_linedef = linedef
          best_idx = idx
          best_dist = dist
        end

        @sector_actions.use_linedef(best_linedef, best_idx) if best_linedef
      end

      def point_to_line_distance(px, py, x1, y1, x2, y2)
        dx = px - x1
        dy = py - y1

        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = (line_dx * line_dx) + (line_dy * line_dy)

        return Math.sqrt((dx * dx) + (dy * dy)) if line_len_sq == 0

        # Project point onto line, clamped to segment
        t = (((dx * line_dx) + (dy * line_dy)) / line_len_sq).clamp(0.0, 1.0)
        closest_x = x1 + (t * line_dx)
        closest_y = y1 + (t * line_dy)

        Math.hypot(px - closest_x, py - closest_y)
      end

      def facing_linedef?(px, py, cos_angle, sin_angle, v1, v2)
        line_dx = v2.x - v1.x
        line_dy = v2.y - v1.y

        # Normal points to the right of the line direction
        normal_x = -line_dy
        normal_y = line_dx

        len = Math.sqrt((normal_x * normal_x) + (normal_y * normal_y))
        return false if len == 0

        normal_x /= len
        normal_y /= len

        # Flip the normal if the player is on the back side, so we always check
        # facing toward the line.
        side = ((px - v1.x) * normal_x) + ((py - v1.y) * normal_y)
        if side < 0
          normal_x = -normal_x
          normal_y = -normal_y
        end

        dot_facing = (cos_angle * -normal_x) + (sin_angle * -normal_y)
        dot_facing > 0.2  # ~78 degree cone, matching DOOM's generous use check
      end

      def post_tic_player(player)
        state = player.state
        health_before = @last_health ||= {}
        before = health_before[player.id] || state.health

        if state.health < before
          state.dead ? @sound&.player_death : @sound&.player_pain
        end
        health_before[player.id] = state.health

        state.update_damage_count
        state.death_tic += 1 if state.dead

        if !state.dead && (@leveltime % SECTOR_DAMAGE_INTERVAL).zero?
          apply_sector_damage(player)
        end
      end

      def apply_sector_damage(player)
        sector = @map.sector_at(player.x, player.y)
        return unless sector

        damage = SECTOR_DAMAGE[sector.special]
        return unless damage

        player.state.take_damage((damage * @damage_multiplier).to_i)
        @sound&.player_pain
      end

      def update_sector_actions
        @sector_actions.update_player_position(primary.x, primary.y) if primary
        @sector_actions.update

        return unless (dest = @sector_actions.pop_teleport)

        p = primary
        return unless p

        physics = physics_for(p)
        p.place(dest[:x], dest[:y], p.z, dest[:angle])
        physics.reset
        physics.settle(p, dest[:x], dest[:y])
      end

      def update_item_pickups
        return if @players.empty?

        picked_before = @item_pickup.picked_up.size
        @players.each { |p| @item_pickup.update(p) unless p.state.dead }
        return unless @sound && @item_pickup.picked_up.size > picked_before

        msg = @item_pickup.pickup_message
        # Weapon pickup messages end with '!' in DOOM's string table.
        msg&.include?('!') ? @sound.weapon_pickup : @sound.item_pickup
      end

      def hidden_things
        @skill_hidden.merge(@item_pickup.picked_up)
      end
      public :hidden_things
    end
  end
end
