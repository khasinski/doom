# Performance Profiling a Software DOOM Renderer in Ruby

This document covers how to profile and optimize a pure-Ruby software renderer that implements DOOM's BSP-based rendering pipeline, and how Ruby's YJIT compiler transforms its performance characteristics.

## Architecture Overview

This DOOM port is a 4,000-line pure-Ruby software renderer. Every pixel is computed on the CPU -- there is no GPU acceleration. The renderer faithfully reimplements id Software's original rendering pipeline:

1. **BSP traversal** -- front-to-back walk of the binary space partition tree
2. **Wall rendering** -- per-column texture-mapped walls with near-plane clipping
3. **Visplane rendering** -- horizontal spans for floors and ceilings
4. **Sprite rendering** -- sorted back-to-front with drawseg clipping

The framebuffer is a flat `Array` of 76,800 integers (320x200), scaled 3x to 960x720 for display via the Gosu library (SDL2). This means every frame involves tens of thousands of Ruby method calls, array accesses, and floating-point operations -- making it an excellent stress test for Ruby runtime performance.

## The Benchmark Harness

The project includes a headless benchmark (`bench/benchmark.rb`) that exercises the renderer without a window:

```bash
# Baseline (interpreted)
ruby bench/benchmark.rb

# With YJIT
ruby --yjit bench/benchmark.rb

# Side-by-side comparison
ruby bench/benchmark.rb --compare

# CPU profiling with StackProf
ruby bench/benchmark.rb --profile
```

The harness measures:

| Metric | Purpose |
|--------|---------|
| Avg/Median/P95/P99 frame time | Central tendency and tail latency |
| Min/Max | Jitter bounds |
| FPS | Throughput |
| Allocs/frame | GC pressure |
| Component breakdown | 3D render vs. HUD overhead |
| Viewpoint variance | Scene complexity sensitivity (4 angles) |
| GC stats | Collection count, heap pages, total allocations |

The viewpoint tests are important: a hallway view draws many more wall columns and visplane spans than an open area, so a single angle gives an incomplete picture.

## Identifying Hot Paths

### Where the time goes

In a typical E1M1 frame, the call tree looks roughly like this:

```
render_frame
 |-- fill_uncovered_with_sector   ~30-40%   (background floor/ceiling)
 |-- render_bsp_node              ~5%       (tree walk + point_on_side)
 |   |-- render_subsector
 |   |   |-- render_seg
 |   |       |-- draw_seg_range   ~20-25%   (per-column wall texturing)
 |-- draw_all_visplanes           ~15-20%   (floor/ceiling spans)
 |   |-- draw_span                          (innermost span loop)
 |-- render_sprites               ~5-10%    (sprite clipping + drawing)
 |-- clear/reset                  ~2-3%     (Array#fill)
```

The two dominant costs are **flat (floor/ceiling) rendering** and **wall column drawing**. Both are inner loops that execute per-pixel arithmetic.

### The innermost loop: `draw_span`

This is the single hottest method in the renderer. For each horizontal pixel span on a floor or ceiling:

```ruby
while x <= x2
  ray_dist = perp_dist * column_distscale[x]
  tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
  tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
  color = flat_pixels[tex_y * 64 + tex_x]
  framebuffer[row_offset + x] = cmap[color]
  x += 1
end
```

Each iteration performs:
- 1 multiply (`perp_dist * distscale`)
- 2 multiply-adds (texture coordinate computation)
- 2 float-to-int conversions (`.to_i`)
- 2 bitwise ANDs (`& 63` for power-of-2 texture wrapping)
- 3 array reads (`column_distscale`, `column_cos`/`sin`, `flat_pixels`, `cmap`)
- 1 array write (`framebuffer[...] =`)

At 320x120 half-screen of floor alone, this loop body executes ~38,400 times per frame. With walls partially occluding the view, a realistic count is 20,000-30,000 iterations.

### Wall column drawing: `draw_seg_range`

For each visible wall column, the renderer computes a ray-segment intersection using precomputed coefficients:

```
s = (E * x + F) / (A * x + B)
```

This avoids per-column trigonometry but still requires a division per column. The method then draws a vertical strip with per-pixel colormap lookups for distance-based lighting.

### BSP traversal

The BSP walk itself is cheap (E1M1 has ~250 nodes), but `check_bbox` is called for every back-child and involves transforming 4 corners plus a column-range occlusion check. The `while` loop in `check_bbox` is a minor but measurable cost because it runs against the clipping arrays.

## Profiling with StackProf

StackProf (wall-clock mode) gives the clearest picture of where time is spent:

```bash
ruby bench/benchmark.rb --profile
stackprof bench/profile_*.dump --text --limit 30
```

Key flags to use:

```bash
# Flamegraph (best for understanding call structure)
stackprof bench/profile_*.dump --flamegraph > flame.json
stackprof --flamegraph-viewer flame.json

# Method-level breakdown
stackprof bench/profile_*.dump --text --limit 30

# Per-line annotation of a hot method
stackprof bench/profile_*.dump --method 'Doom::Render::Renderer#draw_span'
```

The `--method` view is particularly valuable for this codebase because the hot methods are long (50-100 lines) with localized hotspots. Line-level profiles reveal whether time is in array indexing, float arithmetic, or method dispatch.

### What to look for

1. **Method call overhead** -- Ruby method dispatch is expensive in the interpreter. Inlining (caching instance variables as locals) is a major optimization.
2. **Object allocation** -- Every `Hash`, `Array.new`, or implicit boxing creates GC pressure. The `allocs_per_frame` metric from the benchmark catches regressions.
3. **Float vs Integer paths** -- Ruby's `Fixnum` arithmetic is faster than `Float`. Texture coordinates use `.to_i & 63` to stay in integer land for array indexing.
4. **Iterator overhead** -- `(x1..x2).each` allocates a Range and dispatches a block. The renderer uses `while` loops in all hot paths to avoid this.

## Optimization History

The commit log documents a systematic optimization pass. Each change was benchmarked before merging:

| Commit | Optimization | Mechanism |
|--------|-------------|-----------|
| `992842c` | Cache column data when angle unchanged | Skip 320 `atan2`+`sin`+`cos` calls on stationary frames |
| `6cdd227` | Hash-based visplane lookup | O(1) find-or-create vs O(n) linear scan |
| `6271e48` | Reuse sprite clip arrays | Avoid `Array.new(320)` allocations per frame |
| `f07b576` | Bitwise AND for texture wrap | `& 63` vs `% 64` in innermost loops |
| `2ef58e4` | Struct for VisibleSprite | Fixed-field access vs Hash key lookup |
| `68f55bb` | Preallocate y_slope arrays | Remove per-frame allocation of 120-element arrays |
| `2ef8d23` | Remove nil checks from inner loops | Eliminate branches in per-pixel code |
| `c720c50` | Cache texture columns, inline flat lookups | Reduce method dispatch in column drawing |

The cumulative effect was a 62% frame rate improvement (`53fb874`).

### Pattern: local variable caching

The single most impactful micro-optimization is caching instance variables as method-local variables before entering a hot loop:

```ruby
def draw_span(plane, y, x1, x2)
  # Cache all instance vars as locals -- eliminates ivar lookup per iteration
  framebuffer = @framebuffer
  column_distscale = @column_distscale
  column_cos = @column_cos
  column_sin = @column_sin
  player_x = @player_x
  # ...
  while x <= x2
    # All access here is to local variables, not @ivars
  end
end
```

In CRuby's interpreter, `@ivar` access requires a hash lookup on the object. Local variables are stack slots. In a loop that runs 30,000 times, this difference is measurable. YJIT eliminates most of this gap (see below), but the pattern remains beneficial.

## How YJIT Changes the Picture

### What YJIT is

YJIT (Yet Another JIT for Ruby) is CRuby's built-in JIT compiler, available since Ruby 3.1 and production-ready from Ruby 3.2+. It uses lazy basic block versioning to compile Ruby bytecode into native machine code at runtime. Unlike method-level JITs, YJIT compiles individual basic blocks on first execution, specializing on observed types.

This project enables YJIT at startup:

```ruby
# bin/doom
if defined?(RubyVM::YJIT) && RubyVM::YJIT.respond_to?(:enable)
  RubyVM::YJIT.enable
end
```

### Why YJIT helps this workload

A DOOM software renderer is an almost ideal YJIT workload:

1. **Tight numeric loops** -- The inner loops are dominated by `Float` multiply/add and `Integer` bitwise ops. YJIT inlines these as native FPU/ALU instructions, eliminating the interpreter dispatch overhead per operation.

2. **Monomorphic call sites** -- The hot methods call `Array#[]`, `Array#[]=`, `.to_i`, and arithmetic operators on the same types every time. YJIT's inline caches hit nearly 100% after warmup.

3. **Instance variable access** -- YJIT compiles `@ivar` reads as direct struct offset loads (a single `mov` instruction) instead of the interpreter's hash-table lookup. This partially eliminates the need for the local-variable-caching pattern, though locals are still marginally faster.

4. **Predictable branches** -- BSP traversal decisions, clipping comparisons, and loop bounds are all based on numeric comparisons that YJIT compiles to native `cmp`/`jcc` sequences.

5. **No megamorphic dispatch** -- The renderer doesn't use metaprogramming, `method_missing`, or polymorphic dispatch in hot paths. Every call site resolves to exactly one method.

### What YJIT does NOT help

- **Algorithmic complexity** -- YJIT makes each operation faster but doesn't change the O(n) span drawing or O(k) visplane splitting. A poorly-chosen data structure is still slow.
- **GC pressure** -- YJIT doesn't reduce object allocations. If you create 10,000 temporary arrays per frame, you still pay for GC. The allocation-reduction optimizations (preallocated arrays, Struct over Hash) matter just as much with YJIT.
- **Gosu/SDL overhead** -- The pixel data transfer from Ruby arrays to the SDL surface happens outside YJIT's reach. This is a constant cost regardless of JIT.
- **Cache locality** -- Ruby arrays are arrays of tagged `VALUE` pointers, not contiguous floats. YJIT can't restructure memory layout. The framebuffer, colormap lookups, and texture pixel arrays all suffer from pointer-chasing.

### Expected speedup

For this renderer, YJIT typically delivers **1.5-2.5x speedup** on frame rendering time. The benchmark's `--compare` mode measures this directly:

```bash
ruby bench/benchmark.rb --compare
```

The speedup varies by scene complexity:
- **Simple scenes** (few visible walls, large floor spans): Higher speedup because the inner loop dominates and YJIT's numeric optimizations have maximum effect.
- **Complex scenes** (many short wall segments, lots of visplane splits): Lower speedup because more time is spent in object-heavy code (Struct allocation, Array creation for new visplanes).

### YJIT-specific profiling

To see what YJIT is actually compiling:

```bash
# Compile stats at exit
ruby --yjit --yjit-stats bench/benchmark.rb --run

# Key metrics to watch:
#   yjit_insns_count  -- total compiled instructions
#   ratio_in_yjit     -- fraction of time in JIT'd code (aim for >95%)
#   side_exit_count    -- how often YJIT fell back to interpreter
#   invalidation_count -- how often compiled code was thrown away
```

A high `ratio_in_yjit` (>95%) confirms the hot paths are being compiled. Side exits indicate type instability -- if you see many side exits in `draw_span`, check whether any variable is sometimes `nil` or an unexpected type.

### YJIT warmup

YJIT compiles lazily on first execution of each basic block. The benchmark harness runs 30 warmup frames specifically to ensure all hot paths are compiled before measurement begins. For the game itself, the first 0.5-1 second of gameplay serves as implicit warmup.

You can observe warmup by plotting per-frame times: interpreted frames are 2-3x slower, then times plateau once YJIT has compiled the hot loops.

## Advanced Profiling Techniques

### Allocation profiling

High allocation rates cause GC pauses that manifest as frame time spikes (high P99). Profile allocations with:

```bash
# Using allocation_tracer gem
ruby -r allocation_tracer -e '
  ObjectSpace::AllocationTracer.setup(%i[path line type])
  ObjectSpace::AllocationTracer.trace do
    # run benchmark frames
  end
  ObjectSpace::AllocationTracer.result.sort_by { |k,v| -v[0] }.first(20).each { |k,v| p [k,v] }
'
```

Or use the benchmark's built-in `allocs_per_frame` metric. A well-optimized frame should allocate fewer than 500 objects. The major sources of per-frame allocations in this renderer:

- `Visplane.new` -- one per unique (height, texture, light, ceiling) tuple
- `Drawseg.new` -- one per visible wall segment
- `VisibleSprite.new` -- one per visible thing
- `Array.new` inside Visplane (top/bottom arrays, 320 elements each)

These are structural allocations that can't be eliminated without a pooling strategy.

### GC tuning

For real-time rendering, GC pauses are the primary source of frame time jitter. Two environment variables help:

```bash
# Increase heap size to reduce collection frequency
RUBY_GC_HEAP_INIT_SLOTS=100000 ruby --yjit bin/doom

# Disable compaction (reduces pause duration at cost of fragmentation)
# Ruby 3.2+
```

The benchmark reports GC count -- if this is high relative to frame count, allocations are too aggressive.

### Flame graphs

For a visual overview of where time is spent across the full call tree:

```bash
# Generate with stackprof
ruby bench/benchmark.rb --profile
stackprof --d3-flamegraph bench/profile_*.dump > flamegraph.html
open flamegraph.html
```

Flame graphs make it immediately obvious when an unexpected method dominates. They're particularly useful for catching cases where `Math.atan2` or `Math.sqrt` appears higher than expected (indicating a caching opportunity).

### Comparing optimization impact

The benchmark's `--compare` mode runs the same workload with and without YJIT, but you can also A/B test individual optimizations:

```bash
# On a branch with the change:
ruby --yjit bench/benchmark.rb --run > after.txt

# On main:
git stash && ruby --yjit bench/benchmark.rb --run > before.txt && git stash pop

# Compare
diff before.txt after.txt
```

For reliable results, run 3-5 iterations and compare medians, not averages. Frame time distributions have long tails from GC and OS scheduling.

## The Limits of Ruby for Real-Time Rendering

Even with YJIT and careful optimization, this renderer faces fundamental constraints:

1. **No SIMD** -- C DOOM uses fixed-point integer math that modern compilers auto-vectorize. Ruby has no SIMD path. Each texture coordinate computation is scalar.

2. **Tagged value overhead** -- Every `Integer` and `Float` in Ruby is a tagged pointer (or in YJIT, sometimes an unboxed register value, but re-boxed on any escape). The innermost loop operates on values that are conceptually `u8` palette indices but are full Ruby `Integer` objects in memory.

3. **No stack allocation** -- The `[x, y]` return from `transform_point` allocates a heap Array. In C, this would be two registers.

4. **Method dispatch** -- Even with YJIT's inline caches, `Array#[]` is not literally a pointer dereference. There's a bounds check and type guard.

These constraints make a 10-20 FPS Ruby renderer roughly equivalent to a 200+ FPS C renderer in terms of algorithmic work. The achievement is getting it playable at all -- and YJIT is a large part of what makes that possible.

## Quick Reference

```bash
# Run the game
ruby bin/doom                              # YJIT auto-enabled

# Benchmark
ruby bench/benchmark.rb                    # without YJIT
ruby --yjit bench/benchmark.rb             # with YJIT
ruby bench/benchmark.rb --compare          # side-by-side

# Profile
ruby --yjit bench/benchmark.rb --profile   # generate StackProf dump
stackprof bench/profile_*.dump --text      # top methods
stackprof bench/profile_*.dump --method 'Renderer#draw_span'  # per-line

# YJIT diagnostics
ruby --yjit --yjit-stats bench/benchmark.rb --run
```
