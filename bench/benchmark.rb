#!/usr/bin/env ruby
# frozen_string_literal: true

# Headless benchmark for Doom renderer
# Usage:
#   ruby bench/benchmark.rb                    # no YJIT
#   ruby --yjit bench/benchmark.rb             # with YJIT
#   ruby bench/benchmark.rb --compare          # run both and compare
#   ruby bench/benchmark.rb --profile          # profile with stackprof (if available)

require 'benchmark'

# Prevent Gosu from loading (we don't need a window)
module Doom
  module Platform
    class GosuWindow; end
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Load everything except gosu_window
require 'doom/version'
require 'doom/wad_downloader'
require 'doom/wad/reader'
require 'doom/wad/palette'
require 'doom/wad/colormap'
require 'doom/wad/flat'
require 'doom/wad/patch'
require 'doom/wad/texture'
require 'doom/wad/sprite'
require 'doom/wad/hud_graphics'
require 'doom/map/data'
require 'doom/game/player_state'
require 'doom/game/sector_actions'
require 'doom/render/renderer'
require 'doom/render/status_bar'
require 'doom/render/weapon_renderer'

WARMUP_FRAMES = 30
BENCH_FRAMES = 200

# Different viewpoints to test various rendering scenarios
VIEWPOINTS = [
  { name: "spawn",     angle: 0,   desc: "Player start (default view)" },
  { name: "hallway",   angle: 90,  desc: "Rotated 90 deg (long hallway)" },
  { name: "corner",    angle: 45,  desc: "45 deg (wall corners)" },
  { name: "reverse",   angle: 180, desc: "180 deg (looking back)" },
]

def find_wad
  candidates = [
    ARGV.find { |a| a.end_with?('.wad') },
    'doom1.wad',
    File.expand_path('~/.doom/doom1.wad'),
  ].compact

  candidates.each { |p| return p if File.exist?(p) }

  abort "No WAD file found. Place doom1.wad in project root or ~/.doom/"
end

def load_game(wad_path)
  wad = Doom::Wad::Reader.new(wad_path)
  palette = Doom::Wad::Palette.load(wad)
  colormap = Doom::Wad::Colormap.load(wad)
  flats = Doom::Wad::Flat.load_all(wad)
  textures = Doom::Wad::TextureManager.new(wad)
  sprites = Doom::Wad::SpriteManager.new(wad)
  hud_graphics = Doom::Wad::HudGraphics.new(wad)
  map = Doom::Map::MapData.load(wad, 'E1M1')

  renderer = Doom::Render::Renderer.new(wad, map, textures, palette, colormap, flats, sprites)

  player_start = map.player_start
  renderer.set_player(player_start.x, player_start.y, 41, player_start.angle)

  player_state = Doom::Game::PlayerState.new
  status_bar = Doom::Render::StatusBar.new(hud_graphics, player_state)
  weapon_renderer = Doom::Render::WeaponRenderer.new(hud_graphics, player_state)

  { renderer: renderer, player_state: player_state, status_bar: status_bar,
    weapon_renderer: weapon_renderer, player_start: player_start }
end

def bench_render(game, frames: BENCH_FRAMES, warmup: WARMUP_FRAMES)
  renderer = game[:renderer]

  # Warmup
  warmup.times { renderer.render_frame }

  # Force GC before measuring
  GC.start
  GC.compact if GC.respond_to?(:compact)

  gc_before = GC.stat[:total_allocated_objects]

  times = Array.new(frames)
  frames.times do |i|
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    renderer.render_frame
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    times[i] = t1 - t0
  end

  gc_after = GC.stat[:total_allocated_objects]

  times.sort!
  total = times.sum
  {
    total: total,
    avg: total / frames,
    median: times[frames / 2],
    p95: times[(frames * 0.95).to_i],
    p99: times[(frames * 0.99).to_i],
    min: times.first,
    max: times.last,
    fps: frames / total,
    allocs_per_frame: (gc_after - gc_before).to_f / frames,
    frames: frames,
  }
end

def bench_components(game, frames: 100)
  renderer = game[:renderer]
  player_state = game[:player_state]
  status_bar = game[:status_bar]
  weapon_renderer = game[:weapon_renderer]

  # Warmup
  20.times { renderer.render_frame }

  results = {}

  # Full frame (3D only)
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  frames.times { renderer.render_frame }
  results[:render_3d] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / frames

  # Full frame + HUD
  GC.start
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  frames.times do
    renderer.render_frame
    weapon_renderer.render(renderer.framebuffer)
    status_bar.render(renderer.framebuffer)
  end
  results[:render_full] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / frames

  results[:hud_overhead] = results[:render_full] - results[:render_3d]

  results
end

def bench_viewpoints(game, frames: 100)
  renderer = game[:renderer]
  ps = game[:player_start]

  VIEWPOINTS.map do |vp|
    renderer.set_player(ps.x, ps.y, 41, ps.angle + vp[:angle])
    # Warmup
    10.times { renderer.render_frame }
    GC.start

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    frames.times { renderer.render_frame }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    { name: vp[:name], desc: vp[:desc], avg_ms: (elapsed / frames) * 1000, fps: frames / elapsed }
  end
end

def format_ms(seconds)
  "%.2f ms" % (seconds * 1000)
end

def print_results(label, r)
  puts "\n#{label}"
  puts "-" * 50
  puts "  Frames:       #{r[:frames]}"
  puts "  Total:        %.3f s" % r[:total]
  puts "  Avg:          #{format_ms(r[:avg])}"
  puts "  Median:       #{format_ms(r[:median])}"
  puts "  P95:          #{format_ms(r[:p95])}"
  puts "  P99:          #{format_ms(r[:p99])}"
  puts "  Min:          #{format_ms(r[:min])}"
  puts "  Max:          #{format_ms(r[:max])}"
  puts "  FPS:          %.1f" % r[:fps]
  puts "  Allocs/frame: %.0f" % r[:allocs_per_frame]
end

def run_comparison
  wad_path = find_wad
  ruby = RbConfig.ruby

  puts "Running YJIT comparison..."
  puts "Ruby: #{RUBY_DESCRIPTION}"
  puts ""

  script = File.expand_path(__FILE__)

  puts ">>> Without YJIT:"
  system(ruby, script, wad_path, "--run")
  puts ""

  puts ">>> With YJIT:"
  system(ruby, "--yjit", script, wad_path, "--run")
end

def run_profile
  begin
    require 'stackprof'
  rescue LoadError
    abort "stackprof gem required for profiling. Run: gem install stackprof"
  end

  wad_path = find_wad
  puts "Loading WAD for profiling..."
  game = load_game(wad_path)
  renderer = game[:renderer]

  # Warmup
  30.times { renderer.render_frame }

  puts "Profiling #{BENCH_FRAMES} frames (wall time)..."
  profile = StackProf.run(mode: :wall, interval: 100, raw: true) do
    BENCH_FRAMES.times { renderer.render_frame }
  end

  out_path = "bench/profile_#{Time.now.strftime('%Y%m%d_%H%M%S')}.dump"
  File.write(out_path, Marshal.dump(profile))
  puts "Profile saved to #{out_path}"
  puts "View with: stackprof #{out_path} --text --limit 30"
  puts ""

  # Also print inline
  StackProf::Report.new(profile).print_text(STDOUT, 30)
end

def run_benchmark
  wad_path = find_wad

  yjit_status = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "ON" : "OFF"

  puts "=" * 60
  puts "DOOM Ruby Benchmark"
  puts "=" * 60
  puts "Ruby:    #{RUBY_DESCRIPTION}"
  puts "YJIT:    #{yjit_status}"
  puts "WAD:     #{wad_path}"
  puts "Frames:  #{BENCH_FRAMES} (+ #{WARMUP_FRAMES} warmup)"
  puts ""

  puts "Loading game..."
  game = load_game(wad_path)

  # Main benchmark
  r = bench_render(game)
  print_results("Render Performance", r)

  # Component breakdown
  puts "\nComponent Breakdown"
  puts "-" * 50
  comp = bench_components(game)
  puts "  3D render:    #{format_ms(comp[:render_3d])}"
  puts "  Full + HUD:   #{format_ms(comp[:render_full])}"
  puts "  HUD overhead: #{format_ms(comp[:hud_overhead])}"

  # Viewpoint comparison
  puts "\nViewpoint Comparison"
  puts "-" * 50
  bench_viewpoints(game).each do |vp|
    puts "  %-10s %.2f ms (%4.1f fps) - %s" % [vp[:name], vp[:avg_ms], vp[:fps], vp[:desc]]
  end

  # GC stats
  puts "\nGC Stats"
  puts "-" * 50
  gc = GC.stat
  puts "  GC count:      #{gc[:count]}"
  puts "  Heap pages:    #{gc[:heap_eden_pages] || gc[:heap_allocated_pages] || 'N/A'}"
  puts "  Total allocs:  #{gc[:total_allocated_objects]}"

  puts ""
end

# Main
if ARGV.include?('--compare')
  run_comparison
elsif ARGV.include?('--profile')
  run_profile
elsif ARGV.include?('--run') || !ARGV.include?('--compare')
  run_benchmark
end
