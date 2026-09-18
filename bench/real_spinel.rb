# frozen_string_literal: true
# Render the REAL DOOM renderer's E1M1 frame through the spinel AOT compiler --
# the actual textured renderer (lib/doom/render/renderer.rb), not the stripped
# flat-array port. Byte-identical output to CRuby (checksum matches). Four
# E1M1-start rotations, timed; one FRAME_MS line per frame, CHECKSUM per view.
#
#   spinel bench/real_spinel.rb -o real_spinel && ./real_spinel   # (project root)
#   ruby   bench/real_spinel.rb                                    # CRuby, same harness
#   DUMP=1 ...                                                     # also write a PPM

require_relative "../lib/doom/wad/reader"
require_relative "../lib/doom/wad/palette"
require_relative "../lib/doom/wad/colormap"
require_relative "../lib/doom/wad/flat"
require_relative "../lib/doom/wad/patch"
require_relative "../lib/doom/wad/texture"
require_relative "../lib/doom/wad/sprite"
require_relative "../lib/doom/map/data"

module Doom
  module Game
    class PlayerState
      VIEWHEIGHT = 41
    end
    class Player; end
    module MonsterAI
      ATTACK_FRAME_TICS = 1
      ATTACK_FRAMES = {}
    end
  end
end

require_relative "../lib/doom/game/animations"
require_relative "../lib/doom/render/renderer"

WAD_PATH = "/Users/hasik/Projects/doom/doom1.wad"
WARMUP = Integer(ENV.fetch("WARMUP","20"))
REPS   = Integer(ENV.fetch("REPS","60"))

wad      = Doom::Wad::Reader.new(WAD_PATH)
palette  = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats    = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites  = Doom::Wad::SpriteManager.new(wad)
map      = Doom::Map::MapData.load(wad, "E1M1")
animations = Doom::Game::Animations.new(textures.texture_names, flats.map(&:name))

renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites, animations)
start = map.player_start

deltas = [0, 90, 45, 180]
combined = 0
di = 0
while di < deltas.length
  renderer.set_player(start.x, start.y, 41, start.angle + deltas[di])
  w = 0
  while w < WARMUP
    renderer.render_frame
    w = w + 1
  end
  k = 0
  while k < REPS
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    renderer.render_frame
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "FRAME_MS #{(t1 - t0) * 1000.0}"
    k = k + 1
  end
  fb = renderer.framebuffer
  ck = 0
  i = 0
  n = fb.length
  while i < n
    v = fb[i]
    ck = ck + v if v
    i = i + 1
  end
  combined = combined + ck
  puts "VP_CHECKSUM #{di} #{ck}"
  di = di + 1
end
puts "CHECKSUM #{combined}"
