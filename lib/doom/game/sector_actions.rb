# frozen_string_literal: true

require 'set'

module Doom
  module Game
    # Manages animated sector actions (doors, lifts, etc.)
    class SectorActions
      # Door states
      DOOR_CLOSED = 0
      DOOR_OPENING = 1
      DOOR_OPEN = 2
      DOOR_CLOSING = 3

      # Door speeds (units per tic, 35 tics/sec)
      DOOR_SPEED = 2
      DOOR_WAIT = 150  # Tics to wait when open (~4 seconds)
      PLAYER_HEIGHT = 56

      # Lift constants
      LIFT_SPEED = 4
      LIFT_WAIT = 105  # ~3 seconds

      attr_reader :exit_triggered, :secrets_found

      def pop_teleport
        dest = @teleport_dest
        @teleport_dest = nil
        dest
      end

      def initialize(map, sound_engine = nil)
        @map = map
        @sound = sound_engine
        @active_doors = {}   # sector_index => door_state
        @active_lifts = {}   # sector_index => lift_state
        @player_x = 0
        @player_y = 0
        @exit_triggered = nil
        @secrets_found = {}  # sector_index => true
        @crossed_linedefs = {}
      end

      def update_player_position(x, y)
        @player_x = x
        @player_y = y
      end

      def update
        update_doors
        update_lifts
        check_walk_triggers
        check_secrets
      end

      # Try to use a linedef (called when player presses use key)
      def use_linedef(linedef, linedef_idx)
        return false if linedef.special == 0

        case linedef.special
        # --- Doors ---
        when 1    # DR Door Open Wait Close
          activate_door(linedef)
        when 26   # DR Blue Door
          activate_door(linedef, key: :blue_card)
        when 27   # DR Yellow Door
          activate_door(linedef, key: :yellow_card)
        when 28   # DR Red Door
          activate_door(linedef, key: :red_card)
        when 31   # D1 Door Open Stay
          activate_door(linedef, stay_open: true)
        when 32   # D1 Blue Door Open Stay
          activate_door(linedef, key: :blue_card, stay_open: true)
        when 33   # D1 Red Door Open Stay
          activate_door(linedef, key: :red_card, stay_open: true)
        when 34   # D1 Yellow Door Open Stay
          activate_door(linedef, key: :yellow_card, stay_open: true)
        when 103  # S1 Door Open Wait Close (tagged)
          activate_tagged_door(linedef)

        # --- Lifts ---
        when 62   # SR Lift Lower Wait Raise (repeatable)
          activate_lift(linedef)

        # --- Floor changes ---
        when 18   # S1 Raise Floor to Next Higher
          raise_floor_to_next(linedef)
        when 20   # S1 Raise Floor to Next Higher (platform)
          raise_floor_to_next(linedef)
        when 22   # W1 Raise Floor to Next Higher
          raise_floor_to_next(linedef)
        when 23   # S1 Lower Floor to Lowest
          lower_floor_to_lowest(linedef)
        when 36   # S1 Lower Floor to Highest Adjacent - 8
          lower_floor_to_highest(linedef)
        when 70   # SR Lower Floor to Highest Adjacent - 8
          lower_floor_to_highest(linedef)

        # --- Exits ---
        when 11   # S1 Exit
          @exit_triggered = :normal
        when 51   # S1 Secret Exit
          @exit_triggered = :secret

        else
          return false
        end
        true
      end

      private

      # Walk-over trigger types:
      # W1 = once, WR = repeatable
      WALK_TRIGGERS = {
        2  => :door_open_stay,    # W1 Door Open Stay
        5  => :raise_floor,       # W1 Raise Floor to Lowest Ceiling
        7  => :stairs,            # S1 Build Stairs
        8  => :stairs,            # W1 Build Stairs
        52 => :exit,              # W1 Exit
        82 => :lower_floor,       # WR Lower Floor to Lowest
        86 => :door_open_stay,    # WR Door Open Stay
        88 => :lift,              # WR Lift Lower Wait Raise
        90 => :door,              # WR Door Open Wait Close
        91 => :raise_floor,       # WR Raise Floor to Lowest Ceiling
        97 => :teleport,          # WR Teleport
        98 => :lower_floor,       # WR Lower Floor to Highest - 8
        124 => :secret_exit,      # W1 Secret Exit
      }.freeze

      # W1 types that only trigger once
      W1_TYPES = [2, 5, 7, 8, 52, 124].freeze

      def check_walk_triggers
        @near_linedefs ||= {}

        @map.linedefs.each_with_index do |ld, idx|
          next if ld.special == 0
          action = WALK_TRIGGERS[ld.special]
          next unless action

          # W1 types only trigger once
          if W1_TYPES.include?(ld.special)
            next if @crossed_linedefs[idx]
          end

          v1 = @map.vertices[ld.v1]
          v2 = @map.vertices[ld.v2]

          # Determine which side of the linedef the player is on
          # DOOM's P_CrossSpecialLine fires when the player transitions sides
          side = line_side(@player_x, @player_y, v1.x, v1.y, v2.x, v2.y)
          dist = point_line_dist(@player_x, @player_y, v1.x, v1.y, v2.x, v2.y)

          near = dist < 48  # Use generous range for detection
          prev_side = @near_linedefs[idx]

          if near && prev_side && prev_side != side
            # Player crossed the line - trigger!
            @near_linedefs[idx] = side
          elsif near && prev_side.nil?
            # First time near - record side but don't trigger yet
            @near_linedefs[idx] = side
            next
          elsif !near
            @near_linedefs[idx] = nil
            next
          else
            next  # Same side, no crossing
          end

          @crossed_linedefs[idx] = true

          case action
          when :exit
            @exit_triggered = :normal
          when :secret_exit
            @exit_triggered = :secret
          when :door_open_stay
            activate_tagged_door(ld, stay_open: true)
          when :door
            activate_tagged_door(ld)
          when :lift
            activate_lift(ld)
          when :raise_floor
            raise_floor_to_next(ld)
          when :lower_floor
            lower_floor_to_highest(ld)
          when :teleport
            teleport_player(ld)
          end
        end
      end

      # Returns which side of a line a point is on (:front or :back)
      def line_side(px, py, x1, y1, x2, y2)
        cross = (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
        cross >= 0 ? :front : :back
      end

      def point_line_dist(px, py, x1, y1, x2, y2)
        dx = x2 - x1; dy = y2 - y1
        len_sq = dx * dx + dy * dy
        return Math.sqrt((px - x1) ** 2 + (py - y1) ** 2) if len_sq == 0
        t = ((px - x1) * dx + (py - y1) * dy).to_f / len_sq
        t = [[t, 0.0].max, 1.0].min
        cx = x1 + t * dx; cy = y1 + t * dy
        Math.sqrt((px - cx) ** 2 + (py - cy) ** 2)
      end

      def activate_door(linedef, stay_open: false, key: nil)
        # Find the sector on the back side of the linedef
        return unless linedef.two_sided?

        back_sidedef_idx = linedef.sidedef_left
        return if back_sidedef_idx == 0xFFFF || back_sidedef_idx < 0

        back_sidedef = @map.sidedefs[back_sidedef_idx]
        sector_idx = back_sidedef.sector
        sector = @map.sectors[sector_idx]
        return unless sector

        # Check if door is already active
        if @active_doors[sector_idx]
          door = @active_doors[sector_idx]
          # If closing, reverse direction
          if door[:state] == DOOR_CLOSING
            door[:state] = DOOR_OPENING
          end
          return
        end

        # Calculate target height (find lowest adjacent ceiling)
        target_height = find_lowest_ceiling_around(sector_idx) - 4

        # Start the door
        @active_doors[sector_idx] = {
          sector: sector,
          state: DOOR_OPENING,
          target_height: target_height,
          original_height: sector.ceiling_height,
          wait_tics: 0,
          stay_open: stay_open
        }
        @sound&.door_open
      end

      def update_doors
        @active_doors.each do |sector_idx, door|
          case door[:state]
          when DOOR_OPENING
            door[:sector].ceiling_height += DOOR_SPEED
            if door[:sector].ceiling_height >= door[:target_height]
              door[:sector].ceiling_height = door[:target_height]
              if door[:stay_open]
                @active_doors.delete(sector_idx)
              else
                door[:state] = DOOR_OPEN
                door[:wait_tics] = DOOR_WAIT
              end
            end

          when DOOR_OPEN
            door[:wait_tics] -= 1
            if door[:wait_tics] <= 0
              door[:state] = DOOR_CLOSING
              @sound&.door_close
            end

          when DOOR_CLOSING
            # Check if player is in the door sector
            player_sector = @map.sector_at(@player_x, @player_y)
            if player_sector == door[:sector]
              # Player is in door - reopen it
              door[:state] = DOOR_OPENING
              next
            end

            door[:sector].ceiling_height -= DOOR_SPEED
            if door[:sector].ceiling_height <= door[:original_height]
              door[:sector].ceiling_height = door[:original_height]
              @active_doors.delete(sector_idx)
            end
          end
        end
      end

      def find_lowest_ceiling_around(sector_idx)
        lowest = Float::INFINITY

        @map.linedefs.each do |linedef|
          next unless linedef.two_sided?

          # Check if this linedef touches our sector
          right_sidedef = @map.sidedefs[linedef.sidedef_right]
          left_sidedef = @map.sidedefs[linedef.sidedef_left] if linedef.sidedef_left != 0xFFFF

          adjacent_sector = nil
          if right_sidedef&.sector == sector_idx && left_sidedef
            adjacent_sector = @map.sectors[left_sidedef.sector]
          elsif left_sidedef&.sector == sector_idx
            adjacent_sector = @map.sectors[right_sidedef.sector]
          end

          if adjacent_sector
            lowest = [lowest, adjacent_sector.ceiling_height].min
          end
        end

        lowest == Float::INFINITY ? 128 : lowest
      end

      # Door activated by tag (for S1/W1/WR tagged doors)
      def activate_tagged_door(linedef, stay_open: false)
        tag = linedef.tag
        return if tag == 0

        @map.sectors.each_with_index do |sector, idx|
          next unless sector_has_tag?(idx, tag)
          next if @active_doors[idx]

          target = find_lowest_ceiling_around(idx) - 4
          @active_doors[idx] = {
            sector: sector,
            state: DOOR_OPENING,
            target_height: target,
            original_height: sector.ceiling_height,
            wait_tics: 0,
            stay_open: stay_open,
          }
        end
        @sound&.door_open
      end

      # Lift: lower floor to lowest adjacent, wait, raise back
      def activate_lift(linedef)
        tag = linedef.tag
        return if tag == 0

        @map.sectors.each_with_index do |sector, idx|
          next unless sector_has_tag?(idx, tag)
          next if @active_lifts[idx]

          lowest = find_lowest_floor_around(idx)
          @active_lifts[idx] = {
            sector: sector,
            state: :lowering,
            target_low: lowest,
            original_height: sector.floor_height,
            wait_tics: 0,
          }
        end
        @sound&.platform_start
      end

      def update_lifts
        @active_lifts.each do |idx, lift|
          case lift[:state]
          when :lowering
            lift[:sector].floor_height -= LIFT_SPEED
            if lift[:sector].floor_height <= lift[:target_low]
              lift[:sector].floor_height = lift[:target_low]
              lift[:state] = :waiting
              lift[:wait_tics] = LIFT_WAIT
              @sound&.platform_stop
            end
          when :waiting
            lift[:wait_tics] -= 1
            if lift[:wait_tics] <= 0
              lift[:state] = :raising
              @sound&.platform_start
            end
          when :raising
            lift[:sector].floor_height += LIFT_SPEED
            if lift[:sector].floor_height >= lift[:original_height]
              lift[:sector].floor_height = lift[:original_height]
              @active_lifts.delete(idx)
              @sound&.platform_stop
            end
          end
        end
      end

      def raise_floor_to_next(linedef)
        tag = linedef.tag
        return if tag == 0

        @map.sectors.each_with_index do |sector, idx|
          next unless sector_has_tag?(idx, tag)
          target = find_next_higher_floor(idx)
          next if target <= sector.floor_height

          @active_lifts[idx] = {
            sector: sector,
            state: :raising,
            target_low: sector.floor_height,
            original_height: target,
            wait_tics: 0,
          }
        end
      end

      def lower_floor_to_lowest(linedef)
        tag = linedef.tag
        return if tag == 0

        @map.sectors.each_with_index do |sector, idx|
          next unless sector_has_tag?(idx, tag)
          target = find_lowest_floor_around(idx)
          sector.floor_height = target
        end
      end

      def lower_floor_to_highest(linedef)
        tag = linedef.tag
        return if tag == 0

        @map.sectors.each_with_index do |sector, idx|
          next unless sector_has_tag?(idx, tag)
          target = find_highest_floor_around(idx) - 8
          sector.floor_height = target if target < sector.floor_height
        end
      end

      def teleport_player(linedef)
        tag = linedef.tag
        return if tag == 0

        # Find teleport destination thing (type 14) in tagged sector
        @map.things.each do |thing|
          next unless thing.type == 14  # Teleport destination
          sector = @map.sector_at(thing.x, thing.y)
          next unless sector
          sector_idx = @map.sectors.index(sector)
          next unless sector_has_tag?(sector_idx, tag)

          @teleport_dest = { x: thing.x, y: thing.y, angle: thing.angle }
          return
        end
      end


      def check_secrets
        # Build set of secret sector indices on first call
        @secret_sectors ||= Set.new(
          @map.sectors.each_with_index.filter_map { |s, i| i if s.special == 9 }
        )
        return if @secret_sectors.empty?

        # Find which sector the player is in via BSP subsector lookup
        subsector = @map.subsector_at(@player_x, @player_y)
        return unless subsector

        seg = @map.segs[subsector.first_seg]
        return unless seg

        ld = @map.linedefs[seg.linedef]
        return unless ld

        sd_idx = seg.direction == 0 ? ld.sidedef_right : ld.sidedef_left
        return if sd_idx == 0xFFFF

        sector_idx = @map.sidedefs[sd_idx].sector
        return if @secrets_found[sector_idx]

        if @secret_sectors.include?(sector_idx)
          @secrets_found[sector_idx] = true
          # Clear the special so it doesn't retrigger (matching Chocolate Doom)
          @map.sectors[sector_idx].special = 0
          @secret_sectors.delete(sector_idx)
        end
      end

      def sector_has_tag?(sector_idx, tag)
        @map.sectors[sector_idx].tag == tag
      end

      def find_lowest_floor_around(sector_idx)
        lowest = @map.sectors[sector_idx].floor_height
        each_adjacent_sector(sector_idx) do |adj|
          lowest = adj.floor_height if adj.floor_height < lowest
        end
        lowest
      end

      def find_highest_floor_around(sector_idx)
        highest = -32768
        each_adjacent_sector(sector_idx) do |adj|
          highest = adj.floor_height if adj.floor_height > highest
        end
        highest == -32768 ? @map.sectors[sector_idx].floor_height : highest
      end

      def find_next_higher_floor(sector_idx)
        current = @map.sectors[sector_idx].floor_height
        best = Float::INFINITY
        each_adjacent_sector(sector_idx) do |adj|
          if adj.floor_height > current && adj.floor_height < best
            best = adj.floor_height
          end
        end
        best == Float::INFINITY ? current : best
      end

      def each_adjacent_sector(sector_idx)
        @map.linedefs.each do |ld|
          next unless ld.two_sided?
          right = @map.sidedefs[ld.sidedef_right]
          left = @map.sidedefs[ld.sidedef_left] if ld.sidedef_left != 0xFFFF
          next unless left

          if right.sector == sector_idx
            yield @map.sectors[left.sector]
          elsif left.sector == sector_idx
            yield @map.sectors[right.sector]
          end
        end
      end
    end
  end
end
