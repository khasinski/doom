# frozen_string_literal: true

# Load the spinel_native gem. Prefer the local research checkout (it carries
# the native_prelude / native_state extensions this branch relies on) over any
# installed gem.
local_sn = File.expand_path("~/Projects/spin/spinel_native/lib")
$LOAD_PATH.unshift(local_sn) if File.directory?(local_sn) && !$LOAD_PATH.include?(local_sn)
require "spinel/native"

module Doom
  module Render
    module SpinelNative
      # The classic renderer's hot path, ported to spinel_native. Each method
      # mirrors a method of lib/doom/render/renderer.rb; the object graph is
      # replaced by flat Integer/Float arrays kept as module state INSIDE the
      # compiled kernel (native_state), exactly like renderer.rb keeps @map /
      # @framebuffer / @ceiling_clip in ivars. `load_map` uploads the flattened
      # map/textures once; `render` then draws a frame per call and returns the
      # framebuffer -- no per-frame re-copy of the map across the boundary.
      #
      # Visplanes are filled inline (sn_flat_span / sn_sky_span) instead of being
      # deferred through visplane objects -- the per-pixel sampling is identical,
      # so the output matches the reference renderer.
      #
      # The whole module is one kernel (native_state), so every native method
      # carries a signature. With SPINEL_NATIVE=off the same bodies run as plain
      # Ruby against the module's own ivars, which is how the port is verified
      # against renderer.rb before it is compiled.
      module Kernel
        extend Spinel::Native

        PROJECTION = 160.0
        SKY_XSCALE = 512.0 / Math::PI
        SKY_YSCALE = 200.0 / 240.0

        native_prelude <<~SRC
          PROJECTION = 160.0
          SKY_XSCALE = 512.0 / 3.14159265358979
          SKY_YSCALE = 200.0 / 240.0
        SRC

        native_state do
          @nodes = [0.0]; @verts = [0]; @segs = [0]; @subs = [0]
          @lines = [0]; @sides = [0]; @secs = [0]
          @wpx = [0]; @wtab = [0]; @fpx = [0]; @cmap = [0]
          @fb = Array.new(76800, 0)
          @cclip = Array.new(320, -1)
          @fclip = Array.new(320, 240)
          @wdepth = Array.new(320, 1.0e30)
          @cdepth = Array.new(320, 1.0e30)
          @fdepth = Array.new(320, 1.0e30)
          @ccos = Array.new(320, 0.0)
          @csin = Array.new(320, 0.0)
          @cds = Array.new(320, 0.0)
          @px = 0.0; @py = 0.0; @pz = 41.0; @ang = 0.0; @sina = 0.0; @cosa = 1.0
          @ncount = 0; @skytex = 0
        end

        # load_map/render are called from Ruby; the getters hand back the wall
        # pass's clip rows so the game's sprite code (kept in Ruby) can occlude
        # sprites against the walls. Everything else stays internal to the kernel.
        native_entries :load_map, :render, :get_cclip, :get_fclip, :get_wdepth

        # Final ceiling/floor clip rows and per-column nearest-wall depth after a
        # render, for the Ruby sprite pass (@sprite_ceiling_clip etc.).
        native "() -> Array[Integer]"
        def get_cclip
          out = Array.new(320, 0)
          i = 0
          while i < 320
            out[i] = @cclip[i]
            i += 1
          end
          out
        end

        native "() -> Array[Integer]"
        def get_fclip
          out = Array.new(320, 0)
          i = 0
          while i < 320
            out[i] = @fclip[i]
            i += 1
          end
          out
        end

        native "() -> Array[Float]"
        def get_wdepth
          out = Array.new(320, 0.0)
          i = 0
          while i < 320
            out[i] = @wdepth[i]
            i += 1
          end
          out
        end


        # Upload the flattened map/textures once (kept in kernel state).
        native "(Array[Float], Array[Integer], Array[Integer], Array[Integer], Array[Integer], " \
               "Array[Integer], Array[Integer], Array[Integer], Array[Integer], Array[Integer], " \
               "Array[Integer], Integer, Integer) -> Integer"
        def load_map(nodes, verts, segs, subs, lines, sides, secs, wpx, wtab, fpx, cmap, ncount, skytex)
          @nodes = nodes; @verts = verts; @segs = segs; @subs = subs
          @lines = lines; @sides = sides; @secs = secs
          @wpx = wpx; @wtab = wtab; @fpx = fpx; @cmap = cmap
          @ncount = ncount; @skytex = skytex
          @nodes.length
        end

        # Render one frame; returns the framebuffer (76800 palette indices).
        native "(Integer, Integer, Integer, Float) -> Array[Integer]"
        def render(px, py, pz, angle)
          @px = px.to_f; @py = py.to_f; @pz = pz.to_f
          @ang = angle
          @sina = Math.sin(angle)
          @cosa = Math.cos(angle)
          i = 0
          while i < 76800
            @fb[i] = 0
            i += 1
          end
          i = 0
          while i < 320
            @cclip[i] = -1
            @fclip[i] = 240
            @wdepth[i] = 1.0e30
            i += 1
          end
          sn_precompute
          sn_bsp(@ncount - 1)
          # Return a locally-built copy with a concrete Array[Integer] type;
          # spinel will not cross the boundary with an ivar of inferred (poly) type.
          out = Array.new(76800, 0)
          j = 0
          while j < 76800
            out[j] = @fb[j]
            j += 1
          end
          out
        end

        # mirrors precompute_column_data (+ column_distscale from setup)
        native "() -> Integer"
        def sn_precompute
          x = 0
          while x < 320
            ca = @ang - Math.atan2((x - 160).to_f, PROJECTION)
            @ccos[x] = Math.cos(ca)
            @csin[x] = Math.sin(ca)
            dxx = (x - 160).to_f
            @cds[x] = Math.sqrt(dxx * dxx + PROJECTION * PROJECTION) / PROJECTION
            x += 1
          end
          0
        end

        # mirrors render_bsp_node (front-to-back), iterative with an explicit stack
        native "(Integer) -> Integer"
        def sn_bsp(root)
          stack = Array.new(2048, 0)
          sp = 0
          stack[sp] = root
          sp = sp + 1
          while sp > 0
            sp = sp - 1
            ni = stack[sp]
            if (ni & 0x8000) != 0
              sn_subsector(ni & 0x7FFF)
            else
              b = ni * 6
              dx = @px - @nodes[b]
              dy = @py - @nodes[b + 1]
              left_v = dy * @nodes[b + 2]
              right_v = dx * @nodes[b + 3]
              if right_v >= left_v
                stack[sp] = @nodes[b + 5].to_i
                sp = sp + 1
                stack[sp] = @nodes[b + 4].to_i
                sp = sp + 1
              else
                stack[sp] = @nodes[b + 4].to_i
                sp = sp + 1
                stack[sp] = @nodes[b + 5].to_i
                sp = sp + 1
              end
            end
          end
          0
        end

        # mirrors render_subsector
        native "(Integer) -> Integer"
        def sn_subsector(index)
          first = @subs[index * 2]
          count = @subs[index * 2 + 1]
          i = 0
          while i < count
            sn_seg(first + i)
            i += 1
          end
          0
        end

        # mirrors render_seg: transform, near-clip, project, backface, dispatch
        native "(Integer) -> Integer"
        def sn_seg(seg_i)
          v1i = @segs[seg_i * 5]
          v2i = @segs[seg_i * 5 + 1]
          dx1 = @verts[v1i * 2].to_f - @px
          dy1 = @verts[v1i * 2 + 1].to_f - @py
          x1 = dx1 * @sina - dy1 * @cosa
          y1 = dx1 * @cosa + dy1 * @sina
          dx2 = @verts[v2i * 2].to_f - @px
          dy2 = @verts[v2i * 2 + 1].to_f - @py
          x2 = dx2 * @sina - dy2 * @cosa
          y2 = dx2 * @cosa + dy2 * @sina

          if y1 <= 0.0 && y2 <= 0.0
            return 0
          end
          near = 1.0
          if y1 < near || y2 < near
            if y1 < near && y2 < near
              return 0
            elsif y1 < near
              t = (near - y1) / (y2 - y1)
              x1 = x1 + t * (x2 - x1)
              y1 = near
            elsif y2 < near
              t = (near - y1) / (y2 - y1)
              x2 = x1 + t * (x2 - x1)
              y2 = near
            end
          end

          sx1 = 160.0 + x1 * PROJECTION / y1
          sx2 = 160.0 + x2 * PROJECTION / y2
          if sx1 >= sx2
            return 0
          end
          if sx2 < 0.0 || sx1 >= 320.0
            return 0
          end
          x1i = sx1.to_i
          if x1i < 0
            x1i = 0
          end
          x2i = sx2.to_i
          if x2i > 319
            x2i = 319
          end
          if x1i > x2i
            return 0
          end

          ldi = @segs[seg_i * 5 + 2]
          dir = @segs[seg_i * 5 + 3]
          sd_idx = dir == 0 ? @lines[ldi * 3] : @lines[ldi * 3 + 1]
          if sd_idx < 0
            return 0
          end
          fsec = @sides[sd_idx * 6]
          flags = @lines[ldi * 3 + 2]
          back_sd = -1
          if (flags & 4) != 0
            bsi = dir == 0 ? @lines[ldi * 3 + 1] : @lines[ldi * 3]
            if bsi >= 0
              back_sd = bsi
            end
          end

          segdx = (@verts[v2i * 2] - @verts[v1i * 2]).to_f
          segdy = (@verts[v2i * 2 + 1] - @verts[v1i * 2 + 1]).to_f
          seg_len = Math.sqrt(segdx * segdx + segdy * segdy)

          sn_seg_range(x1i, x2i, sx1, sx2, y1, y2, fsec, back_sd, sd_idx, flags, seg_i, seg_len)
          0
        end

        # mirrors draw_seg_range (texture-column coefficients, per-column loop)
        native "(Integer, Integer, Float, Float, Float, Float, Integer, Integer, Integer, Integer, Integer, Float) -> Integer"
        def sn_seg_range(x1, x2, sx1, sx2, dist1, dist2, fsec, back_sd, sd_idx, flags, seg_i, seg_len)
          v1i = @segs[seg_i * 5]
          v2i = @segs[seg_i * 5 + 1]
          segdx = (@verts[v2i * 2] - @verts[v1i * 2]).to_f
          segdy = (@verts[v2i * 2 + 1] - @verts[v1i * 2 + 1]).to_f
          pxr = @px - @verts[v1i * 2].to_f
          pyr = @py - @verts[v1i * 2 + 1].to_f
          sin_a = @sina
          cos_a = @cosa
          c1 = cos_a * PROJECTION - sin_a * 160.0
          c2 = sin_a * PROJECTION + cos_a * 160.0
          tex_a = segdy * sin_a + segdx * cos_a
          tex_b = segdy * c1 - segdx * c2
          tex_e = pyr * sin_a + pxr * cos_a
          tex_f = pyr * c1 - pxr * c2
          tex_offset = @segs[seg_i * 5 + 4] + @sides[sd_idx * 6 + 4]

          f_floor = @secs[fsec * 7]
          f_ceil = @secs[fsec * 7 + 1]
          f_csky = @secs[fsec * 7 + 5]
          has_ceil = 0
          if f_ceil.to_f > @pz
            has_ceil = 1
          end
          if f_csky != 0
            has_ceil = 1
          end
          has_floor = 0
          if f_floor.to_f < @pz
            has_floor = 1
          end

          x = x1
          while x <= x2
            if @cclip[x] < @fclip[x] - 1
              t = 0.0
              if sx2 != sx1
                t = (x.to_f - sx1) / (sx2 - sx1)
              end
              if t < 0.0
                t = 0.0
              end
              if t > 1.0
                t = 1.0
              end
              dist = dist1
              if dist1 > 0.0 && dist2 > 0.0
                inv = (1.0 - t) / dist1 + t / dist2
                dist = 1.0 / inv
              else
                if dist1 > 0.0
                  dist = dist1
                else
                  dist = dist2
                end
              end
              denom = tex_a * x.to_f + tex_b
              ss = 0.0
              da = denom
              if da < 0.0
                da = -da
              end
              if da >= 0.001
                ss = (tex_e * x.to_f + tex_f) / denom
              end
              tex_col = (tex_offset.to_f + ss * seg_len).to_i
              if dist >= 1.0
                scale = PROJECTION / dist
                front_floor = f_floor.to_f - @pz
                front_ceil = f_ceil.to_f - @pz
                fcf = 120.0 - front_ceil * scale
                front_ceil_y = fcf.to_i
                if fcf > front_ceil_y.to_f
                  front_ceil_y = front_ceil_y + 1
                end
                front_floor_y = (120.0 - front_floor * scale).to_i
                ceil_y = front_ceil_y
                if @cclip[x] + 1 > ceil_y
                  ceil_y = @cclip[x] + 1
                end
                floor_y = front_floor_y
                if @fclip[x] - 1 < floor_y
                  floor_y = @fclip[x] - 1
                end
                if back_sd >= 0
                  sn_two_sided(x, ceil_y, floor_y, scale, dist, tex_col, fsec, back_sd, sd_idx, flags, has_ceil, has_floor)
                else
                  sn_one_sided(x, ceil_y, floor_y, scale, dist, tex_col, fsec, sd_idx, flags, has_ceil, has_floor)
                end
              end
            end
            x += 1
          end
          0
        end

        # mirrors draw_one_sided_seg_column
        native "(Integer, Integer, Integer, Float, Float, Integer, Integer, Integer, Integer, Integer, Integer) -> Integer"
        def sn_one_sided(x, ceil_y, floor_y, scale, dist, tex_col, fsec, sd_idx, flags, has_ceil, has_floor)
          f_floor = @secs[fsec * 7]
          f_ceil = @secs[fsec * 7 + 1]
          f_light = @secs[fsec * 7 + 2]
          f_ff = @secs[fsec * 7 + 3]
          f_cf = @secs[fsec * 7 + 4]
          f_csky = @secs[fsec * 7 + 5]
          f_fsky = @secs[fsec * 7 + 6]

          if has_ceil != 0
            mt = @cclip[x] + 1
            mb = ceil_y - 1
            if @fclip[x] - 1 < mb
              mb = @fclip[x] - 1
            end
            if mt <= mb
              if f_csky != 0
                sn_sky_span(x, mt, mb)
              else
                sn_flat_span(x, mt, mb, f_ceil, f_light, f_cf)
              end
            end
          end

          if has_floor != 0
            mt = floor_y + 1
            if @cclip[x] + 1 > mt
              mt = @cclip[x] + 1
            end
            mb = @fclip[x] - 1
            if mt <= mb
              if f_fsky != 0
                sn_sky_span(x, mt, mb)
              else
                sn_flat_span(x, mt, mb, f_floor, f_light, f_ff)
              end
            end
          end

          mid = @sides[sd_idx * 6 + 3]
          yoff = @sides[sd_idx * 6 + 5]
          if (flags & 16) != 0
            th = 128
            if mid >= 0
              th = @wtab[mid * 3 + 2]
            end
            mid_tex_y = yoff + th - (f_ceil - f_floor)
          else
            mid_tex_y = yoff
          end
          sn_wall_column(x, ceil_y, floor_y, mid, dist, f_light, tex_col, mid_tex_y, scale, f_ceil.to_f)

          if dist < @wdepth[x]
            @wdepth[x] = dist
          end
          @cclip[x] = 240
          @fclip[x] = -1
          0
        end

        # mirrors draw_two_sided_seg_column
        native "(Integer, Integer, Integer, Float, Float, Integer, Integer, Integer, Integer, Integer, Integer, Integer) -> Integer"
        def sn_two_sided(x, ceil_y, floor_y, scale, dist, tex_col, fsec, back_sd, sd_idx, flags, has_ceil, has_floor)
          f_floor = @secs[fsec * 7]
          f_ceil = @secs[fsec * 7 + 1]
          f_light = @secs[fsec * 7 + 2]
          f_ff = @secs[fsec * 7 + 3]
          f_cf = @secs[fsec * 7 + 4]
          f_csky = @secs[fsec * 7 + 5]
          f_fsky = @secs[fsec * 7 + 6]
          bsec = @sides[back_sd * 6]
          b_floor = @secs[bsec * 7]
          b_ceil = @secs[bsec * 7 + 1]
          b_light = @secs[bsec * 7 + 2]
          b_ff = @secs[bsec * 7 + 3]
          b_cf = @secs[bsec * 7 + 4]
          b_csky = @secs[bsec * 7 + 5]

          back_floor = b_floor.to_f - @pz
          back_ceil = b_ceil.to_f - @pz
          back_ceil_y = (120.0 - back_ceil * scale).to_i
          bfy = 120.0 - back_floor * scale
          back_floor_y = bfy.to_i
          if bfy > back_floor_y.to_f
            back_floor_y = back_floor_y + 1
          end

          closed_door = 0
          if b_ceil <= f_floor
            closed_door = 1
          end
          if b_floor >= f_ceil
            closed_door = 1
          end
          both_sky = 0
          if f_csky != 0 && b_csky != 0
            both_sky = 1
          end
          eff_front_ceil = f_ceil
          if both_sky != 0
            eff_front_ceil = b_ceil
          end

          should_mark_ceiling = 0
          should_mark_floor = 0
          if closed_door != 0
            should_mark_ceiling = 1
            should_mark_floor = 1
          else
            if eff_front_ceil != b_ceil
              should_mark_ceiling = 1
            end
            if f_cf != b_cf
              should_mark_ceiling = 1
            end
            if f_light != b_light
              should_mark_ceiling = 1
            end
            if f_floor != b_floor
              should_mark_floor = 1
            end
            if f_ff != b_ff
              should_mark_floor = 1
            end
            if f_light != b_light
              should_mark_floor = 1
            end
          end

          if has_ceil != 0 && should_mark_ceiling != 0
            mt = @cclip[x] + 1
            mb = ceil_y - 1
            if @fclip[x] - 1 < mb
              mb = @fclip[x] - 1
            end
            if mt <= mb
              if f_csky != 0
                sn_sky_span(x, mt, mb)
              else
                sn_flat_span(x, mt, mb, f_ceil, f_light, f_cf)
              end
            end
          end

          if has_floor != 0 && should_mark_floor != 0
            mt = floor_y + 1
            mb = @fclip[x] - 1
            if @cclip[x] + 1 > mt
              mt = @cclip[x] + 1
            end
            if mt <= mb
              if f_fsky != 0
                sn_sky_span(x, mt, mb)
              else
                sn_flat_span(x, mt, mb, f_floor, f_light, f_ff)
              end
            end
          end

          if both_sky == 0 && f_ceil > b_ceil
            upper = @sides[sd_idx * 6 + 1]
            yoff = @sides[sd_idx * 6 + 5]
            if (flags & 8) != 0
              upper_tex_y = yoff
            else
              th = 128
              if upper >= 0
                th = @wtab[upper * 3 + 2]
              end
              upper_tex_y = yoff + b_ceil - f_ceil + th
            end
            sn_wall_column(x, ceil_y, back_ceil_y, upper, dist, f_light, tex_col, upper_tex_y, scale, f_ceil.to_f)
          end

          if f_floor < b_floor
            lower = @sides[sd_idx * 6 + 2]
            yoff = @sides[sd_idx * 6 + 5]
            if (flags & 16) != 0
              lower_tex_y = yoff + f_ceil - b_floor
            else
              lower_tex_y = yoff
            end
            sn_wall_column(x, back_floor_y, floor_y, lower, dist, f_light, tex_col, lower_tex_y, scale, b_floor.to_f)
          end

          if closed_door != 0
            if dist < @wdepth[x]
              @wdepth[x] = dist
            end
            @cclip[x] = 240
            @fclip[x] = -1
          else
            if eff_front_ceil > b_ceil
              if back_ceil_y > @cclip[x]
                @cclip[x] = back_ceil_y
              end
            elsif eff_front_ceil < b_ceil
              if ceil_y - 1 > @cclip[x]
                @cclip[x] = ceil_y - 1
              end
            else
              if f_cf != b_cf || f_light != b_light
                if ceil_y - 1 > @cclip[x]
                  @cclip[x] = ceil_y - 1
                end
              end
            end
            if f_floor < b_floor
              if back_floor_y < @fclip[x]
                @fclip[x] = back_floor_y
              end
            elsif f_floor > b_floor
              if floor_y + 1 < @fclip[x]
                @fclip[x] = floor_y + 1
              end
            else
              if f_ff != b_ff || f_light != b_light
                if floor_y + 1 < @fclip[x]
                  @fclip[x] = floor_y + 1
                end
              end
            end
          end
          0
        end

        # mirrors draw_wall_column_ex (top-pegged texel walk, transparent skip)
        native "(Integer, Integer, Integer, Integer, Float, Integer, Integer, Integer, Float, Float) -> Integer"
        def sn_wall_column(x, y1, y2, tex, dist, light, tex_col, tex_y_start, scale, world_top)
          if y1 > y2
            return 0
          end
          if tex < 0
            return 0
          end
          clip_top = @cclip[x] + 1
          clip_bot = @fclip[x] - 1
          if y1 < clip_top
            y1 = clip_top
          end
          if y2 > clip_bot
            y2 = clip_bot
          end
          if y1 > y2
            return 0
          end
          base = @wtab[tex * 3]
          tw = @wtab[tex * 3 + 1]
          th = @wtab[tex * 3 + 2]
          wlnum = light >> 4
          if wlnum > 15
            wlnum = 15
          end
          if wlnum < 0
            wlnum = 0
          end
          wstart = (15 - wlnum) * 4
          wsi = 47
          if dist > 0.0
            wsi = (2560.0 / dist).to_i
          end
          if wsi > 47
            wsi = 47
          end
          if wsi < 0
            wsi = 0
          end
          lvl = wstart - wsi / 2
          if lvl < 0
            lvl = 0
          end
          if lvl > 31
            lvl = 31
          end
          tex_x = tex_col % tw
          if tex_x < 0
            tex_x = tex_x + tw
          end
          tex_step = 1.0 / scale
          unclipped_y1 = 120.0 - (world_top - @pz) * scale
          tex_y_at_y1 = tex_y_start.to_f + (y1.to_f - unclipped_y1) * tex_step
          y = y1
          while y <= y2
            off = y - y1
            ty = (tex_y_at_y1 + off.to_f * tex_step).to_i % th
            if ty < 0
              ty = ty + th
            end
            c = @wpx[base + tex_x * th + ty]
            if c >= 0
              @fb[y * 320 + x] = @cmap[lvl * 256 + c]
            end
            y += 1
          end
          0
        end

        # mirrors draw_span's per-pixel flat sampling, done per column inline
        native "(Integer, Integer, Integer, Integer, Integer, Integer) -> Integer"
        def sn_flat_span(x, y1, y2, plane_h, light, flat_idx)
          if y1 > y2
            return 0
          end
          ph = plane_h.to_f - @pz
          if ph < 0.0
            ph = -ph
          end
          if ph == 0.0
            return 0
          end
          lnum = light >> 4
          if lnum > 15
            lnum = 15
          end
          if lnum < 0
            lnum = 0
          end
          startmap = (15 - lnum) * 4
          fbase = flat_idx * 4096
          y = y1
          if y < 0
            y = 0
          end
          yy2 = y2
          if yy2 > 239
            yy2 = 239
          end
          while y <= yy2
            dy = y - 120
            if dy != 0
              absdy = dy
              if absdy < 0
                absdy = -absdy
              end
              perp = ph * PROJECTION / absdy.to_f
              rd = perp * @cds[x]
              tx = (@px + rd * @ccos[x]).to_i & 63
              ty = (0.0 - @py - rd * @csin[x]).to_i & 63
              zc = (perp / 16.0).to_i
              if zc > 127
                zc = 127
              end
              if zc < 0
                zc = 0
              end
              lvl = (startmap.to_f - 10.0 / (zc + 1).to_f).to_i
              if lvl < 0
                lvl = 0
              end
              if lvl > 31
                lvl = 31
              end
              @fb[y * 320 + x] = @cmap[lvl * 256 + @fpx[fbase + ty * 64 + tx]]
            end
            y += 1
          end
          0
        end

        # mirrors draw_sky_plane's per-column sky sampling (full bright)
        native "(Integer, Integer, Integer) -> Integer"
        def sn_sky_span(x, y1, y2)
          if y1 > y2
            return 0
          end
          off = @wtab[@skytex * 3]
          sw = @wtab[@skytex * 3 + 1]
          sh = @wtab[@skytex * 3 + 2]
          ca = @ang - Math.atan2((x - 160).to_f, PROJECTION)
          sx = (ca * SKY_XSCALE).to_i % sw
          if sx < 0
            sx = sx + sw
          end
          y = y1
          if y < 0
            y = 0
          end
          yy2 = y2
          if yy2 > 239
            yy2 = 239
          end
          while y <= yy2
            ty = (100.0 + (y - 120).to_f * SKY_YSCALE).to_i % sh
            if ty < 0
              ty = ty + sh
            end
            c = @wpx[off + sx * sh + ty]
            if c >= 0
              @fb[y * 320 + x] = c
            end
            y += 1
          end
          0
        end

      end
    end
  end
end
