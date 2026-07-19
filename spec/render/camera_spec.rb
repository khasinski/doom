# frozen_string_literal: true

require_relative '../spec_helper'

# Renderer used to own the player pose; now Game::Player owns it and the
# renderer is aimed via apply_view once per frame. These specs pin that the
# swap is behaviour-preserving -- the camera must produce the same image it
# always did.
RSpec.describe 'renderer as camera' do
  before(:all) do
    skip_without_wad
    @wad = Doom::Wad::Reader.new(wad_path)
    @map = Doom::Map::MapData.load(@wad, 'E1M1')
    @palette = Doom::Wad::Palette.load(@wad)
    @colormap = Doom::Wad::Colormap.load(@wad)
    @flats = Doom::Wad::Flat.load_all(@wad)
    @textures = Doom::Wad::TextureManager.new(@wad)
    @sprites = Doom::Wad::SpriteManager.new(@wad)
  end

  after(:all) { @wad&.close }

  def build_renderer
    Doom::Render::Renderer.new(@wad, @map, @textures, @palette, @colormap,
                               @flats, @sprites, nil)
  end

  # E1M1 player start
  START = [1056.0, -3616.0, 41.0, 90.0].freeze

  it 'renders an identical frame via apply_view as via set_player' do
    x, y, z, deg = START

    legacy = build_renderer
    legacy.set_player(x, y, z, deg)
    legacy.render_frame

    camera = build_renderer
    camera.apply_view(x, y, z, deg * Math::PI / 180.0)
    camera.render_frame

    expect(camera.framebuffer).to eq(legacy.framebuffer)
  end

  it 'renders a non-trivial frame (guards the comparison above from being vacuous)' do
    r = build_renderer
    r.apply_view(*START[0, 3], START[3] * Math::PI / 180.0)
    r.render_frame
    expect(r.framebuffer.uniq.size).to be > 10
  end

  it 'exposes the angle it was given' do
    r = build_renderer
    r.apply_view(0.0, 0.0, 41.0, 1.234)
    expect(r.player_angle).to be_within(1e-12).of(1.234)
    expect(r.sin_angle).to be_within(1e-12).of(Math.sin(1.234))
    expect(r.cos_angle).to be_within(1e-12).of(Math.cos(1.234))
  end

  it 'follows a player pose through view_pose' do
    player = Doom::Game::Player.new
    player.place(*START)

    direct = build_renderer
    direct.set_player(*START)
    direct.render_frame

    followed = build_renderer
    followed.apply_view(*player.view_pose(1.0))
    followed.render_frame

    expect(followed.framebuffer).to eq(direct.framebuffer)
  end

  it 'produces a different frame at an interpolated midpoint' do
    player = Doom::Game::Player.new
    player.place(*START)
    player.snapshot!
    player.move_to(START[0] + 200, START[1] + 200)

    mid = build_renderer
    mid.apply_view(*player.view_pose(0.5))
    mid.render_frame

    end_frame = build_renderer
    end_frame.apply_view(*player.view_pose(1.0))
    end_frame.render_frame

    expect(mid.framebuffer).not_to eq(end_frame.framebuffer)
  end
end
