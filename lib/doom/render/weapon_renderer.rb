# frozen_string_literal: true

module Doom
  module Render
    # Renders the first-person weapon view
    class WeaponRenderer
      # Weapon is rendered above the status bar
      WEAPON_AREA_HEIGHT = SCREEN_HEIGHT - StatusBar::STATUS_BAR_HEIGHT

      # DOOM positions weapon sprites using their built-in offsets:
      #   x = SCREENWIDTH/2 - sprite.left_offset
      #   y = WEAPONTOP + SCREENHEIGHT - 200 - sprite.top_offset
      # WEAPONTOP = 32 in fixed-point = 32 pixels above the default position
      # We scale for our 240px screen vs DOOM's 200px.
      WEAPONTOP = 32
      SCREEN_Y_OFFSET = SCREEN_HEIGHT - 200  # 40px offset for 240px screen

      def initialize(hud_graphics, player_state)
        @gfx = hud_graphics
        @player = player_state
      end

      def render(framebuffer)
        weapon_name = @player.weapon_name
        weapon_data = @gfx.weapons[weapon_name]
        return unless weapon_data

        # Get the appropriate frame
        sprite = if @player.attacking && weapon_data[:fire]&.any?
                   frame = @player.attack_frame.clamp(0, weapon_data[:fire].length - 1)
                   weapon_data[:fire][frame]
                 else
                   weapon_data[:idle]
                 end

        return unless sprite

        # Bob offset (frozen during attack to keep weapon steady)
        bob_x = @player.attacking ? 0 : @player.weapon_bob_x.to_i
        bob_y = @player.attacking ? 0 : @player.weapon_bob_y.to_i

        # Chocolate Doom R_DrawPSprite positioning:
        # centery(120) - (WEAPONTOP(32) - topoffset) for y
        # centery is HALF_HEIGHT for our 240px screen (view area 208px, center 104)
        # But psprite centery uses full screen center = 120
        x = 1 - sprite.left_offset + bob_x
        y = 120 - (WEAPONTOP - sprite.top_offset) + bob_y

        draw_weapon_sprite(framebuffer, sprite, x, y)

        # Draw muzzle flash only on the first fire frame (the actual shot)
        if @player.attacking && @player.attack_frame == 0
          draw_muzzle_flash(framebuffer, weapon_name)
        end
      end

      private

      def draw_weapon_sprite(framebuffer, sprite, base_x, base_y)
        return unless sprite

        # Clip to screen bounds (don't draw over status bar)
        max_y = WEAPON_AREA_HEIGHT - 1

        sprite.width.times do |sx|
          column = sprite.column_pixels(sx)
          next unless column

          draw_x = base_x + sx
          next if draw_x < 0 || draw_x >= SCREEN_WIDTH

          column.each_with_index do |color, sy|
            next unless color  # Skip transparent pixels

            draw_y = base_y + sy
            next if draw_y < 0 || draw_y > max_y

            framebuffer[draw_y * SCREEN_WIDTH + draw_x] = color
          end
        end
      end

      def draw_muzzle_flash(framebuffer, weapon_name)
        weapon_data = @gfx.weapons[weapon_name]
        return unless weapon_data && weapon_data[:flash]

        flash_frame = @player.attack_frame.clamp(0, weapon_data[:flash].length - 1)
        flash_sprite = weapon_data[:flash][flash_frame]
        return unless flash_sprite

        # Flash uses same positioning as weapon sprite (built-in offsets)
        # Same positioning formula as weapon sprite
        flash_x = 1 - flash_sprite.left_offset
        flash_y = 120 - (WEAPONTOP - flash_sprite.top_offset)

        draw_weapon_sprite(framebuffer, flash_sprite, flash_x, flash_y)
      end
    end
  end
end
