#!/usr/bin/env bash
# Usage: scripts/run_bench.sh [N_per_array] [reps]   -> results/ (raw logs + all.csv + summary.md)
set -euo pipefail
cd "$(dirname "$0")/.."
N=${1:-10485760}; REPS=${2:-15}
mkdir -p bin results
nim c -o:bin/bench src/bench.nim
(cd go && go build -o ../bin/gobench .)
NC=$(nproc)
{ lscpu; echo; free -m; uname -a; nim --version | head -1; go version; } > results/system.txt
THREADS=(1); for ((t=2; t<NC; t*=2)); do THREADS+=($t); done; [ "$NC" -gt 1 ] && THREADS+=($NC)
echo "cores=$NC sweep=${THREADS[*]}"
: > results/raw.log
for t in "${THREADS[@]}"; do
  ./bin/bench -n=$N -t=$t -r=$REPS      | tee -a results/raw.log
  ./bin/bench -n=$N -t=$t -r=$REPS -p   | tee -a results/raw.log
  ./bin/gobench -x $N -y $N -t $t -r $REPS    | tee -a results/raw.log
  ./bin/gobench -x $N -y $N -t $t -r $REPS -p | tee -a results/raw.log
done
echo "impl,threads,mode,min_ms,median_ms" > results/all.csv
grep '^CSV,' results/raw.log | cut -d, -f2- >> results/all.csv
python3 scripts/summarize.py results/all.csv $NC > results/summary.md
cat results/summary.md
