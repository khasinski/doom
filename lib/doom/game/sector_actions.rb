# frozen_string_literal: true

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
      PLAYER_HEIGHT = 56  # Player height for door collision

      attr_reader :exit_triggered

      def initialize(map, sound_engine = nil)
        @map = map
        @sound = sound_engine
        @active_doors = {}  # sector_index => door_state
        @player_x = 0
        @player_y = 0
        @exit_triggered = nil
        @crossed_linedefs = {}
      end

      def update_player_position(x, y)
        @player_x = x
        @player_y = y
      end

      def update
        update_doors
        check_walk_triggers
      end

      # Try to use a linedef (called when player presses use key)
      def use_linedef(linedef, linedef_idx)
        return false if linedef.special == 0

        case linedef.special
        when 1  # DR Door Open Wait Close
          activate_door(linedef)
          true
        when 31  # D1 Door Open Stay
          activate_door(linedef, stay_open: true)
          true
        when 26  # DR Blue Door
          activate_door(linedef, key: :blue_card)
          true
        when 27  # DR Yellow Door
          activate_door(linedef, key: :yellow_card)
          true
        when 28  # DR Red Door
          activate_door(linedef, key: :red_card)
          true
        when 11  # S1 Exit
          @exit_triggered = :normal
          true
        when 51  # S1 Secret Exit
          @exit_triggered = :secret
          true
        else
          false
        end
      end

      private

      def check_walk_triggers
        @map.linedefs.each_with_index do |ld, idx|
          next if @crossed_linedefs[idx]
          next unless [52, 124].include?(ld.special)  # W1 Exit, W1 Secret Exit

          v1 = @map.vertices[ld.v1]
          v2 = @map.vertices[ld.v2]
          # Check if player is near this linedef
          dist = point_line_dist(@player_x, @player_y, v1.x, v1.y, v2.x, v2.y)
          if dist < 24
            @crossed_linedefs[idx] = true
            @exit_triggered = ld.special == 124 ? :secret : :normal
          end
        end
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
    end
  end
end
