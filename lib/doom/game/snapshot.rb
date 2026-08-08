# frozen_string_literal: true

module Doom
  module Game
    # A complete, restorable copy of a World, as bytes.
    #
    # This is deliberately not the same thing as StateHash. The hash is a
    # fingerprint: enough to notice two worlds have diverged. A snapshot has to
    # do the harder thing -- carry enough that a fresh world restored from it
    # goes on to simulate byte-for-byte identically. So it captures state the
    # hash skips because it does not change the current tic's picture: monster
    # attack timers, sector-effect countdowns, the full projectile list, door
    # and lift animations in progress.
    #
    # Why it exists: a player joining a running match cannot replay the round
    # from the start -- at 30 players that is nearly a minute of catch-up and
    # it grows with the match. Handed a snapshot, they resume in one step.
    #
    # This module reaches directly into subsystem internals. That coupling is
    # intentional and concentrated here, in one place, so the wire format lives
    # in one file rather than smeared across eight. The round-trip spec is what
    # keeps it honest: it restores a snapshot and runs both worlds forward,
    # failing the moment a field was missed.
    module Snapshot
      VERSION = 1

      # A cursor-based binary writer, so record offsets are never hand-managed.
      class Writer
        def initialize
          @buf = +''.b
        end

        def u8(v)  = append([v & 0xff].pack('C'))
        def u16(v) = append([v & 0xffff].pack('S<'))
        def u32(v) = append([v & 0xffffffff].pack('L<'))
        def i64(v) = append([v].pack('q<'))
        def f64(v) = append([v].pack('E'))
        def bool(v) = u8(v ? 1 : 0)

        def str(s)
          bytes = s.to_s.b
          u16(bytes.bytesize)
          append(bytes)
        end

        # length-prefixed homogeneous array
        def list(items)
          u32(items.size)
          items.each { |it| yield it }
        end

        def to_s = @buf.dup

        private

        def append(bytes)
          @buf << bytes
          self
        end
      end

      class Reader
        def initialize(bytes)
          @buf = bytes.b
          @pos = 0
        end

        def u8  = take(1).unpack1('C')
        def u16 = take(2).unpack1('S<')
        def u32 = take(4).unpack1('L<')
        def i64 = take(8).unpack1('q<')
        def f64 = take(8).unpack1('E')
        def bool = u8 == 1

        def str
          take(u16)
        end

        def list
          Array.new(u32) { yield }
        end

        private

        def take(n)
          raise 'snapshot truncated' if @pos + n > @buf.bytesize

          slice = @buf.byteslice(@pos, n)
          @pos += n
          slice
        end
      end

      NO_ID = 0xff       # sentinel for "no player" (target/owner)
      PROJ_TARGETS = { monsters: 0, player: 1 }.freeze
      PROJ_TARGET_NAMES = PROJ_TARGETS.invert.freeze

      module_function

      # Serialize a whole world to bytes.
      def dump(world)
        w = Writer.new
        w.u8(VERSION)
        dump_header(w, world)
        dump_map_state(w, world.map)
        dump_players(w, world)
        dump_combat(w, world.combat)
        dump_monsters(w, world.monster_ai)
        dump_item_pickup(w, world.item_pickup)
        dump_sector_effects(w, world.sector_effects)
        dump_sector_actions(w, world.sector_actions, world.map)
        w.to_s
      end

      # Rebuild a world from bytes. The caller supplies the environment the
      # joiner already has -- a freshly loaded map for the same level, the
      # sprite set, and a sound engine (or nil headless). Everything that
      # varies during play comes out of the bytes.
      def load(bytes, map:, sprites:, sound: nil)
        r = Reader.new(bytes)
        version = r.u8
        raise "unknown snapshot version #{version}" unless version == VERSION

        header = load_header(r)
        world = World.new(map, sprites: sprites, sound: sound,
                               random: Random.new(0), mode: header[:mode],
                               frag_limit: header[:frag_limit])
        world.instance_variable_set(:@leveltime, header[:leveltime])
        world.instance_variable_set(:@damage_multiplier, header[:damage_multiplier])
        # World.rebuild_actor_subsystems mirrors the skill's damage factor onto
        # the monster AI; a fresh world built here for a load skips that path, so
        # set it explicitly or restored monsters would deal 1.0x damage.
        world.monster_ai.damage_multiplier = header[:damage_multiplier]
        world.random.index = header[:random_index]

        load_map_state(r, map)
        load_players(r, world, map)
        load_combat(r, world.combat, header[:combat_tic])
        relink_projectile_owners(world)
        load_monsters(r, world, header[:monster_tic], header[:aggression])
        load_item_pickup(r, world.item_pickup)
        load_sector_effects(r, world.sector_effects)
        load_sector_actions(r, world.sector_actions, map)
        world
      end

      # --- header -------------------------------------------------------------

      def dump_header(w, world)
        w.u32(world.leveltime)
        w.u8(World::MODES.index(world.mode))
        w.u32(world.frag_limit || 0)
        w.f64(world.damage_multiplier)
        w.u8(world.random.index)
        w.u32(world.combat.instance_variable_get(:@tic))
        w.u32(world.monster_ai.instance_variable_get(:@tic_counter))
        w.bool(world.monster_ai.aggression)
      end

      def load_header(r)
        {
          leveltime: r.u32,
          mode: World::MODES[r.u8],
          frag_limit: (fl = r.u32).zero? ? nil : fl,
          damage_multiplier: r.f64,
          random_index: r.u8,
          combat_tic: r.u32,
          monster_tic: r.u32,
          aggression: r.bool,
        }
      end

      # --- map: the parts doors, lifts and light effects mutate ---------------

      def dump_map_state(w, map)
        w.list(map.sectors) do |sec|
          w.i64(sec.light_level)
          w.i64(sec.floor_height)
          w.i64(sec.ceiling_height)
        end
      end

      def load_map_state(r, map)
        count = r.u32
        count.times do |i|
          light = r.i64; floor = r.i64; ceil = r.i64
          sec = map.sectors[i]
          next unless sec

          sec.light_level = light
          sec.floor_height = floor
          sec.ceiling_height = ceil
        end
      end

      # --- players ------------------------------------------------------------

      def dump_players(w, world)
        w.list(world.players) do |p|
          w.u8(p.id)
          w.i64(p.frags)
          w.bool(p.use_held)
          w.f64(p.x); w.f64(p.y); w.f64(p.z); w.f64(p.angle)
          w.f64(p.momx); w.f64(p.momy)

          phys = world.physics_for(p)
          w.f64(phys.floor_z || 0.0)
          w.bool(!phys.floor_z.nil?)
          w.f64(phys.momz)

          dump_player_state(w, p.state)
        end
      end

      def load_players(r, world, map)
        count = r.u32
        count.times do
          id = r.u8
          player = world.add_player(map.player_start_for(id) || map.player_start, id: id)
          player.frags = r.i64
          player.use_held = r.bool
          player.x = r.f64; player.y = r.f64; player.z = r.f64
          player.angle = r.f64
          player.momx = r.f64; player.momy = r.f64
          player.snapshot!  # collapse interpolation onto the restored pose

          phys = world.physics_for(player)
          floor_z = r.f64
          has_floor = r.bool
          phys.instance_variable_set(:@floor_z, has_floor ? floor_z : nil)
          phys.instance_variable_set(:@momz, r.f64)

          load_player_state(r, player.state)
        end
      end

      PLAYER_STATE_INTS = %i[
        health armor max_health max_armor
        ammo_bullets ammo_shells ammo_rockets ammo_cells
        max_bullets max_shells max_rockets max_cells
        weapon attack_frame attack_tics death_tic damage_count
      ].freeze

      PLAYER_STATE_BOOLS = %i[attacking dead god_mode infinite_ammo is_moving].freeze

      PLAYER_STATE_FLOATS = %i[
        bob_angle bob_amount viewheight deltaviewheight view_bob_offset
        momx momy thrust_x thrust_y view_bob_angle
      ].freeze

      def dump_player_state(w, s)
        PLAYER_STATE_INTS.each { |f| w.i64(s.instance_variable_get(:"@#{f}")) }
        PLAYER_STATE_BOOLS.each { |f| w.bool(s.instance_variable_get(:"@#{f}")) }
        PLAYER_STATE_FLOATS.each { |f| w.f64(s.instance_variable_get(:"@#{f}")) }

        weapons = s.has_weapons
        w.u16(weapons.each_index.sum { |i| weapons[i] ? (1 << i) : 0 })

        keys = s.keys
        w.list(keys.keys) do |k|
          w.str(k.to_s)
          w.bool(keys[k])
        end
      end

      def load_player_state(r, s)
        PLAYER_STATE_INTS.each { |f| s.instance_variable_set(:"@#{f}", r.i64) }
        PLAYER_STATE_BOOLS.each { |f| s.instance_variable_set(:"@#{f}", r.bool) }
        PLAYER_STATE_FLOATS.each { |f| s.instance_variable_set(:"@#{f}", r.f64) }

        mask = r.u16
        weapons = s.has_weapons
        weapons.each_index { |i| weapons[i] = mask[i] == 1 }

        keys = {}
        r.list { name = r.str; keys[name.to_sym] = r.bool }
        s.keys.replace(keys)
      end

      # --- combat -------------------------------------------------------------

      def dump_combat(w, combat)
        w.list(combat.instance_variable_get(:@monster_hp).to_a) do |idx, hp|
          w.u32(idx); w.i64(hp)
        end
        w.list(combat.dead_things.to_a) do |idx, info|
          w.u32(idx); w.u32(info[:tic]); w.str(info[:prefix].to_s)
        end
        w.list(combat.instance_variable_get(:@pain_until).to_a) do |idx, tic|
          w.u32(idx); w.u32(tic)
        end
        w.list(combat.projectiles) { |p| dump_projectile(w, p) }
      end

      def load_combat(r, combat, tic)
        combat.instance_variable_set(:@tic, tic)

        hp = {}
        r.list { idx = r.u32; hp[idx] = r.i64 }
        combat.instance_variable_set(:@monster_hp, hp)

        dead = {}
        r.list { idx = r.u32; dead[idx] = { tic: r.u32, prefix: r.str } }
        combat.instance_variable_set(:@dead_things, dead)

        pain = {}
        r.list { idx = r.u32; pain[idx] = r.u32 }
        combat.instance_variable_set(:@pain_until, pain)

        projectiles = r.list { load_projectile(r) }
        combat.instance_variable_set(:@projectiles, projectiles)
      end

      def dump_projectile(w, p)
        w.f64(p.x); w.f64(p.y); w.f64(p.z)
        w.f64(p.dx); w.f64(p.dy); w.f64(p.dz || 0.0)
        w.str(p.type.to_s)
        w.u32(p.spawn_tic)
        w.str(p.sprite_prefix.to_s)
        w.u8(PROJ_TARGETS.fetch(p.target, 0))
        w.u8(p.owner&.id || NO_ID)
        w.f64(p.damage_multiplier || 1.0)
      end

      def load_projectile(r)
        Combat::Projectile.new(
          r.f64, r.f64, r.f64, r.f64, r.f64, r.f64,
          r.str.to_sym, r.u32, r.str, PROJ_TARGET_NAMES.fetch(r.u8, :monsters),
          r.u8, # owner id; re-linked to a Player by relink_projectile_owners
          r.f64 # damage_multiplier
        )
      end

      # Projectiles carry their owner as an id on the wire; swap it for the
      # Player object once players exist, or nil for an owner who has left.
      def relink_projectile_owners(world)
        by_id = world.players.to_h { |p| [p.id, p] }
        world.combat.projectiles.each do |proj|
          proj.owner = proj.owner == NO_ID ? nil : by_id[proj.owner]
        end
      end

      # --- monsters -----------------------------------------------------------

      MONSTER_INT_FIELDS = %i[thing_idx movedir movecount chase_timer type
                              attack_cooldown reactiontime last_saw_player attack_frame_tic].freeze
      MONSTER_BOOL_FIELDS = %i[active attacking fired].freeze

      def dump_monsters(w, ai)
        things = ai.instance_variable_get(:@map).things
        w.list(ai.monsters) do |m|
          MONSTER_INT_FIELDS.each { |f| w.i64(m[f]) }
          MONSTER_BOOL_FIELDS.each { |f| w.bool(m[f]) }
          w.f64(m.x); w.f64(m.y)
          w.u8(m.target&.id || NO_ID)

          # The map thing carries an integer-truncated copy of the monster's
          # position, synced only when the monster moves (monster_ai.rb writes
          # thing.x = mon.x.to_i). Hitscan traces against THIS, not against
          # mon.x/mon.y, so it must be restored explicitly: a stale thing
          # position makes bullets hit where the monster no longer is. It also
          # lags mon.x.to_i for a monster that has paused, so it is stored
          # directly rather than recomputed. This was the field whose absence
          # broke the round-trip test once a lift was in play.
          thing = things[m.thing_idx]
          w.i64(thing.x); w.i64(thing.y)
        end
      end

      def load_monsters(r, world, tic, aggression)
        ai = world.monster_ai
        ai.instance_variable_set(:@tic_counter, tic)
        ai.aggression = aggression
        by_id = world.players.to_h { |p| [p.id, p] }

        saved = r.list do
          fields = {}
          MONSTER_INT_FIELDS.each { |f| fields[f] = r.i64 }
          MONSTER_BOOL_FIELDS.each { |f| fields[f] = r.bool }
          fields[:x] = r.f64; fields[:y] = r.f64
          fields[:target_id] = r.u8
          fields[:thing_x] = r.i64; fields[:thing_y] = r.i64
          fields
        end

        # The monster list is rebuilt from the map in a fixed order by the
        # constructor, so match saved records to live monsters by thing index
        # rather than trusting position.
        things = world.map.things
        live = ai.monster_by_thing_idx
        saved.each do |f|
          mon = live[f[:thing_idx]]
          next unless mon

          MONSTER_INT_FIELDS.each { |k| mon[k] = f[k] }
          MONSTER_BOOL_FIELDS.each { |k| mon[k] = f[k] }
          mon.x = f[:x]; mon.y = f[:y]
          mon.target = f[:target_id] == NO_ID ? nil : by_id[f[:target_id]]

          thing = things[f[:thing_idx]]
          thing.x = f[:thing_x]
          thing.y = f[:thing_y]
        end
      end

      # --- item pickup --------------------------------------------------------

      def dump_item_pickup(w, ip)
        w.u32(ip.ammo_multiplier)
        w.list(ip.picked_up.keys) { |idx| w.u32(idx) }
      end

      def load_item_pickup(r, ip)
        ip.ammo_multiplier = r.u32
        picked = {}
        r.list { picked[r.u32] = true }
        ip.picked_up.replace(picked)
      end

      # --- sector effects: rebuilt in map order, full state restored ----------
      #
      # The effect list rebuilds in a fixed order from the map, so records line
      # up by index. But NOT only the countdown gets restored: a rebuilt effect
      # reads its max and min light from the sector's CURRENT level, and at a
      # snapshot mid-fade that level has already moved, so reconstruction alone
      # gives a wrong max/min and the light drifts a few tics later. Every
      # effect field is carried instead.
      EFFECT_FIELDS = %i[@maxlight @minlight @count @direction @darktime @brighttime].freeze

      def dump_sector_effects(w, effects)
        list = effects.instance_variable_get(:@effects)
        w.list(list) do |e|
          EFFECT_FIELDS.each { |iv| w.i64(e.instance_variable_defined?(iv) ? e.instance_variable_get(iv) : 0) }
        end
        scrolls = effects.instance_variable_get(:@scroll_sides)
        w.list(scrolls) { |side| w.i64(side.x_offset) }
      end

      def load_sector_effects(r, effects)
        list = effects.instance_variable_get(:@effects)
        records = r.list { EFFECT_FIELDS.map { r.i64 } }
        records.each_with_index do |values, i|
          e = list[i]
          next unless e

          EFFECT_FIELDS.each_with_index do |iv, j|
            e.instance_variable_set(iv, values[j]) if e.instance_variable_defined?(iv)
          end
        end

        scrolls = effects.instance_variable_get(:@scroll_sides)
        offsets = r.list { r.i64 }
        offsets.each_with_index { |off, i| scrolls[i]&.x_offset = off }
      end

      # --- sector actions: doors, lifts and trigger-once bookkeeping ----------

      def dump_sector_actions(w, actions, map)
        w.list(actions.instance_variable_get(:@active_doors).to_a) do |idx, d|
          w.u32(idx)
          w.i64(d[:state]) # DOOR_OPENING/OPEN/CLOSING are integers, not symbols
          w.i64(d[:target_height]); w.i64(d[:original_height])
          w.u32(d[:wait_tics]); w.bool(d[:stay_open])
        end
        w.list(actions.instance_variable_get(:@active_lifts).to_a) do |idx, l|
          w.u32(idx)
          w.str(l[:state].to_s)
          w.i64(l[:target_low]); w.i64(l[:original_height])
          w.u32(l[:wait_tics])
        end
        w.list(actions.instance_variable_get(:@crossed_linedefs).keys) { |idx| w.u32(idx) }
        w.list(actions.instance_variable_get(:@secrets_found).keys) { |idx| w.u32(idx) }

        # Which side of each nearby line the player was last on. Walk triggers
        # fire on a side change, so without this a restored world detects a
        # crossing that never happened (or misses one), which silently
        # activates a different set of lines and diverges tics later. This was
        # the field that broke the round-trip test.
        # A nil side means "not yet seen", which is the same as the key being
        # absent, so those entries are dropped rather than encoded.
        near = (actions.instance_variable_get(:@near_linedefs) || {}).reject { |_, side| side.nil? }
        w.list(near.to_a) { |idx, side| w.u32(idx); w.i64(side) }

        w.bool(!actions.exit_triggered.nil?)
        w.str(actions.exit_triggered.to_s)
      end

      def load_sector_actions(r, actions, map)
        doors = {}
        r.list do
          idx = r.u32
          doors[idx] = {
            sector: map.sectors[idx], state: r.i64,
            target_height: r.i64, original_height: r.i64,
            wait_tics: r.u32, stay_open: r.bool
          }
        end
        actions.instance_variable_set(:@active_doors, doors)

        lifts = {}
        r.list do
          idx = r.u32
          lifts[idx] = {
            sector: map.sectors[idx], state: r.str.to_sym,
            target_low: r.i64, original_height: r.i64, wait_tics: r.u32
          }
        end
        actions.instance_variable_set(:@active_lifts, lifts)

        crossed = {}
        r.list { crossed[r.u32] = true }
        actions.instance_variable_set(:@crossed_linedefs, crossed)

        secrets = {}
        r.list { secrets[r.u32] = true }
        actions.instance_variable_set(:@secrets_found, secrets)

        near = {}
        r.list { idx = r.u32; near[idx] = r.i64 }
        actions.instance_variable_set(:@near_linedefs, near)

        has_exit = r.bool
        exit_val = r.str
        actions.instance_variable_set(:@exit_triggered, has_exit ? exit_val.to_sym : nil)
      end
    end
  end
end
