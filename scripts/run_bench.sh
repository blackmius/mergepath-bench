#!/usr/bin/env bash
# Usage: scripts/run_bench.sh [N_per_array] [reps]   -> results/ (raw logs + all.csv + summary.md)
#
# Only the nimony compiler is external; its rows are built from
# src/bench_nimony.nim. Point NIMONY at the compiler if it is not on PATH or
# in ../nimony/bin:
#   NIMONY=/path/to/nimony/bin/nimony scripts/run_bench.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
N=${1:-10485760}; REPS=${2:-15}
mkdir -p bin results
nim c -o:bin/bench src/bench.nim
(cd go && go build -o ../bin/gobench .)

# ---- nimony: std/threadpool + .passive ----
# Only the compiler comes from its checkout; the implementation is
# `src/bench_nimony.nim` in this repository.
NIMONY=${NIMONY:-}
if [ -n "$NIMONY" ] && [ ! -x "$NIMONY" ] && command -v "$NIMONY" >/dev/null 2>&1; then
  NIMONY=$(command -v "$NIMONY")
fi
if [ -z "$NIMONY" ] && command -v nimony >/dev/null 2>&1; then
  NIMONY=$(command -v nimony)
fi
if [ -z "$NIMONY" ] && [ -x ../nimony/bin/nimony ]; then
  NIMONY=$(cd ../nimony && pwd)/bin/nimony
fi
NIMONY_BENCH=${NIMONY_BENCH:-src/bench_nimony.nim}
HAVE_NIMONY=0
if [ -n "$NIMONY" ] && [ -x "$NIMONY" ] && [ -f "$NIMONY_BENCH" ]; then
  NIMONY_BENCH=$(cd "$(dirname "$NIMONY_BENCH")" && pwd)/$(basename "$NIMONY_BENCH")
  echo "building nimony bench with $NIMONY"
  "$NIMONY" c -d:danger --nimcache:"$ROOT/bin/nimonycache" \
    -o:"$ROOT/bin/bench_nimony" "$NIMONY_BENCH"
  HAVE_NIMONY=1
else
  echo "nimony not found (set NIMONY=/path/to/nimony/bin/nimony); skipping nimony rows"
fi

NC=$(nproc)
{ lscpu; echo; free -m; uname -a; nim --version | head -1; go version; } > results/system.txt
if [ "$HAVE_NIMONY" = 1 ]; then
  { echo; "$NIMONY" --version 2>&1 | head -1; } >> results/system.txt
fi
THREADS=(1); for ((t=2; t<NC; t*=2)); do THREADS+=($t); done; [ "$NC" -gt 1 ] && THREADS+=($NC)
echo "cores=$NC sweep=${THREADS[*]}"
: > results/raw.log
for t in "${THREADS[@]}"; do
  ./bin/bench -n=$N -t=$t -r=$REPS      | tee -a results/raw.log
  ./bin/bench -n=$N -t=$t -r=$REPS -p   | tee -a results/raw.log
  if [ "$HAVE_NIMONY" = 1 ]; then
    ./bin/bench_nimony --n=$N --threads=$t --reps=$REPS | tee -a results/raw.log
    ./bin/bench_nimony --n=$N --threads=$t --reps=$REPS --prealloc | tee -a results/raw.log
  fi
  ./bin/gobench -x $N -y $N -t $t -r $REPS    | tee -a results/raw.log
  ./bin/gobench -x $N -y $N -t $t -r $REPS -p | tee -a results/raw.log
done
echo "impl,threads,mode,min_ms,median_ms" > results/all.csv
# `-f2-6` keeps nimony's extra digest column (field 7) out of the shared table.
grep '^CSV,' results/raw.log | cut -d, -f2-6 >> results/all.csv
python3 scripts/summarize.py results/all.csv $NC > results/summary.md
cat results/summary.md
