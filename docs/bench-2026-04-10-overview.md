# DOOM Ruby Performance Benchmarks -- April 2026

Benchmarked on Apple Silicon (M-series Mac), E1M1, 200 frames after 30-frame warmup.
Rendering only (no window/display overhead). All numbers are frame times.

## Summary Table

| Runtime | Avg (ms) | Median (ms) | P95 (ms) | P99 (ms) | FPS | vs 3.3 |
|---------|----------|-------------|----------|----------|-----|--------|
| Ruby 3.3 interpreter | 32.41 | 31.52 | 35.04 | 60.83 | **30.9** | 1.00x |
| Ruby 3.4 interpreter | 30.38 | 30.32 | 31.08 | 33.06 | **32.9** | 1.06x |
| Ruby 4.0 interpreter | 29.23 | 29.18 | 29.93 | 32.78 | **34.2** | 1.11x |
| Ruby 4.1dev interpreter | 30.87 | 30.75 | 31.88 | 33.20 | **32.4** | 1.05x |
| Ruby 4.0 ZJIT | 28.12 | 27.97 | 29.36 | 32.57 | **35.6** | 1.15x |
| Ruby 4.1dev ZJIT | 23.65 | 23.49 | 24.56 | 27.39 | **42.3** | 1.37x |
| Ruby 3.4 YJIT | 12.23 | 12.19 | 12.63 | 12.85 | **81.8** | 2.65x |
| Ruby 4.0 YJIT | 12.38 | 12.32 | 13.09 | 13.22 | **80.8** | 2.61x |
| Ruby 4.1dev YJIT | 12.12 | 12.06 | 12.58 | 13.59 | **82.5** | 2.67x |
| TruffleRuby 33 (JVM) | 6.35 | 6.22 | 12.21 | 15.32 | **157.6** | 5.10x |
| TruffleRuby 33 (Native) | 6.85 | 5.55 | 13.38 | 19.28 | **145.9** | 4.72x |

## Key Findings

### 1. YJIT delivers consistent 2.6x across all Ruby versions

YJIT performance is remarkably stable: 81-82 FPS whether on Ruby 3.4, 4.0, or 4.1dev. The JIT has matured to the point where the Ruby version doesn't matter -- the compiled machine code is equally efficient. Median frame times cluster tightly around 12.1-12.3ms.

### 2. ZJIT is improving fast: 19% gain from 4.0 to 4.1dev

| ZJIT Version | FPS | Avg (ms) | vs Interpreter |
|-------------|-----|----------|----------------|
| Ruby 4.0 | 35.6 | 28.12 | 1.04x |
| Ruby 4.1dev | 42.3 | 23.65 | 1.30x |

ZJIT went from barely beating the interpreter (4%) to a meaningful 30% speedup. At 42 FPS it's now playable, though still half of YJIT's speed. The gap is closing.

### 3. TruffleRuby dominates at 5x

TruffleRuby (GraalVM JVM mode) hits 157.6 FPS -- 5.1x faster than CRuby interpreter, 1.9x faster than YJIT. The GraalVM JIT's aggressive inlining, escape analysis, and loop vectorization are perfectly suited to this numeric-heavy workload. The JVM mode edges out Native mode (157 vs 146 FPS) due to more aggressive runtime optimization.

The tradeoff: higher tail latency (P99=15ms vs YJIT's 13ms) from JIT compilation warmup, and inability to run the interactive game on macOS (thread model conflict with SDL2/Cocoa).

### 4. Interpreter has plateaued

CRuby interpreter performance barely moves: 30.9 to 34.2 FPS across four versions (3.3 to 4.0). The 10% improvement from 3.3 to 4.0 is mostly from reduced GC pressure, not faster execution.

### 5. Ruby 4.1dev dramatically reduces GC pressure

| Runtime | GC Runs | Allocs per GC |
|---------|---------|---------------|
| Ruby 3.3 | 233 | 28,171 |
| Ruby 4.0 | 132-170 | 37,711-49,132 |
| Ruby 4.1dev | 37-56 | 114,540-175,216 |

Ruby 4.1dev runs GC 4x less frequently than 3.3, collecting 4-6x more objects per cycle. This explains the tighter P99 latencies -- fewer GC pauses means fewer frame spikes.
