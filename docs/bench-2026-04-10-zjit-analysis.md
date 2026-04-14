# ZJIT Progress Analysis: From 4.0 to 4.1dev

ZJIT is Ruby's new SSA-based JIT compiler, built from scratch as an alternative to YJIT.
This analysis tracks its progress using DOOM Ruby as a real-world benchmark.

## Results

| Metric | Ruby 4.0 ZJIT | Ruby 4.1dev ZJIT | Change |
|--------|---------------|-------------------|--------|
| Avg frame time | 28.12 ms | 23.65 ms | **-15.9%** |
| Median | 27.97 ms | 23.49 ms | -16.0% |
| FPS | 35.6 | 42.3 | **+18.8%** |
| P99 | 32.57 ms | 27.39 ms | -15.9% |
| vs Interpreter | 1.04x | 1.30x | -- |
| vs YJIT | 0.44x | 0.51x | -- |

### Per-Viewpoint Breakdown

| View | 4.0 ZJIT (ms) | 4.1dev ZJIT (ms) | Improvement |
|------|---------------|-------------------|-------------|
| Spawn | 28.17 | 23.72 | -15.8% |
| Hallway | 24.50 | 21.11 | -13.8% |
| Corner | 27.64 | 23.23 | -16.0% |
| Reverse | 22.03 | 19.03 | -13.6% |

Improvement is consistent across all viewpoints (13.6-16.0%), suggesting ZJIT's gains come from better compilation of the common hot paths rather than specific optimizations for certain code patterns.

## ZJIT vs YJIT Gap

| Metric | ZJIT 4.1dev | YJIT 4.1dev | Gap |
|--------|-------------|-------------|-----|
| FPS | 42.3 | 82.5 | 1.95x |
| Median | 23.49 ms | 12.06 ms | 1.95x |
| P99 | 27.39 ms | 13.59 ms | 2.01x |

ZJIT is currently ~2x slower than YJIT. The gap is consistent (1.95-2.01x) which suggests a systemic difference in code generation quality rather than a single missing optimization.

### What ZJIT Likely Needs

DOOM Ruby's hot path is a tight numeric loop:
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

For this to run fast, the JIT needs:
1. **Array bounds check elimination** -- `column_distscale[x]`, `column_cos[x]`, etc. are guaranteed in-bounds
2. **Float unboxing** -- avoid heap-allocating Float objects for intermediate results
3. **Loop-invariant code motion** -- `perp_dist`, `row_offset`, `cmap` don't change within the loop
4. **Inlining `.to_i`** -- this is 5.3% of frame time as a method call
5. **Integer specialization** -- `x += 1` and `& 63` should compile to single instructions

YJIT handles most of these through its trace-based approach. ZJIT's SSA framework can theoretically do even better (it can prove loop invariants), but the implementation isn't there yet.

## ZJIT Trajectory

| Release | FPS | vs Interpreter | vs YJIT |
|---------|-----|----------------|---------|
| Ruby 4.0 (March 2026) | 35.6 | 1.04x | 0.44x |
| Ruby 4.1dev (April 2026) | 42.3 | 1.30x | 0.51x |
| Projected 4.1 release | ~50? | ~1.5x? | ~0.6x? |

If ZJIT maintains its current improvement rate (~19% per release), it could reach 60% of YJIT's speed by the Ruby 4.1 release. Reaching parity would require the loop optimizations listed above.

## GC Behavior Under ZJIT

| Runtime | GC Runs | Allocs/GC |
|---------|---------|-----------|
| 4.0 ZJIT | 136 | 47,671 |
| 4.1dev ZJIT | 37 | 175,216 |

Ruby 4.1dev's GC runs 3.7x less frequently under ZJIT. This is likely a Ruby VM improvement (not ZJIT-specific) since the interpreter shows the same pattern. Fewer GC pauses contribute to ZJIT's tighter P99 (27.39ms vs 32.57ms).
