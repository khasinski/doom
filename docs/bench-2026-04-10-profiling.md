# CPU Profiling Analysis -- Where Frame Time Goes

StackProf wall-clock profiling, Ruby 4.0 YJIT, 200 frames of E1M1.
44,000 samples, 0.06% miss rate, 0.65% GC.

## Top Functions by Self Time

| Rank | Function | Self % | Total % | What It Does |
|------|----------|--------|---------|-------------|
| 1 | `fill_uncovered_with_sector` | **53.3%** | 57.1% | Background floor/ceiling fill |
| 2 | `draw_span` | **18.5%** | 21.4% | Visplane horizontal spans |
| 3 | `Float#to_i` | **5.3%** | 5.3% | Texture coordinate conversion |
| 4 | `Range#each` | **6.2%** | 39.0% | Iterator overhead |
| 5 | `render_visplane_spans` | **4.4%** | 31.6% | Visplane span builder |
| 6 | `draw_wall_column_ex` | **2.2%** | 3.7% | Wall texture columns |
| 7 | `Comparable#clamp` | **2.2%** | 2.6% | Value clamping |
| 8 | `draw_seg_range` | **1.8%** | 7.4% | Per-column wall processing |
| 9 | `calculate_flat_light` | **0.2%** | 1.5% | Flat lighting lookup |
| 10 | GC | **0.7%** | 0.7% | Garbage collection |

## The #1 Bottleneck: fill_uncovered_with_sector (53.3%)

This single function consumes over half of every frame. It draws the player's current sector's floor and ceiling across the ENTIRE 320x240 framebuffer (76,800 pixels) as a background layer. Then visplanes overwrite most of it with the correct per-sector textures.

### Why it exists

The BSP renderer draws walls and visplanes front-to-back, but some pixels between sector boundaries end up uncovered -- 1-pixel gaps where adjacent visplanes don't perfectly tile. The background fill ensures no "hall of mirrors" artifacts appear in these gaps.

### The hot inner loop (lines 565-571, 592-598)

Each pixel requires:
- 1 multiply: `ray_dist = perp_dist * column_distscale[x]`
- 2 multiply-adds: texture coordinate computation
- 2 `.to_i` calls: float-to-int conversion
- 2 `& 63` masks: texture wrapping
- 3 array reads: texture lookup + colormap
- 1 array write: framebuffer store

At 76,800 pixels per frame and ~80 FPS, that's 6.1 million pixel operations per second in pure Ruby.

### Optimization opportunity

Eliminating or reducing this function would nearly double FPS:
- **Best case**: Fix visplane coverage to have no gaps, remove the fill entirely
- **Pragmatic**: Only fill pixels not already covered by visplanes (skip tracking)
- **Quick win**: Reduce to a flat color fill instead of textured (removes the expensive per-pixel math)

## The #2 Bottleneck: draw_span (18.5%)

Same inner loop structure as the background fill, but only for marked visplane regions. Combined, flat rendering (fill + spans) accounts for **71.8%** of frame time. Wall rendering is only 7.4%.

This ratio matches DOOM's original performance profile -- floors and ceilings are the most expensive part because they require per-pixel texture mapping with perspective correction, while walls use per-column rendering (much fewer iterations).

## Allocations and GC

| Metric | Value |
|--------|-------|
| Allocations per frame | ~7,125 |
| Total (200 frames) | ~6.4M |
| GC % of frame time | 0.65% |

GC is not a bottleneck. The 7,125 allocations per frame come from:
- `Visplane.new` per unique floor/ceiling region (~100-200 per frame)
- `Drawseg.new` per visible wall segment (~50-100)
- Temporary arrays for visplane top/bottom marks
- `VisibleSprite.new` per visible thing

## Viewpoint Performance Variance

| View | YJIT (ms) | Interpreter (ms) | Ratio |
|------|-----------|-------------------|-------|
| Reverse (wall) | 8.49 | 23.56 | 2.78x |
| Hallway (corridor) | 10.32 | 27.05 | 2.62x |
| Corner (complex) | 12.10 | 30.63 | 2.53x |
| Spawn (default) | 12.35 | 31.04 | 2.51x |

YJIT's speedup is highest for simple views (2.78x for a flat wall) and lowest for complex views (2.51x for many sectors). This suggests the overhead being eliminated by YJIT is per-operation (method dispatch, type checks) rather than algorithmic -- the ratio is consistent regardless of scene complexity.
