# Performance Report -- DOOM Ruby v0.5.0

Benchmarked on Apple Silicon (M-series), 200 frames of E1M1 after 30 warmup frames.
All times are frame rendering only (no window/display overhead).

## Results Summary

| Runtime | Avg (ms) | Median (ms) | P95 (ms) | P99 (ms) | FPS | Speedup |
|---------|----------|-------------|----------|----------|-----|---------|
| Ruby 3.3 (interpreter) | 31.46 | 31.30 | 32.95 | 37.63 | **31.8** | 1.00x |
| Ruby 3.4 (interpreter) | 31.15 | 30.97 | 32.17 | 39.74 | **32.1** | 1.01x |
| Ruby 4.0 (interpreter) | 30.22 | 29.99 | 31.77 | 34.40 | **33.1** | 1.04x |
| Ruby 4.0 ZJIT | 28.83 | 28.64 | 29.96 | 31.31 | **34.7** | 1.09x |
| Ruby 3.4 YJIT | 12.53 | 12.40 | 13.76 | 16.34 | **79.8** | 2.51x |
| Ruby 4.0 YJIT | 12.61 | 12.51 | 13.24 | 13.85 | **79.3** | 2.49x |

### Key Findings

**YJIT is transformative**: 2.5x faster than the interpreter on both Ruby 3.4 and 4.0. The renderer goes from barely playable (32 FPS) to smooth (80 FPS). YJIT's effectiveness comes from this workload being tight numeric loops with monomorphic call sites.

**ZJIT is not there yet**: Only 9% faster than the interpreter on Ruby 4.0. The method-at-a-time SSA compiler hasn't yet delivered on inlining or loop optimizations that would benefit this workload. Expected to improve in Ruby 4.1.

**Interpreter versions are flat**: Ruby 3.3, 3.4, and 4.0 interpreters are within 4% of each other. The interpreter is not a bottleneck target.

**Ruby 4.0 YJIT has better tail latency**: P99 is 13.85ms vs 16.34ms on Ruby 3.4. The JIT is more stable with fewer outlier frames, likely from improved compilation heuristics.

## Viewpoint Performance (Ruby 4.0 YJIT)

| View | Time (ms) | FPS | Notes |
|------|-----------|-----|-------|
| Spawn (default) | 12.81 | 78.0 | Moderate complexity |
| Hallway (90 deg) | 11.02 | 90.7 | Long corridor, fewer visplanes |
| Corner (45 deg) | 13.03 | 76.7 | Many wall segments |
| Reverse (180 deg) | 8.90 | 112.3 | Looking at nearby wall, few visplanes |

The 1.5x variance between views confirms that visplane count and floor/ceiling span drawing dominate frame time.

## CPU Profile (Ruby 4.0 YJIT, StackProf wall-clock)

### Top Functions by Self Time

| Function | Self % | Total % | Role |
|----------|--------|---------|------|
| `fill_uncovered_with_sector` | **53.4%** | 57.3% | Background floor/ceiling fill |
| `draw_span` | **18.5%** | 21.2% | Visplane horizontal span drawing |
| `Float#to_i` | **5.3%** | 5.3% | Texture coordinate conversion |
| `draw_seg_range` | **1.9%** | 7.4% | Per-column wall processing |
| `draw_wall_column_ex` | **2.2%** | 3.5% | Wall texture column drawing |
| `render_visplane_spans` | **4.4%** | 31.7% | Visplane span builder |
| `Comparable#clamp` | **2.0%** | 2.3% | Value clamping in inner loops |
| GC | **0.7%** | 0.7% | Garbage collection |

### The #1 Bottleneck: `fill_uncovered_with_sector` (53.4% of frame time)

This function draws the player's sector floor/ceiling across the entire screen as a background, then visplanes overwrite it. It processes **every pixel** in the 320x240 framebuffer (76,800 pixels) with per-pixel texture coordinate computation:

```ruby
while x < SCREEN_WIDTH
  ray_dist = perp_dist * column_distscale[x]
  tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
  tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
  color = flat_pixels[tex_y * 64 + tex_x]
  framebuffer[row_offset + x] = cmap[color]
  x += 1
end
```

Each pixel: 1 multiply, 2 multiply-adds, 2 `.to_i`, 2 `& 63`, 3 array reads, 1 array write. At 76,800 pixels/frame, this is ~1M operations. The floor loop (lines 592-598) and ceiling loop (lines 565-571) account for 53.4% of total frame time combined.

**Why it's so expensive**: Unlike Chocolate Doom (which only draws floors/ceilings via visplanes), we draw the ENTIRE screen as background first. Visplanes then overwrite most of it. The background fill exists to cover gaps at sector boundaries. A large fraction of the work is wasted (overwritten by visplanes).

**Optimization opportunity**: Skip background fill for rows/columns that will be fully covered by visplanes. Or eliminate the background fill entirely by ensuring the visplane system has no gaps (the hardest approach, but would save 53% of frame time).

### The #2 Bottleneck: `draw_span` (18.5%)

The visplane span drawer is the second most expensive function. It draws horizontal spans of floor/ceiling texture with per-pixel lighting. Same inner loop structure as the background fill but only for marked visplane regions (not the entire screen).

### Allocation Pressure

| Metric | Value |
|--------|-------|
| Allocs/frame | ~7,000 |
| Total allocs (200 frames) | ~6.4M |
| GC count (Ruby 4.0 YJIT) | 134 |
| GC % of frame time | 0.7% |

GC is not a significant bottleneck (0.7%). The ~7,000 allocations per frame come from:
- `Visplane.new` per unique floor/ceiling region
- `Drawseg.new` per visible wall segment
- `VisibleSprite.new` per visible thing
- Temporary arrays for visplane top/bottom marks

### Recommendations

1. **Eliminate or reduce background fill** -- This is the single highest-impact optimization. If the visplane system could guarantee full coverage, removing `fill_uncovered_with_sector` would nearly double FPS.

2. **Batch `.to_i` calls** -- `Float#to_i` accounts for 5.3% of self time. Pre-computing integer texture coordinates in bulk (rather than per-pixel) could help.

3. **Skip already-covered pixels** -- Track which framebuffer pixels have been written by walls/visplanes and skip them in the background fill.

4. **Profile-guided visplane marking** -- The background fill exists because some sectors have gaps in visplane coverage. Identifying and fixing those specific gaps would allow removing the fill entirely.

5. **YJIT is mandatory for playability** -- At 32 FPS without JIT, the game is borderline. YJIT at 80 FPS is smooth. Users should be advised to use `--yjit` or Ruby 4.0+ with YJIT enabled.
