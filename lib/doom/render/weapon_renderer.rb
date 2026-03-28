# frozen_string_literal: true

module Doom
  module Render
    # Renders the first-person weapon view
    class WeaponRenderer
      # Weapon is rendered above the status bar
      WEAPON_AREA_HEIGHT = SCREEN_HEIGHT - StatusBar::STATUS_BAR_HEIGHT

      # Chocolate Doom R_DrawPSprite weapon positioning:
      # centery = viewheight/2 (view area excluding status bar)
      # texturemid = centery - (WEAPONTOP - spritetopoffset)
      # dc_yl = centery - texturemid (first visible row)
      WEAPONTOP = 32
      VIEW_CENTERY = (SCREEN_HEIGHT - StatusBar::STATUS_BAR_HEIGHT) / 2  # 104

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

        # dc_yl = centery - texturemid, where texturemid = centery - (WEAPONTOP - topoffset)
        # Simplifies to: dc_yl = WEAPONTOP - topoffset
        x = 1 - sprite.left_offset + bob_x
        y = WEAPONTOP - sprite.top_offset + bob_y

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
        flash_y = WEAPONTOP - flash_sprite.top_offset

        draw_weapon_sprite(framebuffer, flash_sprite, flash_x, flash_y)
      end
    end
  end
end
