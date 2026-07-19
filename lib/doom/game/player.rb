# frozen_string_literal: true

module Doom
  module Game
    # A player as a first-class entity.
    #
    # Before this existed the "player" was scattered across three objects:
    # position and angle lived in Renderer, horizontal momentum lived in
    # GosuWindow, and floor height lived in PlayerPhysics -- which made more
    # than one of them impossible. Everything that identifies a player now
    # lives here; Renderer is reduced to a camera that gets pointed at a pose.
    #
    # Angles are radians internally (Renderer's old setters took degrees).
    class Player
      attr_accessor :id, :x, :y, :z, :angle
      attr_accessor :momx, :momy
      attr_reader :state
      attr_reader :sin_angle, :cos_angle

      # Previous tic's pose, kept so the renderer can interpolate between tics
      # and stay smooth above 35 FPS.
      attr_reader :prev_x, :prev_y, :prev_z, :prev_angle

      def initialize(id: 0, state: PlayerState.new)
        @id = id
        @state = state
        @x = 0.0
        @y = 0.0
        @z = 41.0     # eye height
        @momx = 0.0
        @momy = 0.0
        self.angle = 0.0
        snapshot!
      end

      # Keeps the sin/cos cache in step with the angle -- every read path
      # (thrust direction, firing direction, view transform) depends on it.
      def angle=(radians)
        @angle = radians
        @sin_angle = Math.sin(radians)
        @cos_angle = Math.cos(radians)
      end

      def angle_degrees=(degrees)
        self.angle = degrees * Math::PI / 180.0
      end

      def turn(degrees)
        self.angle = @angle + (degrees * Math::PI / 180.0)
      end

      def move_to(x, y)
        @x = x.to_f
        @y = y.to_f
      end

      # Place the player outright (spawn, teleport, respawn) and collapse the
      # interpolation history so the camera doesn't sweep across the map.
      def place(x, y, z, angle_degrees)
        @x = x.to_f
        @y = y.to_f
        @z = z.to_f
        self.angle_degrees = angle_degrees
        @momx = 0.0
        @momy = 0.0
        snapshot!
      end

      # Called at the start of each tic, before the simulation moves the player.
      def snapshot!
        @prev_x = @x
        @prev_y = @y
        @prev_z = @z
        @prev_angle = @angle
      end

      # Pose to render at, `alpha` of the way from the previous tic to this one.
      # Angle is interpolated along the shortest arc so wrapping past +/-PI
      # doesn't spin the view the long way round.
      def view_pose(alpha)
        a = alpha.clamp(0.0, 1.0)
        delta = @angle - @prev_angle
        delta -= 2 * Math::PI while delta > Math::PI
        delta += 2 * Math::PI while delta < -Math::PI

        [
          @prev_x + ((@x - @prev_x) * a),
          @prev_y + ((@y - @prev_y) * a),
          @prev_z + ((@z - @prev_z) * a),
          @prev_angle + (delta * a),
        ]
      end

      def dead?
        @state.dead
      end
    end
  end
end
