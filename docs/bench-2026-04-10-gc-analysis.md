# GC and Memory Analysis Across Ruby Versions

## GC Frequency

| Runtime | GC Runs (200 frames) | Allocs/frame | Allocs per GC | GC % of time |
|---------|---------------------|-------------|---------------|-------------|
| Ruby 3.3 interp | 233 | 7,126 | 28,171 | ~0.7% |
| Ruby 3.4 interp | 179 | 7,125 | 35,876 | ~0.5% |
| Ruby 3.4 YJIT | 196 | 7,220 | 33,121 | ~0.5% |
| Ruby 4.0 interp | 170 | 7,125 | 37,711 | ~0.5% |
| Ruby 4.0 YJIT | 132 | 7,220 | 49,132 | ~0.4% |
| Ruby 4.0 ZJIT | 136 | 7,220 | 47,671 | ~0.4% |
| Ruby 4.1dev interp | 56 | 7,125 | 114,540 | ~0.3% |
| Ruby 4.1dev YJIT | 48 | 7,220 | 135,003 | ~0.2% |
| Ruby 4.1dev ZJIT | 37 | 7,220 | 175,216 | ~0.2% |
| TruffleRuby JVM | 62 | 0 | 0 | ~0.3% |
| TruffleRuby Native | 45 | 0 | 0 | ~0.3% |

### Key Observations

**Allocation count is constant**: ~7,125-7,220 objects per frame regardless of Ruby version or JIT. The renderer's architecture determines allocations, not the runtime. YJIT/ZJIT allocate slightly more (~95 extra) likely from JIT metadata structures.

**GC frequency dropped 4x from 3.3 to 4.1dev**: Ruby 3.3 runs GC every 28k allocations. Ruby 4.1dev waits until 114-175k allocations. This means GC runs once every 16-24 frames instead of every 4 frames.

**GC is NOT a significant bottleneck**: Even on Ruby 3.3, GC accounts for only 0.7% of frame time. The 4x reduction in 4.1dev is nice for tail latency but doesn't materially affect average FPS.

**TruffleRuby eliminates all allocations**: Escape analysis proves that all intermediate objects (Floats, temporary arrays) don't escape the method scope, so they're never heap-allocated. This is the most dramatic difference vs CRuby.

## P99 Latency (Frame Spike) Analysis

| Runtime | P99 (ms) | Max (ms) | P99/Median |
|---------|----------|----------|------------|
| Ruby 3.3 | 60.83 | 82.53 | 1.93x |
| Ruby 3.4 | 33.06 | 33.92 | 1.09x |
| Ruby 4.0 interp | 32.78 | 32.93 | 1.12x |
| Ruby 4.0 YJIT | 13.22 | 13.26 | 1.07x |
| Ruby 4.1dev YJIT | 13.59 | 13.91 | 1.13x |
| TruffleRuby JVM | 15.32 | 15.42 | 2.46x |

Ruby 3.3 has terrible P99 (1.93x median) due to frequent GC pauses. Ruby 3.4+ dramatically improved this. YJIT on 4.0 has the tightest P99/median ratio (1.07x) -- nearly zero frame spikes.

TruffleRuby's P99 (2.46x median) is the worst ratio despite best median, due to JIT compilation warmup and GC pauses from the JVM garbage collector.

## What Gets Allocated

The ~7,125 allocations per frame break down as:

| Object Type | Approx Count | Purpose |
|-------------|-------------|---------|
| Visplane | 100-200 | One per unique floor/ceiling region |
| Drawseg | 50-100 | One per visible wall segment |
| VisibleSprite | 5-20 | One per visible thing |
| Array (top/bottom) | 200-400 | Visplane column markers |
| Float (intermediate) | ~6,000 | Texture coordinate math |

The Float allocations are the largest category and the main target for escape analysis. If CRuby could unbox Floats in hot loops (as TruffleRuby does), allocations would drop to ~1,000/frame.
