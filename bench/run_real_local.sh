#!/usr/bin/env bash
set -u
ROOT="/Users/hasik/Projects/doom"; B="$HOME/.local/share/mise/installs/ruby"
OUT="$ROOT/bench_local/raw_real"; mkdir -p "$OUT"; cd "$ROOT" || exit 1
export WAD="$ROOT/doom1.wad"
CR3="$B/3.4.9/bin/ruby"; CR4="$B/4.0.6/bin/ruby"; TR="$B/truffleruby+graalvm-34.0.1/bin/ruby"
run(){ local label="$1"; local warm="$2"; shift 2; local runs="$1"; shift
  for k in $(seq 1 $runs); do WARMUP=$warm REPS=60 "$@" -Ilib bench/real_frame_bench.rb > "$OUT/${label}__run$k.txt" 2>>"$OUT/err.log"; done; echo "done $label"; }
run r34-base   20 3 "$CR3"
run r34-yjit   20 3 "$CR3" --yjit
run r40-base   20 3 "$CR4"
run r40-yjit   20 3 "$CR4" --yjit
run r40-zjit   20 3 "$CR4" --zjit
run truffle-cold 20  2 "$TR"
run truffle-warm 1500 2 "$TR"
run jruby-cold   20  2 jruby
run jruby-warm   1500 2 jruby
# spinel_native inside the REAL renderer
for k in 1 2 3; do SPINEL="$ROOT/../spin/spinel/bin/spinel" DOOM_NATIVE=1 WARMUP=20 REPS=60 "$CR4" -Ilib bench/real_frame_bench.rb > "$OUT/spinel_native__run$k.txt" 2>>"$OUT/err.log"; done; echo "done spinel_native"
echo "REAL_LOCAL_DONE"
