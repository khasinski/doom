# YJIT vs ZJIT: Benchmarking Ruby's JIT Compilers on a DOOM Renderer

A pure-Ruby software renderer for DOOM is one of the most demanding workloads you can throw at a Ruby runtime. Every pixel is computed on the CPU -- tens of thousands of floating-point operations, array accesses, and method calls per frame. This makes it an excellent test case for comparing Ruby's two JIT compilers.

All benchmarks were run on Ruby 4.0.1 (arm64-darwin), rendering 200 frames of E1M1 after 30 warmup frames.

## Results

### Frame Rendering Performance

| Metric | Interpreter | YJIT | ZJIT |
|--------|------------|------|------|
| **Avg frame time** | 28.12 ms | 11.80 ms | 27.16 ms |
| **Median** | 28.10 ms | 11.73 ms | 27.08 ms |
| **P95** | 28.92 ms | 12.13 ms | 27.65 ms |
| **P99** | 29.15 ms | 12.28 ms | 29.39 ms |
| **Min** | 27.37 ms | 11.43 ms | 26.68 ms |
| **Max** | 29.28 ms | 12.41 ms | 29.44 ms |
| **FPS** | **35.6** | **84.7** | **36.8** |
| **Speedup** | 1.0x | **2.38x** | **1.03x** |

### Viewpoint Comparison (FPS)

| Viewpoint | Interpreter | YJIT | ZJIT |
|-----------|------------|------|------|
| Spawn (default) | 36.2 | 84.8 | 37.4 |
| Hallway (90 deg) | 41.3 | 99.9 | 41.7 |
| Corner (45 deg) | 36.3 | 82.5 | 38.3 |
| Reverse (180 deg) | 47.5 | 121.8 | 47.2 |

### Component Breakdown

| Component | Interpreter | YJIT | ZJIT |
|-----------|------------|------|------|
| 3D render | 28.05 ms | 11.81 ms | 27.57 ms |
| Full + HUD | 29.01 ms | 12.84 ms | 28.03 ms |
| HUD overhead | 0.96 ms | 1.02 ms | 0.46 ms |

### GC Statistics

| Metric | Interpreter | YJIT | ZJIT |
|--------|------------|------|------|
| GC count | 136 | 130 | 138 |
| Allocs/frame | 6,671 | 6,755 | 6,755 |
| Total allocs | 6,053,275 | 6,113,837 | 6,111,630 |

## Analysis

### YJIT: 2.38x faster

YJIT delivers a dramatic speedup on this workload. The reasons are visible in YJIT's own runtime stats (collected with `--yjit-stats`):

**Near-zero side exits.** Only 2 side exits across 645 million compiled instructions. This means YJIT's type assumptions held almost perfectly throughout rendering -- the hot paths are completely monomorphic.

**C function inlining dominates.** 67.1% of C method calls were inlined by YJIT. The top C call is `Float#to_i` at 10.5 million calls (26.2% of all C calls), which is the texture coordinate conversion in the inner span-drawing loop. YJIT inlines this as a native `fcvtzs` (float-to-int) instruction instead of a full method dispatch.

**Hot method profile matches expectations.** The top ISEQ calls are exactly the hot paths identified in the renderer:

| Rank | Method | Calls/50 frames | Role |
|------|--------|-----------------|------|
| 1 | `transform_point` | 72,788 | View-space coordinate transform |
| 2 | `calculate_flat_light` | 59,340 | Distance-based lighting |
| 3 | `Visplane#mark` | 55,892 | Column marking for floor/ceiling |
| 4 | `draw_span` | 54,321 | Innermost floor/ceiling loop |
| 5 | `draw_wall_column_ex` | 44,300 | Per-column wall texture drawing |
| 6 | `calculate_light` | 36,770 | Wall distance lighting |
| 7 | `Texture#[]` | 36,250 | Texture data lookup |
| 8 | `column_pixels` | 36,199 | Texture column extraction |

YJIT compiles these methods into tight native code with direct struct-offset ivar access, inlined arithmetic, and minimal overhead.

### ZJIT: 1.03x faster (essentially interpreter speed)

ZJIT shows a marginal 3% improvement over the interpreter. This is consistent with its current maturity level -- ZJIT shipped in Ruby 4.0 as an experimental compiler, with the team explicitly stating that performance parity with YJIT is a Ruby 4.1 goal.

Interestingly, ZJIT shows an anomalous result in the HUD overhead: 0.46 ms vs the interpreter's 0.96 ms (2x faster). This suggests ZJIT may already be effective on the simpler, less loop-intensive HUD rendering code, even while the complex 3D renderer shows little benefit.

### Why the gap is so large

The performance gap comes down to what each JIT can optimize today:

**YJIT's advantages on this workload:**

1. **Lazy Basic Block Versioning.** YJIT specializes code paths on observed types as it compiles. For a renderer where every hot path operates on `Float`/`Integer` without variation, this produces optimally specialized native code with near-zero type-check overhead.

2. **C method inlining.** YJIT can inline common C-implemented methods (`Float#to_i`, `Integer#+`, `Float#*`, etc.) as single native instructions. The inner rendering loop calls `Float#to_i` roughly 60,000 times per frame -- eliminating method dispatch on each one accounts for a significant chunk of the 2.38x speedup.

3. **Inline caches.** With 0% polymorphic or megamorphic sends across 45 million method calls, YJIT's inline caches hit on every call in the hot path.

4. **Maturity.** YJIT has had 4+ years of development and production hardening (including deployment at Shopify scale). Its compilation heuristics are well-tuned.

**What ZJIT is missing (for now):**

1. **No general-purpose method inlining.** ZJIT cannot yet inline Ruby method calls like `transform_point`, `calculate_light`, or `draw_wall_column_ex`. Each of these is called tens of thousands of times per frame. Without inlining, the compiler can't see through call boundaries to optimize arithmetic chains.

2. **No loop optimizations.** The inner `while` loops in `draw_span` and `fill_uncovered_with_sector` run 20,000-30,000 iterations per frame. ZJIT doesn't yet perform loop-invariant code motion or loop unrolling.

3. **Limited intrinsics.** While ZJIT has DOMJIT-like support for some C methods, its coverage is narrower than YJIT's inline support for `Float#to_i`, arithmetic operators, and array access.

## Architectural Comparison

| Aspect | YJIT | ZJIT |
|--------|------|------|
| **Compilation unit** | Basic block (lazy) | Entire method |
| **IR** | Direct bytecode-to-machine-code | Two-tier: HIR (SSA) then LIR |
| **Type specialization** | Inline via LBBV | GuardType + specialized ops |
| **Method inlining** | Yes (C methods + some Ruby) | Limited (constants, self, params) |
| **Cross-instruction optimization** | Minimal | Constant/branch folding, DCE |
| **Escape analysis** | No | No |
| **Loop optimizations** | No | No |
| **Design goal** | Fast compilation, good enough code | Optimal code, extensible compiler |

ZJIT's architecture is more ambitious -- a proper SSA-based method compiler with multi-pass optimization. This is the kind of infrastructure that enables escape analysis, loop-invariant code motion, and aggressive inlining once implemented. YJIT's simpler approach produces good code faster but has a lower optimization ceiling.

## What ZJIT Could Do in the Future

For a software renderer, ZJIT's roadmap includes optimizations that would be transformative:

**Method inlining** would let ZJIT see through `transform_point` (2 multiplies + 2 multiply-adds) and inline it at each call site in `render_seg` and `check_bbox`. Instead of 72,788 method calls per 50 frames, the arithmetic would be woven directly into the caller.

**Loop-invariant code motion** would hoist per-loop constants (like `perp_dist`, `cmap`, `row_offset`) out of the while loop in `draw_span`, reducing redundant loads.

**Escape analysis** could eliminate the `[x, y]` Array allocation in `transform_point` (called 1,400+ times per frame), replacing it with scalar values in registers.

**Better register allocation** from the method-wide SSA view could keep the framebuffer pointer, column arrays, and player coordinates in registers across the entire span-drawing loop, instead of reloading them from Ruby's stack frame.

If ZJIT delivers on these, it could theoretically exceed YJIT's performance on numeric-heavy workloads. The SSA IR makes all of these optimizations structurally feasible in ways that YJIT's block-at-a-time model cannot easily support.

## How to Run These Benchmarks Yourself

```bash
# Interpreter baseline
ruby bench/benchmark.rb --run

# YJIT
ruby --yjit bench/benchmark.rb --run

# ZJIT
ruby --zjit bench/benchmark.rb --run

# YJIT with detailed stats
ruby --yjit --yjit-stats bench/benchmark.rb --run

# Side-by-side YJIT comparison (built into harness)
ruby bench/benchmark.rb --compare
```

Requires Ruby 4.0+ built with Rust 1.85+ for ZJIT support. Both JITs are compiled in by default but must be explicitly enabled at runtime.

## Conclusion

On this workload today, **YJIT is the clear choice** -- 2.38x faster than the interpreter, turning a 36 FPS slideshow into a smooth 85 FPS experience. ZJIT at 37 FPS is essentially running at interpreter speed, reflecting its early experimental status.

But ZJIT's architecture is built for a higher ceiling. A method-at-a-time SSA compiler with multi-pass optimization is the same foundation that makes JVMs and V8 fast. The question isn't whether ZJIT can eventually match YJIT on this workload -- it's whether it can surpass it. The rendering hot paths (tight numeric loops, monomorphic calls, no metaprogramming) are exactly the kind of code where a sufficiently smart optimizing compiler should excel.

For now, use YJIT. Keep an eye on ZJIT in Ruby 4.1.
