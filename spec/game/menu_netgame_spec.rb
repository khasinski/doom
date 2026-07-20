# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/doom/wad/hud_graphics'
require_relative '../../lib/doom/game/menu'

# In a netgame every peer runs the same world from the same commands. A cheat
# or a new game applied on one machine only is a genuine desync -- unlike a
# pause, which merely stalls -- so those entries must not be reachable.
RSpec.describe 'menu in a netgame' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
  end

  after(:all) { @wad&.close }

  # The menu loads its own graphics from the WAD; HudGraphics is enough.
  def new_menu(netgame:)
    menu = Doom::Game::Menu.new(@wad, Doom::Wad::HudGraphics.new(@wad), nil)
    menu.netgame = netgame
    menu
  end

  describe 'solo' do
    subject(:menu) { new_menu(netgame: false) }

    it 'offers a new game' do
      expect(menu.main_items).to include(:new_game)
    end

    it 'offers the cheats' do
      expect(menu.options_items).to include(*Doom::Game::Menu::NETGAME_UNSAFE_OPTIONS)
    end
  end

  describe 'networked' do
    subject(:menu) { new_menu(netgame: true) }

    it 'does not offer a new game, which would restart the level locally' do
      expect(menu.main_items).not_to include(:new_game)
    end

    it 'does not offer cheats that change simulation state' do
      Doom::Game::Menu::NETGAME_UNSAFE_OPTIONS.each do |cheat|
        expect(menu.options_items).not_to include(cheat)
      end
    end

    it 'still offers options and quit' do
      expect(menu.main_items).to include(:options, :quit)
    end

    it 'keeps the presentation-only options, which touch no game state' do
      expect(menu.options_items).to include(:fullscreen, :uncapped_fps)
    end

    it 'leaves no gap in the item list for the cursor to land on' do
      # The cursor indexes these lists directly, so a filtered-out entry must
      # be gone rather than left as a hole.
      expect(menu.options_items).to all(be_a(Symbol))
      expect(menu.options_items.size).to eq(menu.options_items.compact.size)
    end

    it 'can move the cursor over every remaining main entry' do
      menu.show
      menu.handle_key(:enter) if menu.state == Doom::Game::Menu::STATE_TITLE

      menu.main_items.size.times { menu.handle_key(:down) }
      expect(menu.instance_variable_get(:@cursor)).to be < menu.main_items.size
    end
  end

  describe 'the unsafe list itself' do
    it 'names only options that mutate player state' do
      expect(Doom::Game::Menu::NETGAME_UNSAFE_OPTIONS)
        .to contain_exactly(:god_mode, :infinite_ammo, :all_weapons)
    end

    it 'is a subset of the real options' do
      expect(Doom::Game::Menu::OPTIONS_ITEMS)
        .to include(*Doom::Game::Menu::NETGAME_UNSAFE_OPTIONS)
    end
  end
end
