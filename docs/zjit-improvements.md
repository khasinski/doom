# ZJIT Improvements Log

Tracking ZJIT optimizations developed using the DOOM renderer benchmark.

## 1. Float arithmetic inlining (+, -, *, /)

**Branch:** `zjit-doom-analysis` in ruby/ruby
**Status:** Local, not submitted

### What changed

Added `FloatAdd`, `FloatSub`, `FloatMul`, `FloatDiv` HIR instructions to ZJIT.
These lower to `gen_prepare_leaf_call_with_gc` + direct ccall to `rb_float_plus` etc.,
skipping the full `CCallWithFrame` overhead (frame push/pop, stack spill, locals spill).

Key detail: guards use `types::Flonum` (cheap bitwise tag check) not `types::Float`
(expensive class load from memory). Initial implementation with `types::Float` caused
a 25% regression due to the cost of the class check in the inner loop.

### Files modified

- `zjit/src/hir.rs` -- 4 new Insn variants, effects, display, copy, type inference, verifier
- `zjit/src/codegen.rs` -- 4 gen functions, dispatch entries
- `zjit/src/cruby_methods.rs` -- `try_inline_float_op` helper, 4 inline functions, 4 annotations

### Benchmark results

DOOM renderer, 320x240, 200 frames, Apple Silicon, `--enable-zjit=dev`:

| Viewpoint | Baseline (ms) | Float inline (ms) | Change |
|-----------|--------------|-------------------|--------|
| spawn     | 35.44        | 33.52             | -5.4%  |
| hallway   | 30.89        | 30.17             | -2.3%  |
| corner    | 34.50        | 33.43             | -3.1%  |
| reverse   | 28.91        | 28.04             | -3.0%  |
| **FPS**   | **28.3**     | **29.8**          | **+5.3%** |

Spawn and corner (high floor/ceiling pixel count) gain more than reverse (low pixel count),
confirming the optimization targets the floor/ceiling rendering loop as expected.

### Lesson learned

`GuardType Float` (union of Flonum + HeapFloat) generates a full class check: test for
special constant, compare to Qfalse, load klass from object memory, compare to rb_cFloat.
That is 4 instructions + a memory dereference per guard. With 4 guards per pixel in the
inner loop, this caused 300K+ memory loads per frame and a net 25% regression.

Switching to `GuardType Flonum` uses a cheap bitwise tag check: `(val & 3) == 2`.
No memory access, single branch. Since most Ruby Floats are Flonum on 64-bit platforms,
the guard rarely fails.

---

## 2. Float#to_i inlining

**Branch:** `zjit-doom-analysis` in ruby/ruby
**Status:** Local, not submitted

### What changed

Added `FloatToInt` HIR instruction and `rb_jit_flo_to_i` C helper in `jit.c`
(wrapper for static `flo_to_i`). Truncates Float to Integer via
`gen_prepare_leaf_call_with_gc + ccall`, skipping CCallWithFrame.

### Files modified

- `jit.c` -- new `rb_jit_flo_to_i` helper
- `zjit/bindgen/src/main.rs` -- allowlist entry
- `zjit/src/cruby_bindings.inc.rs` -- function declaration
- `zjit/src/hir.rs` -- FloatToInt instruction
- `zjit/src/codegen.rs` -- gen_float_to_int
- `zjit/src/cruby_methods.rs` -- inline_float_to_i, annotations for to_i and to_int

### Cumulative benchmark results (release build, `--enable-zjit`)

| Runtime | FPS | vs Interpreter |
|---------|-----|----------------|
| Interpreter | 30.8 | 1.00x |
| ZJIT baseline | 40.5 | 1.32x |
| **ZJIT + all optimizations** | **44.5** | **1.44x (+10%)** |
| YJIT | 79.1 | 2.57x |

Dev build results (`--enable-zjit=dev`, with debug assertions):

| Viewpoint | Baseline (ms) | All optimizations (ms) | Change |
|-----------|--------------|----------------------|--------|
| spawn     | 35.44        | 33.13                | -6.5%  |
| hallway   | 30.89        | 29.70                | -3.9%  |
| corner    | 34.50        | 32.33                | -6.3%  |
| reverse   | 28.91        | 27.62                | -4.5%  |

---

## Remaining targets (from zjit-optimization-spec.md)

| Target | Expected impact | Status |
|--------|----------------|--------|
| Float#== annotation | ~1% | Low priority (preamble, not inner loop) |
| Float/Integer mixed ops | ~1% | Low priority (once per row) |
| Loop-invariant code motion | 5-10% | Needs ZJIT infrastructure |
| Float unboxing / scalar replacement | 15-25% | Needs ZJIT infrastructure |
| Array bounds check elimination | 5-10% | Needs ZJIT infrastructure |
