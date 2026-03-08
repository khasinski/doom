#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a GIF showing the BSP rendering process segment by segment.
# Each frame adds one more seg to the scene, revealing how Doom builds a frame.
#
# Usage:
#   ruby tools/render_segments_film.rb [wad_path] [output.gif]

require 'chunky_png'
require 'fileutils'

# Prevent Gosu from loading
module Doom
  module Platform
    class GosuWindow; end
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

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

WAD_PATH = ARGV[0] || 'doom1.wad'
OUTFILE  = ARGV[1] || 'segment_render.gif'
SCALE    = 2  # upscale for visibility

abort "Cannot find #{WAD_PATH}" unless File.exist?(WAD_PATH)

# Subclass renderer to capture state after each seg
module Doom
  module Render
    class SteppingRenderer < Renderer
      attr_reader :seg_snapshots

      def initialize(*)
        super
        @seg_snapshots = []
        @capturing = false
        @seg_drew_pixels = false
      end

      def render_frame_with_capture
        @seg_snapshots = []
        @capturing = true
        render_frame
        @capturing = false
      end

      # Skip background fill so we start from black - makes wall drawing visible
      def draw_floor_ceiling_background
        # no-op during capture
      end

      # Override draw_wall_column_ex to detect when a seg actually draws pixels
      def draw_wall_column_ex(*)
        @seg_drew_pixels = true if @capturing
        super
      end

      # Override render_seg to snapshot after each seg that drew something
      def render_seg(seg)
        @seg_drew_pixels = false
        super
        if @capturing && @seg_drew_pixels
          @seg_snapshots << @framebuffer.dup
        end
      end

      # Capture after visplanes are drawn (floor/ceiling fills in)
      def draw_all_visplanes
        super
        @seg_snapshots << @framebuffer.dup if @capturing
      end

      # Capture after sprites
      def render_sprites
        super
        @seg_snapshots << @framebuffer.dup if @capturing
      end
    end
  end
end

puts "Loading WAD: #{WAD_PATH}"
wad = Doom::Wad::Reader.new(WAD_PATH)
palette = Doom::Wad::Palette.load(wad)
colormap = Doom::Wad::Colormap.load(wad)
flats = Doom::Wad::Flat.load_all(wad)
textures = Doom::Wad::TextureManager.new(wad)
sprites = Doom::Wad::SpriteManager.new(wad)
map = Doom::Map::MapData.load(wad, 'E1M1')

renderer = Doom::Render::SteppingRenderer.new(wad, map, textures, palette, colormap, flats, sprites)

player_start = map.player_start
renderer.set_player(player_start.x, player_start.y, 41, player_start.angle)

puts "Rendering frame with segment capture..."
renderer.render_frame_with_capture

total = renderer.seg_snapshots.size
puts "Captured #{total} snapshots (visible segs + visplanes + sprites)"

# Build palette lookup (index -> ChunkyPNG color)
colors = palette.colors.map { |r, g, b| ChunkyPNG::Color.rgb(r, g, b) }

w = Doom::Render::SCREEN_WIDTH
h = Doom::Render::SCREEN_HEIGHT
sw = w * SCALE
sh = h * SCALE

# Sample frames evenly - aim for ~30s at 2fps
max_frames = 60
if total <= max_frames
  frame_indices = (0...total).to_a
else
  frame_indices = max_frames.times.map { |i| (i * (total - 1).to_f / (max_frames - 1)).round }
  frame_indices.uniq!
end
frame_indices << total - 1 unless frame_indices.last == total - 1

puts "Generating #{frame_indices.size} frames..."

tmpdir = File.join(__dir__, '..', 'tmp', 'seg_frames')
FileUtils.rm_rf(tmpdir)
FileUtils.mkdir_p(tmpdir)

frame_indices.each_with_index do |snap_idx, frame_num|
  fb = renderer.seg_snapshots[snap_idx]
  img = ChunkyPNG::Image.new(sw, sh)

  h.times do |y|
    row_offset = y * w
    w.times do |x|
      color = colors[fb[row_offset + x]]
      SCALE.times do |sy|
        SCALE.times do |sx|
          img[x * SCALE + sx, y * SCALE + sy] = color
        end
      end
    end
  end

  path = File.join(tmpdir, "frame_%04d.png" % frame_num)
  img.save(path)
  print "\r  Frame #{frame_num + 1}/#{frame_indices.size}"
end
puts ""

# Add pause at the end (4 extra copies of final frame = 2s pause)
4.times do |i|
  src = File.join(tmpdir, "frame_%04d.png" % (frame_indices.size - 1))
  dst = File.join(tmpdir, "frame_%04d.png" % (frame_indices.size + i))
  FileUtils.cp(src, dst)
end

total_frames = frame_indices.size + 4
puts "Assembling GIF (#{total_frames} frames at 2 fps)..."

palette_path = File.join(tmpdir, "palette.png")
input_pattern = File.join(tmpdir, "frame_%04d.png")

# Two-pass GIF: generate optimal palette from all frames, then apply
system("ffmpeg", "-y", "-framerate", "2", "-i", input_pattern,
       "-vf", "palettegen=max_colors=256:stats_mode=full",
       palette_path,
       [:out, :err] => "/dev/null")

system("ffmpeg", "-y", "-framerate", "2", "-i", input_pattern,
       "-i", palette_path,
       "-lavfi", "paletteuse=dither=bayer:bayer_scale=3",
       "-loop", "0",
       OUTFILE,
       [:out, :err] => "/dev/null")

FileUtils.rm_rf(tmpdir)

if File.exist?(OUTFILE)
  size_kb = File.size(OUTFILE) / 1024
  duration = total_frames / 2.0
  puts "Generated #{OUTFILE} (#{size_kb} KB, #{total_frames} frames, ~#{duration.round}s, loops)"
else
  abort "Failed to generate GIF"
end
