# ZJIT Optimization Targets: DOOM Ruby Benchmark

This document describes specific ZJIT optimization opportunities identified by profiling a pure-Ruby DOOM renderer. The benchmark is a real-world, numeric-heavy workload that exercises tight loops, Float arithmetic, and Array access patterns. It is designed to be used as a guide for improving ZJIT's code generation.

## The Benchmark

**Repository:** `github.com/khasinski/doom`

### How to run

```bash
git clone https://github.com/khasinski/doom.git
cd doom
# You need doom1.wad (shareware, free) -- the game will offer to download it
bundle install

# Run benchmark (headless, no window needed)
ruby --zjit bench/benchmark.rb --run

# Compare with YJIT
ruby --yjit bench/benchmark.rb --run

# CPU profile (requires stackprof gem)
gem install stackprof
ruby --yjit bench/benchmark.rb --profile
```

### What it measures

The benchmark renders 200 frames of DOOM's E1M1 map at 320x240 (76,800 pixels per frame). No window is created -- it runs entirely in memory. Each frame is a full BSP rendering cycle: tree traversal, wall projection, floor/ceiling texture mapping, sprite clipping, and HUD overlay.

Timing uses `Process.clock_gettime(Process::CLOCK_MONOTONIC)` per frame, after 30 warmup frames and a forced GC.

### Current results (April 2026, Apple Silicon)

| Runtime | FPS | vs Interpreter |
|---------|-----|----------------|
| Ruby 4.0 interpreter | 34.2 | 1.00x |
| Ruby 4.0 ZJIT | 35.6 | 1.04x |
| Ruby 4.1-dev ZJIT | 42.3 | 1.24x |
| Ruby 4.0 YJIT | 80.8 | 2.36x |
| Ruby 4.1-dev YJIT | 82.5 | 2.41x |

ZJIT is currently ~2x slower than YJIT on this workload. The gap is consistent across all viewpoints, suggesting systemic code generation differences rather than a single missing optimization.

---

## The Hot Path

53% of frame time is spent in one function: `fill_uncovered_with_sector` (lib/doom/render/renderer.rb, around line 560). Another 18% is in `draw_span` which has an identical inner loop structure. Together, floor/ceiling rendering is 71% of the frame.

The critical inner loop:

```ruby
while x < SCREEN_WIDTH           # SCREEN_WIDTH = 320 (constant)
  ray_dist = perp_dist * column_distscale[x]
  tex_x = (player_x + ray_dist * column_cos[x]).to_i & 63
  tex_y = (neg_player_y - ray_dist * column_sin[x]).to_i & 63
  color = flat_pixels[tex_y * 64 + tex_x]
  framebuffer[row_offset + x] = cmap[color]
  x += 1
end
```

This loop runs ~76,800 times per frame (once per pixel). At 80 FPS (YJIT speed) that is 6.1 million iterations per second. Every operation in this loop matters.

### Variable types (stable, monomorphic)

| Variable | Type | Notes |
|----------|------|-------|
| `x` | Integer | Loop counter, 0..319 |
| `SCREEN_WIDTH` | Integer | Constant 320 |
| `perp_dist` | Float | Computed once per row, invariant within inner loop |
| `column_distscale` | Array[Float] | Length 320, invariant across frames |
| `column_cos` | Array[Float] | Length 320, invariant across frames |
| `column_sin` | Array[Float] | Length 320, invariant across frames |
| `player_x` | Float | Invariant within inner loop |
| `neg_player_y` | Float | Invariant within inner loop |
| `ray_dist` | Float | Intermediate, does not escape loop |
| `tex_x` | Integer | Intermediate, does not escape loop |
| `tex_y` | Integer | Intermediate, does not escape loop |
| `flat_pixels` | Array[Integer] | Length 4096 (64x64 texture), invariant |
| `framebuffer` | Array[Integer] | Length 76800 (320x240), output |
| `cmap` | Array[Integer] | Length 256 (colormap), invariant within inner loop |
| `row_offset` | Integer | Invariant within inner loop |
| `color` | Integer | 0..255 |

All types are stable and monomorphic. There are no polymorphic call sites, no blocks, no exceptions, no string operations.

---

## Optimization Targets (ordered by expected impact)

### 1. Float unboxing / scalar replacement

**Current cost:** ~5.3% of frame time in `Float#to_i` alone, plus allocation overhead for every intermediate Float.

**The problem:** `ray_dist`, the product of `perp_dist * column_distscale[x]`, is a new heap-allocated Float object every iteration. So are the results of `player_x + ray_dist * column_cos[x]` and `neg_player_y - ray_dist * column_sin[x]`. That is 5 Float allocations per pixel, ~384,000 per frame.

**What YJIT does:** YJIT does NOT unbox Floats. It still allocates them on the heap. But YJIT's allocation path is faster than the interpreter's.

**What TruffleRuby does:** GraalVM's escape analysis proves these Floats do not escape the loop body and keeps them entirely in FP registers. TruffleRuby reports 0 allocations per frame. This is the single biggest reason TruffleRuby is 1.9x faster than YJIT.

**What ZJIT could do:** Since ZJIT has an SSA IR, it can prove that `ray_dist`, `tex_x_float`, `tex_y_float` are local to the loop body. They are assigned once and consumed immediately. A scalar replacement pass could keep them in registers.

**Expected impact:** Eliminating 384,000 Float allocations per frame. Estimated 15-25% speedup.

### 2. Loop-invariant code motion (LICM)

**The problem:** Several values are recomputed or re-fetched on every iteration but do not change:
- `perp_dist` -- computed once per row (outer loop), invariant in inner loop
- `player_x`, `neg_player_y` -- invariant for entire frame
- `row_offset` -- invariant within inner loop
- `cmap` -- invariant within inner loop
- Array object pointers for `column_distscale`, `column_cos`, `column_sin`, `flat_pixels`, `framebuffer`

**What should happen:** LICM should hoist all invariant loads (including Ruby object header checks, array capacity checks) out of the inner loop. The loop body should only contain the arithmetic and array element accesses.

**Expected impact:** Fewer redundant loads per iteration. Estimated 5-10% speedup.

### 3. Array bounds check elimination

**The problem:** Every `array[index]` in Ruby performs a bounds check. In this loop:
- `column_distscale[x]` -- x is 0..319, array length is 320. Always in bounds.
- `column_cos[x]` -- same.
- `column_sin[x]` -- same.
- `flat_pixels[tex_y * 64 + tex_x]` -- tex_x and tex_y are masked with `& 63`, so the index is 0..4095. Array length is 4096. Always in bounds.
- `framebuffer[row_offset + x]` -- row_offset is `y * 320`, x is 0..319. Always in bounds for a 76800-element array.
- `cmap[color]` -- color comes from flat_pixels which contains values 0..255. cmap length is 256. Always in bounds.

**What ZJIT could do:** With SSA, ZJIT can prove that `x` ranges from 0 to SCREEN_WIDTH-1 (the loop guard is `x < SCREEN_WIDTH`). Combined with knowing array lengths are constant (they are not resized within the loop), all bounds checks can be eliminated.

**Expected impact:** 6 fewer branches per iteration. Estimated 5-10% speedup.

### 4. Inlining `Float#to_i`

**Current cost:** 5.3% of self time in the StackProf profile.

**The problem:** `.to_i` is called twice per pixel (for tex_x and tex_y). Each call goes through Ruby method dispatch: check receiver type, look up method, call C function `flo_to_i`, allocate Integer result.

**What should happen:** For a Float receiver, `.to_i` should compile to a single `fcvtzs` (ARM) or `cvttsd2si` (x86) instruction. No method dispatch, no C call.

**Expected impact:** Eliminating 153,600 method dispatches per frame. Estimated 3-5% speedup.

### 5. Integer operation specialization

**The problem:** `x += 1`, `& 63`, `* 64`, `+ tex_x` are all Integer operations that go through Ruby's generic dispatch. For known-Integer operands (which ZJIT can prove via SSA type inference), these should compile to single machine instructions.

**What to check:** Verify that `x += 1` compiles to `add x, x, #1` (ARM) without a method call or overflow check (x is bounded by the loop guard, max value 319, well within Fixnum range).

**Expected impact:** Modest but cumulative. Estimated 2-5% speedup.

### 6. Constant folding for `SCREEN_WIDTH`

**The problem:** `SCREEN_WIDTH` is a Ruby constant (320). The loop guard `x < SCREEN_WIDTH` should compile to `cmp x, #320` without loading the constant from Ruby's constant table on every iteration.

**What to check:** Is the constant resolved at compile time or looked up at runtime?

**Expected impact:** Small but easy. Estimated 1-2% speedup.

---

## How to Verify Improvements

After making changes to ZJIT, run:

```bash
# Quick check
ruby --zjit bench/benchmark.rb --run

# Compare with baseline
ruby bench/benchmark.rb --run          # interpreter
ruby --yjit bench/benchmark.rb --run   # YJIT

# Detailed per-viewpoint comparison
# The benchmark outputs 4 viewpoints (spawn, hallway, corner, reverse)
# If your optimization targets loops, "spawn" and "corner" should
# improve more than "reverse" (which has fewer floor pixels)
```

### What "good" looks like

| Optimization | Measurable signal |
|-------------|-------------------|
| Float unboxing | Allocs/frame drops from ~7,200 to ~1,200 |
| LICM | Uniform improvement across all viewpoints |
| Bounds elimination | Small uniform improvement |
| to_i inlining | `Float#to_i` disappears from StackProf profile |
| Integer specialization | Modest uniform improvement |

### Viewpoint sensitivity

The four viewpoints have different floor-to-wall ratios:

| Viewpoint | Floor/ceiling pixels | Expected sensitivity to loop opts |
|-----------|---------------------|----------------------------------|
| spawn | High | High |
| corner | High | High |
| hallway | Medium | Medium |
| reverse | Low | Low |

If your optimization targets the floor/ceiling loop, "spawn" FPS should improve more than "reverse" FPS. If the improvement is uniform across all viewpoints, the optimization is likely hitting a different code path (BSP traversal, wall rendering).

---

## Other Hot Paths (lower priority)

### `draw_span` (18.5% of frame time)

Same inner loop structure as `fill_uncovered_with_sector`. All optimizations above apply equally. Located in renderer.rb around line 379.

### `draw_wall_column_ex` (2.2% of frame time)

Vertical column drawing for walls. Different loop structure (iterates over Y, not X). Less impactful because wall rendering is a smaller fraction of frame time. Located in renderer.rb around line 1193.

### `render_visplane_spans` (4.4% of frame time)

Iterates over visplane columns to build horizontal spans. Mostly array access and comparison operations. Located in renderer.rb around line 300.

---

## Contact

For questions about the benchmark or to discuss findings: github.com/khasinski/doom/issues
