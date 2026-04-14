# Viewpoint Performance Analysis

DOOM's rendering cost varies dramatically by what the player sees.
Four viewpoints are benchmarked on E1M1 to measure this variance.

## Viewpoints

- **Spawn**: Player start position, facing the room ahead. Moderate complexity.
- **Hallway**: Rotated 90 degrees, looking down a long corridor. Fewer sectors.
- **Corner**: Rotated 45 degrees, looking at wall corners. Many wall segments.
- **Reverse**: Rotated 180 degrees, looking at a nearby wall. Minimal floor/ceiling.

## Results by Runtime

### Frame Time (ms)

| View | 3.3 Interp | 4.0 Interp | 4.0 YJIT | 4.1 ZJIT | TruffleRuby |
|------|-----------|-----------|----------|----------|-------------|
| Spawn | 31.04 | 29.22 | 12.27 | 23.72 | 2.43 |
| Hallway | 27.05 | 25.29 | 10.25 | 21.11 | 4.79 |
| Corner | 30.63 | 28.52 | 11.96 | 23.23 | 3.35 |
| Reverse | 23.56 | 21.94 | 8.60 | 19.03 | 5.88 |
| **Range** | **1.32x** | **1.33x** | **1.43x** | **1.25x** | **2.42x** |

### Equivalent FPS

| View | 3.3 Interp | 4.0 YJIT | 4.1 ZJIT | TruffleRuby |
|------|-----------|----------|----------|-------------|
| Spawn | 32.2 | 81.5 | 42.2 | 411.0 |
| Hallway | 37.0 | 97.5 | 47.4 | 208.8 |
| Corner | 32.6 | 83.6 | 43.0 | 298.8 |
| Reverse | 42.4 | 116.2 | 52.5 | 170.0 |

## Analysis

### Why "Reverse" is fastest on CRuby but slowest on TruffleRuby

On CRuby, the reverse view (looking at a nearby wall) is fastest because:
- Most of the screen is one wall = few wall columns to draw
- Very few floor/ceiling pixels visible = less fill_uncovered work
- Few visplanes = less draw_span work

On TruffleRuby, the reverse view is the SLOWEST. This is counterintuitive. The reason: TruffleRuby's JIT optimizes the floor/ceiling loops so aggressively that they become nearly free. With the loop bottleneck removed, other costs dominate (BSP traversal, wall column rendering), and these are similar across all views. The "easy" reverse view doesn't benefit as much from loop optimization because it didn't have many loops to optimize in the first place.

### Variance reveals the bottleneck

The range between fastest and slowest viewpoint tells us what dominates:

| Runtime | Range | Dominant Cost |
|---------|-------|--------------|
| CRuby (any) | 1.25-1.43x | Floor/ceiling fill (~53% of time) |
| TruffleRuby | 2.42x | BSP traversal and wall rendering |

CRuby's small variance (1.3x) means the background fill dominates regardless of view. TruffleRuby's large variance (2.4x) means it has eliminated the fill bottleneck and scene complexity now matters more.

### YJIT speedup by viewpoint

| View | YJIT Speedup (vs 4.0 interp) |
|------|-----|
| Reverse | 2.55x |
| Hallway | 2.47x |
| Corner | 2.38x |
| Spawn | 2.38x |

YJIT's speedup is remarkably consistent (2.38-2.55x), confirming that YJIT's gains come from per-operation overhead reduction (method dispatch, type guards) rather than algorithmic optimization. Every operation gets ~2.4x faster, regardless of how many operations there are.

### ZJIT speedup by viewpoint (4.1dev vs 4.0 interpreter)

| View | ZJIT Speedup |
|------|-----|
| Spawn | 1.23x |
| Hallway | 1.20x |
| Corner | 1.23x |
| Reverse | 1.15x |

ZJIT's speedup is also consistent but lower (1.15-1.23x). The gap to YJIT's 2.4x suggests ZJIT is compiling the code but not yet eliminating enough overhead per operation.
