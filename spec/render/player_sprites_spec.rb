# frozen_string_literal: true

require_relative '../spec_helper'

# Other players are drawn with the PLAY sprites. Nothing else in the engine
# renders a player, so these specs check the pixels rather than the plumbing.
RSpec.describe 'rendering other players' do
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

  # E1M1 start, facing north up a long open corridor.
  VIEWER = [1056.0, -3616.0, 41.0, 90.0].freeze

  def build_renderer
    r = Doom::Render::Renderer.new(@wad, @map, @textures, @palette, @colormap,
                                   @flats, @sprites, nil)
    r.apply_view(VIEWER[0], VIEWER[1], VIEWER[2], VIEWER[3] * Math::PI / 180.0)
    r
  end

  def viewer_player
    p = Doom::Game::Player.new(id: 0)
    p.place(*VIEWER)
    p
  end

  # Another player standing `dist` units in front of the viewer (which faces +y).
  def other_player(dist: 200, id: 1)
    p = Doom::Game::Player.new(id: id)
    p.place(VIEWER[0], VIEWER[1] + dist, VIEWER[2], 270)
    p
  end

  def render(players, view_player)
    r = build_renderer
    r.players = players
    r.view_player = view_player
    r.render_frame
    r
  end

  it 'draws a second player into the frame' do
    me = viewer_player
    empty = render([me], me)
    with_other = render([me, other_player], me)

    expect(with_other.framebuffer).not_to eq(empty.framebuffer)
  end

  it 'never draws the player being looked through' do
    me = viewer_player
    alone = render([me], me)

    # Same world with nobody else in it must be pixel-identical to no players
    # at all -- otherwise we are drawing the viewer's own body in their face.
    none = render([], nil)
    expect(alone.framebuffer).to eq(none.framebuffer)
  end

  it 'does not draw a player standing behind the viewer' do
    me = viewer_player
    behind = Doom::Game::Player.new(id: 1)
    behind.place(VIEWER[0], VIEWER[1] - 200, VIEWER[2], 90)

    expect(render([me, behind], me).framebuffer).to eq(render([me], me).framebuffer)
  end

  it 'draws a nearer player larger than a distant one' do
    me = viewer_player
    near = render([me, other_player(dist: 150)], me)
    far  = render([me, other_player(dist: 600)], me)
    base = render([me], me)

    near_pixels = near.framebuffer.each_index.count { |i| near.framebuffer[i] != base.framebuffer[i] }
    far_pixels  = far.framebuffer.each_index.count { |i| far.framebuffer[i] != base.framebuffer[i] }

    expect(near_pixels).to be > far_pixels
    expect(far_pixels).to be > 0
  end

  it 'tolerates an empty or unset player list' do
    r = build_renderer
    expect { r.render_frame }.not_to raise_error

    r.players = []
    expect { r.render_frame }.not_to raise_error
  end

  describe 'sprite selection' do
    let(:renderer) { build_renderer }

    def frame_for(player)
      renderer.send(:player_sprite, player, 0.0)
    end

    it 'uses a death frame for a dead player' do
      p = other_player
      p.state.dead = true
      p.state.death_tic = 0
      dead_sprite = frame_for(p)

      alive = frame_for(other_player)
      expect(dead_sprite).not_to be_nil
      expect(dead_sprite).not_to equal(alive)
    end

    it 'advances the death animation over time' do
      early = other_player
      early.state.dead = true
      early.state.death_tic = 0

      late = other_player
      late.state.dead = true
      late.state.death_tic = 30

      expect(frame_for(early)).not_to equal(frame_for(late))
    end

    it 'holds the last death frame instead of running off the end' do
      p = other_player
      p.state.dead = true
      p.state.death_tic = 100_000
      expect(frame_for(p)).not_to be_nil
    end

    it 'uses the attack frame while firing' do
      p = other_player
      p.state.attacking = true
      expect(frame_for(p)).not_to equal(frame_for(other_player))
    end

    it 'gives a standing player a sprite' do
      expect(frame_for(other_player)).not_to be_nil
    end

    it 'picks different rotations depending on where the viewer stands' do
      p = other_player
      front = renderer.send(:player_sprite, p, 0.0)
      side = renderer.send(:player_sprite, p, Math::PI / 2)
      expect(front).not_to equal(side)
    end
  end
end
