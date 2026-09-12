# frozen_string_literal: true

# Self-contained headless benchmark for the Doom-in-Ruby renderer.
#
# Designed to be extractable into a standalone benchmark repo: this file
# requires the Doom library (renderer + WAD readers) and otherwise depends
# only on Ruby's stdlib (net/http, json, zlib, fileutils).
#
# It auto-downloads Freedoom Phase 1 (~12MB zip, ~30MB extracted) on first
# run and caches it under ~/.doom/freedoom1.wad. No window is opened.
#
# Usage:
#   bin/doom --bench
#   bin/doom --bench --json
#   bin/doom --bench --frames=500 --warmup=50
#   bin/doom --bench --wad=/path/to/some.wad
#   bin/doom --bench --map=E1M3

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'zlib'

# Stub Gosu so the renderer's Platform module can load without the gem.
module Doom
  module Platform
    class GosuWindow; end unless defined?(GosuWindow)
  end
end

require_relative 'wad/reader'
require_relative 'wad/palette'
require_relative 'wad/colormap'
require_relative 'wad/flat'
require_relative 'wad/patch'
require_relative 'wad/texture'
require_relative 'wad/sprite'
require_relative 'map/data'
require_relative 'game/player_state'
require_relative 'game/sector_actions'
require_relative 'render/renderer'

module Doom
  module Benchmark
    FREEDOOM_VERSION = '0.13.0'
    FREEDOOM_URL =
      'https://github.com/freedoom/freedoom/releases/download/' \
      "v#{FREEDOOM_VERSION}/freedoom-#{FREEDOOM_VERSION}.zip"
    FREEDOOM_WAD_BASENAME = 'freedoom1.wad'
    CACHE_DIR = File.join(Dir.home, '.doom')

    DEFAULT_WARMUP = 30
    DEFAULT_FRAMES = 200
    DEFAULT_MAP = 'E1M1'

    module_function

    # Entry point. argv is what came after --bench.
    # Returns process exit code.
    def run(argv = [])
      opts = parse_args(argv)
      wad_path = opts[:wad] || ensure_freedoom_wad

      game = load_game(wad_path, opts[:map])
      result = bench_render(game, frames: opts[:frames], warmup: opts[:warmup])

      result[:wad] = File.basename(wad_path)
      result[:map] = opts[:map]
      result[:ruby] = RUBY_DESCRIPTION
      result[:jit] = jit_status

      print_result(result, json: opts[:json])
      0
    rescue StandardError => e
      warn "benchmark failed: #{e.class}: #{e.message}"
      warn e.backtrace.first(10).join("\n")
      1
    end

    def parse_args(argv)
      opts = {
        warmup: DEFAULT_WARMUP,
        frames: DEFAULT_FRAMES,
        map: DEFAULT_MAP,
        wad: nil,
        json: false
      }
      argv.each do |arg|
        case arg
        when '--json' then opts[:json] = true
        when /\A--frames=(\d+)\z/ then opts[:frames] = Regexp.last_match(1).to_i
        when /\A--warmup=(\d+)\z/ then opts[:warmup] = Regexp.last_match(1).to_i
        when /\A--map=(\w+)\z/ then opts[:map] = Regexp.last_match(1).upcase
        when /\A--wad=(.+)\z/ then opts[:wad] = Regexp.last_match(1)
        end
      end
      opts
    end

    def jit_status
      if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enabled?) && RubyVM::YJIT.enabled?
        'YJIT'
      elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.respond_to?(:enabled?) && RubyVM::ZJIT.enabled?
        'ZJIT'
      else
        'OFF'
      end
    end

    def ensure_freedoom_wad
      cached = File.join(CACHE_DIR, FREEDOOM_WAD_BASENAME)
      return cached if File.exist?(cached)

      FileUtils.mkdir_p(CACHE_DIR)
      tmp_zip = File.join(CACHE_DIR, "freedoom-#{FREEDOOM_VERSION}.zip.part")

      warn "Downloading Freedoom Phase 1 v#{FREEDOOM_VERSION} (~12 MB)..."
      download_file(FREEDOOM_URL, tmp_zip)

      warn "Extracting #{FREEDOOM_WAD_BASENAME}..."
      extract_from_zip(tmp_zip, FREEDOOM_WAD_BASENAME, cached)
      File.delete(tmp_zip) if File.exist?(tmp_zip)

      cached
    end

    # Download URL to dest, following redirects.
    def download_file(url, dest, redirect_limit: 5)
      raise 'too many redirects' if redirect_limit < 0

      uri = URI.parse(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request_get(uri.request_uri) do |resp|
          case resp
          when Net::HTTPSuccess
            File.open(dest, 'wb') { |f| resp.read_body { |chunk| f.write(chunk) } }
          when Net::HTTPRedirection
            return download_file(resp['location'], dest, redirect_limit: redirect_limit - 1)
          else
            raise "HTTP #{resp.code} fetching #{url}"
          end
        end
      end
    end

    # Minimal ZIP reader: locate one named file in a ZIP archive and extract
    # it to dest. Supports stored (method 0) and deflated (method 8) entries.
    # No ZIP64, no encryption, no spanning. Sufficient for the Freedoom zip.
    def extract_from_zip(zip_path, target_basename, dest)
      data = File.binread(zip_path)

      eocd = find_eocd(data) or raise "ZIP end-of-central-directory not found in #{zip_path}"
      _, _, _, _, _, _, cdir_offset, = data.byteslice(eocd, 22).unpack('VvvvvVVv')

      ptr = cdir_offset
      while data.byteslice(ptr, 4) == "PK\x01\x02".b
        fields = data.byteslice(ptr, 46).unpack('VvvvvvvVVVvvvvvVV')
        method = fields[4]
        csize = fields[8]
        fname_len = fields[10]
        extra_len = fields[11]
        comment_len = fields[12]
        local_offset = fields[16]
        fname = data.byteslice(ptr + 46, fname_len)

        if File.basename(fname) == target_basename
          lh = data.byteslice(local_offset, 30).unpack('VvvvvvVVVvv')
          lh_fname_len = lh[9]
          lh_extra_len = lh[10]
          data_offset = local_offset + 30 + lh_fname_len + lh_extra_len
          compressed = data.byteslice(data_offset, csize)

          content = case method
                    when 0 then compressed
                    when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(compressed)
                    else raise "unsupported ZIP compression method #{method}"
                    end

          File.binwrite(dest, content)
          return
        end

        ptr += 46 + fname_len + extra_len + comment_len
      end

      raise "#{target_basename} not found in #{zip_path}"
    end

    # EOCD record sits at the end of the file. Search backwards through the
    # last 64KB (max comment size).
    def find_eocd(data)
      sig = "PK\x05\x06".b
      max = data.size - 22
      min = [max - 65_536, 0].max
      max.downto(min) { |i| return i if data.byteslice(i, 4) == sig }
      nil
    end

    def load_game(wad_path, map_name)
      wad = Doom::Wad::Reader.new(wad_path)
      palette = Doom::Wad::Palette.load(wad)
      colormap = Doom::Wad::Colormap.load(wad)
      flats = Doom::Wad::Flat.load_all(wad)
      textures = Doom::Wad::TextureManager.new(wad)
      sprites = Doom::Wad::SpriteManager.new(wad)
      map = Doom::Map::MapData.load(wad, map_name)

      renderer = Doom::Render::Renderer.new(
        wad, map, textures, palette, colormap, flats, sprites
      )
      renderer.skip_background_fill = true

      ps = map.player_start
      renderer.set_player(ps.x, ps.y, 41, ps.angle)

      { renderer: renderer, player_start: ps }
    end

    def bench_render(game, frames:, warmup:)
      renderer = game[:renderer]

      warmup.times { renderer.render_frame }

      GC.start
      GC.compact if GC.respond_to?(:compact)

      gc_before = total_allocs
      times = Array.new(frames)
      frames.times do |i|
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        renderer.render_frame
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        times[i] = t1 - t0
      end
      gc_after = total_allocs

      sorted = times.sort
      total = times.sum
      {
        frames: frames,
        warmup: warmup,
        avg_ms: (total / frames) * 1000,
        median_ms: sorted[frames / 2] * 1000,
        p95_ms: sorted[(frames * 0.95).to_i] * 1000,
        p99_ms: sorted[(frames * 0.99).to_i] * 1000,
        min_ms: sorted.first * 1000,
        max_ms: sorted.last * 1000,
        fps: frames / total,
        allocs_per_frame: (gc_after - gc_before).to_f / frames
      }
    end

    def total_allocs
      GC.stat[:total_allocated_objects] || 0
    rescue StandardError
      0
    end

    def print_result(r, json:)
      if json
        puts JSON.generate(r)
        return
      end

      puts 'DOOM-Ruby benchmark'
      puts "  WAD:    #{r[:wad]} (#{r[:map]})"
      puts "  Ruby:   #{r[:ruby]}"
      puts "  JIT:    #{r[:jit]}"
      puts ''
      puts "Performance (#{r[:frames]} frames after #{r[:warmup]} warmup):"
      puts '  avg     %.2f ms' % r[:avg_ms]
      puts '  median  %.2f ms' % r[:median_ms]
      puts '  p95     %.2f ms' % r[:p95_ms]
      puts '  p99     %.2f ms' % r[:p99_ms]
      puts '  min     %.2f ms' % r[:min_ms]
      puts '  max     %.2f ms' % r[:max_ms]
      puts '  fps     %.1f' % r[:fps]
      puts '  allocs/frame  %.0f' % r[:allocs_per_frame] if r[:allocs_per_frame] > 0
    end
  end
end
