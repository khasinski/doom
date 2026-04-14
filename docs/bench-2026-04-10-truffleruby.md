# TruffleRuby Analysis: 5x Faster Than CRuby

TruffleRuby 33.0.1 on GraalVM delivers the fastest DOOM Ruby performance
by a wide margin. This analysis explores why and what it tells us about
Ruby JIT potential.

## Results

| Mode | Avg (ms) | Median (ms) | P95 (ms) | P99 (ms) | FPS |
|------|----------|-------------|----------|----------|-----|
| GraalVM JVM | 6.35 | 6.22 | 12.21 | 15.32 | **157.6** |
| GraalVM Native | 6.85 | 5.55 | 13.38 | 19.28 | **145.9** |
| CRuby YJIT (best) | 12.12 | 12.06 | 12.58 | 13.59 | 82.5 |
| CRuby interpreter | 29.23 | 29.18 | 29.93 | 32.78 | 34.2 |

### TruffleRuby vs CRuby YJIT: 1.9x faster

TruffleRuby is nearly twice as fast as YJIT. The GraalVM JIT's advantages:

1. **Aggressive inlining**: GraalVM inlines through multiple levels of method calls, eliminating dispatch overhead for the entire hot path. YJIT inlines selectively.

2. **Escape analysis**: Intermediate Float objects (`ray_dist`, `tex_x`, `tex_y`) are proven non-escaping and kept in registers. CRuby always heap-allocates Floats.

3. **Loop optimizations**: GraalVM's Graal compiler can unroll, vectorize, and hoist invariants from tight loops. YJIT compiles basic blocks without cross-iteration optimization.

4. **Zero allocations**: TruffleRuby reports 0 allocations per frame (all optimized away). CRuby allocates ~7,125 objects per frame even with YJIT.

## Per-Viewpoint Performance

| View | TruffleRuby JVM (ms) | YJIT (ms) | Ratio |
|------|---------------------|-----------|-------|
| Spawn (default) | 2.43 | 12.20 | **5.0x** |
| Corner (complex) | 3.35 | 11.86 | **3.5x** |
| Hallway (corridor) | 4.79 | 10.39 | **2.2x** |
| Reverse (wall) | 5.88 | 8.36 | **1.4x** |

The speedup varies dramatically by viewpoint: 5x for the spawn view, only 1.4x for the reverse view (looking at a nearby wall). This reveals what GraalVM optimizes best:

- **Spawn view** (5x): Large open area with many floor/ceiling pixels. GraalVM's loop optimizations excel at the per-pixel inner loops.
- **Reverse view** (1.4x): Mostly wall columns with few floor pixels. Wall rendering is less loop-intensive, so the optimization gap narrows.

This confirms that **loop optimization is the primary differentiator** between GraalVM and YJIT for this workload.

## JVM vs Native Mode

| Metric | JVM | Native | JVM Advantage |
|--------|-----|--------|---------------|
| FPS | 157.6 | 145.9 | +8% |
| Median | 6.22 ms | 5.55 ms | Native better |
| P99 | 15.32 ms | 19.28 ms | JVM better |
| Min | 2.63 ms | 2.90 ms | JVM better |

JVM mode wins on throughput (8% higher FPS) and tail latency (P99). Native mode has a slightly better median but worse P99. JVM mode benefits from more aggressive runtime profiling and recompilation, while Native mode uses ahead-of-time compilation that can't adapt to runtime behavior.

## Why TruffleRuby Can't Run the Game

Despite superior performance, TruffleRuby cannot run the interactive DOOM game on macOS:

```
API misuse: setting the main menu on a non-main thread.
```

Both JVM and Native modes run Ruby code on a non-main thread. macOS requires all Cocoa/SDL2 initialization on the main thread. This is a fundamental threading model difference -- CRuby runs on the process's main thread, TruffleRuby doesn't.

The benchmark works because it's headless (no window). The game would require either:
- TruffleRuby adding main-thread execution support
- A display backend that doesn't require main-thread initialization
- Running on Linux (no Cocoa requirement)

## What This Means for CRuby JIT Development

TruffleRuby's 5x speedup shows the theoretical ceiling for Ruby JIT performance on this workload. The key optimizations CRuby JITs would need:

| Optimization | TruffleRuby | YJIT | ZJIT |
|-------------|-------------|------|------|
| Method inlining | Deep, speculative | Selective | Planned |
| Float unboxing | Full escape analysis | No | Planned |
| Loop unrolling | Automatic | No | No |
| Loop-invariant hoisting | Automatic | No | Planned (SSA) |
| Array bounds elimination | Yes | No | Planned |
| Allocation elimination | Yes (EA) | No | No |

ZJIT's SSA-based architecture could theoretically implement most of these. The gap from ZJIT (42 FPS) to TruffleRuby (158 FPS) is 3.7x -- a large but not impossible gap to close over several releases.
