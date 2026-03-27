# frozen_string_literal: true

module Doom
  module Game
    # DOOM main menu system with title screen, new game, and difficulty selection.
    class Menu
      SKULL_ANIM_TICS = 8  # Skull cursor blink rate

      # Difficulty levels matching DOOM's skill levels
      SKILL_BABY = 0      # I'm too young to die
      SKILL_EASY = 1      # Hey, not too rough
      SKILL_MEDIUM = 2    # Hurt me plenty
      SKILL_HARD = 3      # Ultra-Violence
      SKILL_NIGHTMARE = 4 # Nightmare!

      # Menu states
      STATE_TITLE = :title
      STATE_MAIN = :main
      STATE_SKILL = :skill
      STATE_NONE = :none   # In-game, no menu

      # Main menu items
      MAIN_ITEMS = %i[new_game options quit].freeze

      # Skill menu items
      SKILL_ITEMS = [SKILL_BABY, SKILL_EASY, SKILL_MEDIUM, SKILL_HARD, SKILL_NIGHTMARE].freeze

      # Menu item Y positions (from Chocolate Doom m_menu.c)
      MAIN_X = 97
      MAIN_Y = 64
      MAIN_SPACING = 16

      SKILL_X = 48
      SKILL_Y = 63
      SKILL_SPACING = 16

      attr_reader :state, :selected_skill

      def initialize(wad, hud_graphics)
        @wad = wad
        @gfx = hud_graphics
        @state = STATE_TITLE
        @cursor = 0
        @skull_frame = 0
        @skull_tic = 0
        @selected_skill = SKILL_MEDIUM  # Default difficulty

        load_graphics
      end

      def active?
        @state != STATE_NONE
      end

      def needs_background?
        @state != STATE_TITLE
      end

      def update
        @skull_tic += 1
        if @skull_tic >= SKULL_ANIM_TICS
          @skull_tic = 0
          @skull_frame = 1 - @skull_frame
        end
      end

      def render(framebuffer, palette_colors)
        case @state
        when STATE_TITLE
          render_title(framebuffer)
        when STATE_MAIN
          render_main_menu(framebuffer)
        when STATE_SKILL
          render_skill_menu(framebuffer)
        end
      end

      # Returns :start_game if game should begin, nil otherwise
      def handle_key(key)
        case @state
        when STATE_TITLE
          @state = STATE_MAIN
          @cursor = 0
        when STATE_MAIN
          handle_main_key(key)
        when STATE_SKILL
          handle_skill_key(key)
        end
      end

      def dismiss
        @state = STATE_NONE
      end

      def show
        @state = STATE_MAIN
        @cursor = 0
      end

      private

      def load_graphics
        # Title screen
        @title = load_patch('TITLEPIC')

        # Main menu
        @m_doom = load_patch('M_DOOM')
        @m_newg = load_patch('M_NGAME')
        @m_option = load_patch('M_OPTION')
        @m_quitg = load_patch('M_QUITG')

        # Skill menu
        @m_skill = load_patch('M_SKILL')
        @m_jkill = load_patch('M_JKILL')
        @m_hurt = load_patch('M_HURT')
        @m_rough = load_patch('M_ROUGH')  # Not used, but loaded
        @m_ultra = load_patch('M_ULTRA')
        @m_nmare = load_patch('M_NMARE')

        # Episode (shareware only has 1)
        @m_episod = load_patch('M_EPISOD')
        @m_epi1 = load_patch('M_EPI1')

        # Skull cursor
        @skulls = [load_patch('M_SKULL1'), load_patch('M_SKULL2')]
      end

      def load_patch(name)
        @gfx.send(:load_graphic, name)
      end

      def render_title(framebuffer)
        draw_fullscreen(framebuffer, @title) if @title
      end

      def render_main_menu(framebuffer)
        # Draw title logo
        draw_sprite(framebuffer, @m_doom, 94, 2) if @m_doom

        # Draw menu items
        items = [@m_newg, @m_option, @m_quitg]
        items.each_with_index do |item, i|
          next unless item
          draw_sprite(framebuffer, item, MAIN_X, MAIN_Y + i * MAIN_SPACING)
        end

        # Draw skull cursor
        skull = @skulls[@skull_frame]
        if skull
          skull_x = MAIN_X - 32
          skull_y = MAIN_Y + @cursor * MAIN_SPACING - 5
          draw_sprite(framebuffer, skull, skull_x, skull_y)
        end
      end

      def render_skill_menu(framebuffer)
        # Draw skill title
        draw_sprite(framebuffer, @m_skill, 38, 15) if @m_skill

        # Draw skill items: baby, easy, medium, hard, nightmare
        skill_items = [@m_jkill, @m_hurt, @m_rough, @m_ultra, @m_nmare]
        skill_items.each_with_index do |item, i|
          next unless item
          draw_sprite(framebuffer, item, SKILL_X, SKILL_Y + i * SKILL_SPACING)
        end

        # Draw skull cursor
        skull = @skulls[@skull_frame]
        if skull
          skull_x = SKILL_X - 32
          skull_y = SKILL_Y + @cursor * SKILL_SPACING - 5
          draw_sprite(framebuffer, skull, skull_x, skull_y)
        end
      end

      def handle_main_key(key)
        case key
        when :up
          @cursor = (@cursor - 1) % MAIN_ITEMS.size
        when :down
          @cursor = (@cursor + 1) % MAIN_ITEMS.size
        when :enter
          case MAIN_ITEMS[@cursor]
          when :new_game
            @state = STATE_SKILL
            @cursor = SKILL_MEDIUM  # Default to "Hurt me plenty"
          when :quit
            return :quit
          end
        when :escape
          @state = STATE_TITLE
        end
        nil
      end

      def handle_skill_key(key)
        case key
        when :up
          @cursor = (@cursor - 1) % SKILL_ITEMS.size
        when :down
          @cursor = (@cursor + 1) % SKILL_ITEMS.size
        when :enter
          @selected_skill = SKILL_ITEMS[@cursor]
          @state = STATE_NONE
          return :start_game
        when :escape
          @state = STATE_MAIN
          @cursor = 0
        end
        nil
      end

      def draw_fullscreen(framebuffer, sprite)
        return unless sprite
        # TITLEPIC is 320x200, our screen is 320x240
        # Draw it centered vertically (offset by 20 pixels)
        y_offset = 20
        sprite.width.times do |x|
          col = sprite.column_pixels(x)
          next unless col
          col.each_with_index do |color, y|
            next unless color
            screen_y = y + y_offset
            next if screen_y < 0 || screen_y >= 240
            framebuffer[screen_y * 320 + x] = color
          end
        end
      end

      def draw_sprite(framebuffer, sprite, x, y)
        return unless sprite
        sprite.width.times do |col_x|
          screen_x = x + col_x
          next if screen_x < 0 || screen_x >= 320

          col = sprite.column_pixels(col_x)
          next unless col

          col.each_with_index do |color, col_y|
            next unless color
            screen_y = y + col_y
            next if screen_y < 0 || screen_y >= 240
            framebuffer[screen_y * 320 + screen_x] = color
          end
        end
      end
    end
  end
end
