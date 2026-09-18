# frozen_string_literal: true
# Full GAME frame benchmark on the REAL renderer (lib/doom/render/renderer.rb):
# textured walls, floors, ceilings, sky and sprites -- the actual game frame.
# Four E1M1-start rotations (spawn/hallway/corner/reverse), like the original
# run. Warm up each viewpoint, then time render_frame; one FRAME_MS line per
# frame and a CHECKSUM per viewpoint (must match across every runtime).
#
#   ruby -Ilib bench/real_frame_bench.rb
#   WARMUP=800 ...   # warm steady state for TruffleRuby / JRuby
#
# Env: WARMUP (default 20), REPS (default 60), WAD.

require "json"

%w[
  wad/reader wad/palette wad/colormap wad/flat wad/patch wad/texture
  wad/sprite wad/hud_graphics map/data
  game/player_state game/sector_actions game/animations game/sector_effects
  render/renderer
].each { |f| require "doom/#{f}" rescue LoadError }

WAD_PATH = ENV.fetch("WAD", "/Users/hasik/Projects/doom/doom1.wad")
WARMUP = Integer(ENV.fetch("WARMUP", "20"))
REPS   = Integer(ENV.fetch("REPS", "60"))

wad      = Doom::Wad::Reader.new(WAD_PATH)
palette  = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats    = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites  = Doom::Wad::SpriteManager.new(wad)
map      = Doom::Map::MapData.load(wad, "E1M1")

renderer =
  begin
    animations = Doom::Game::Animations.new(textures.texture_names, flats.map(&:name))
    Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites, animations)
  rescue ArgumentError, NameError
    Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)
  end

start = map.player_start
viewpoints = [["spawn", 0], ["hallway", 90], ["corner", 45], ["reverse", 180]]
combined = 0

viewpoints.each do |name, delta|
  renderer.set_player(start.x, start.y, 41, start.angle + delta)
  WARMUP.times { renderer.render_frame }
  REPS.times do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    renderer.render_frame
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    puts "FRAME_MS #{(t1 - t0) * 1000.0}"
  end
  fb = renderer.framebuffer
  ck = 0; i = 0; n = fb.length
  while i < n
    v = fb[i]; ck += v if v; i += 1
  end
  combined += ck
  puts "VP_CHECKSUM #{name} #{ck}"
end
puts "CHECKSUM #{combined}"
puts "ENGINE #{(defined?(RUBY_ENGINE) ? RUBY_ENGINE : 'ruby')} #{RUBY_VERSION} warmup=#{WARMUP} native=#{ENV['DOOM_NATIVE']}"
