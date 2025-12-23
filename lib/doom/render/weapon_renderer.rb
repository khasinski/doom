# frozen_string_literal: true

module Doom
  module Render
    # Renders the first-person weapon view
    class WeaponRenderer
      # Weapon is rendered above the status bar
      WEAPON_AREA_HEIGHT = SCREEN_HEIGHT - StatusBar::STATUS_BAR_HEIGHT

      def initialize(hud_graphics, player_state)
        @gfx = hud_graphics
        @player = player_state
      end

      def render(framebuffer)
        weapon_name = @player.weapon_name
        weapon_data = @gfx.weapons[weapon_name]
        return unless weapon_data

        # Get the appropriate frame
        sprite = if @player.attacking && weapon_data[:fire]
                   frame = @player.attack_frame.clamp(0, weapon_data[:fire].length - 1)
                   weapon_data[:fire][frame]
                 else
                   weapon_data[:idle]
                 end

        return unless sprite

        # Calculate position with bob offset
        bob_x = @player.weapon_bob_x.to_i
        bob_y = @player.weapon_bob_y.to_i

        # Center weapon horizontally (sprite width / 2 from center)
        # Position weapon at bottom of view area
        # Weapon offsets in DOOM are negative, meaning the sprite draws UP and LEFT from origin
        x = (SCREEN_WIDTH / 2) - (sprite.width / 2) + bob_x
        y = WEAPON_AREA_HEIGHT - sprite.height + bob_y

        # Add some vertical offset during attack (recoil effect)
        if @player.attacking
          recoil = case @player.attack_frame
                   when 0 then -6
                   when 1 then -3
                   when 2 then 3
                   else 0
                   end
          y += recoil
        end

        draw_weapon_sprite(framebuffer, sprite, x, y)

        # Draw muzzle flash for pistol
        if @player.attacking && @player.attack_frame < 2
          draw_muzzle_flash(framebuffer, weapon_name, x, y)
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

      def draw_muzzle_flash(framebuffer, weapon_name, weapon_x, weapon_y)
        weapon_data = @gfx.weapons[weapon_name]
        return unless weapon_data && weapon_data[:flash]

        flash_frame = @player.attack_frame.clamp(0, weapon_data[:flash].length - 1)
        flash_sprite = weapon_data[:flash][flash_frame]
        return unless flash_sprite

        # Flash is drawn at weapon position (sprite handles offset)
        flash_x = (SCREEN_WIDTH / 2) - flash_sprite.left_offset
        flash_y = WEAPON_AREA_HEIGHT - flash_sprite.top_offset

        draw_weapon_sprite(framebuffer, flash_sprite, flash_x, flash_y)
      end
    end
  end
end
