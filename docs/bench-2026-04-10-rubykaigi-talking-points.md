# RubyKaigi Talking Points: DOOM Ruby Performance

## The One-Slide Summary

> A pure-Ruby DOOM renderer goes from 31 FPS (barely playable) to 82 FPS (smooth)
> with YJIT -- a 2.6x speedup with zero code changes. TruffleRuby hits 158 FPS,
> showing the theoretical ceiling. ZJIT is at 42 FPS and improving fast.

## Story Arc for a Talk

### 1. "Can Ruby run DOOM?" (Hook)

- 8,500 lines of pure Ruby, no C extensions for rendering
- BSP tree traversal, texture mapping, sprite clipping -- all in Ruby
- Every pixel computed in Ruby, 76,800 pixels per frame
- The answer: yes, but HOW FAST?

### 2. The Interpreter Baseline: 31 FPS

- Ruby 3.3: 31 FPS, borderline playable
- 32ms per frame, 53% spent in ONE function (floor/ceiling fill)
- 7,125 object allocations per frame, 233 GC pauses per 200 frames
- The hot loop: 6 multiplications, 3 array reads, 1 write -- per pixel

### 3. YJIT: Flip a Switch, Get 2.6x

- `ruby --yjit` or `RubyVM::YJIT.enable` -- no code changes
- 31 FPS -> 82 FPS instantly
- Same 53% in floor fill, but each operation is 2.4x faster
- YJIT eliminates: method dispatch, type guards, operand stack manipulation
- **Live demo**: press Y to toggle YJIT mid-game, watch FPS jump

### 4. ZJIT: The New Challenger

- SSA-based compiler, built from scratch in Rust
- Ruby 4.0: barely beats interpreter (35.6 vs 34.2 FPS)
- Ruby 4.1dev: 42.3 FPS -- 19% improvement in one release cycle
- Still 2x slower than YJIT, but the architecture enables optimizations YJIT can't do
- What ZJIT needs: Float unboxing, loop-invariant hoisting, array bounds elimination

### 5. TruffleRuby: The Theoretical Ceiling

- 158 FPS -- 5x faster than interpreter, 1.9x faster than YJIT
- Zero allocations per frame (escape analysis eliminates all Floats)
- Can't run the game interactively on macOS (thread model conflict)
- Shows what's possible: the Ruby LANGUAGE isn't the bottleneck, the IMPLEMENTATION is

### 6. What This Teaches Us About Ruby Performance

**The 53% problem**: One function consuming half the frame time. In C, this would be vectorized. In Ruby, it's 76,800 iterations of a method-call-heavy inner loop. JIT quality directly determines how fast this runs.

**Allocations matter less than you think**: 7,125 allocs/frame, GC is only 0.65% of time. Ruby's GC is fast. The bottleneck is execution speed, not memory management.

**YJIT's consistency is remarkable**: 2.4x speedup regardless of scene complexity. It's not optimizing algorithms -- it's optimizing the language runtime overhead that surrounds every operation.

**The Float unboxing gap**: CRuby allocates ~6,000 Float objects per frame for intermediate math. TruffleRuby allocates zero. This single optimization accounts for much of the 1.9x gap between YJIT and TruffleRuby.

## Key Numbers for Slides

| What | Number |
|------|--------|
| Lines of Ruby | 8,500 |
| Pixels per frame | 76,800 |
| Allocations per frame | 7,125 |
| GC % of frame time | 0.65% |
| YJIT speedup | 2.6x |
| ZJIT speedup (4.1dev) | 1.3x |
| TruffleRuby speedup | 5.1x |
| Floor fill % of frame | 53% |
| ZJIT improvement rate | 19% per release |
| Ruby 4.1dev GC reduction | 4x fewer pauses |

## Demo Ideas

1. **Live YJIT toggle**: Start without YJIT, press Y mid-game, FPS jumps from ~35 to ~80
2. **Difficulty comparison**: Baby mode (half damage) vs Nightmare -- show it's actually playable
3. **Screen melt**: The iconic DOOM wipe effect, implemented in pure Ruby
4. **Benchmark run**: Show the viewpoint comparison -- same scene, 4 angles, different FPS
5. **Profile flamegraph**: 53% in one function -- the visual is striking

## Potential Audience Questions

**Q: Why not use C extensions for the hot path?**
A: The whole point is to benchmark Ruby itself. If we escape to C for the hot loop, we're not measuring Ruby anymore. The game IS the benchmark.

**Q: Would frozen string literals help?**
A: Already enabled. String allocation isn't a factor -- it's Float allocation and method dispatch.

**Q: What about Ractors/parallelism?**
A: DOOM's renderer is inherently serial (front-to-back BSP order). Parallelizing visplane rendering across columns is theoretically possible but would add complexity that defeats the benchmarking purpose.

**Q: Will ZJIT catch YJIT?**
A: ZJIT's SSA architecture enables optimizations YJIT can't do (loop-invariant hoisting, escape analysis). If those are implemented, ZJIT could eventually surpass YJIT for this type of workload. The 19% per-release improvement rate is promising.
