## Merge-path benchmark (4 cores) — min of N runs, ms (lower is better)

### dst allocation included

| implementation | t=1 | t=2 | t=4 |
|---|---:|---:|---:|
| seq (user baseline) | 69.7 | 68.8 | 72.2 |
| seq 2-chain kernel | 38.3 | 39.0 | 40.1 |
| malebolgia (user) | 68.5 | 35.8 | 20.4 |
| malebolgia + fast | 37.1 | 18.3 | 11.1 |
| seq-branchy | 53.6 | 54.1 | 55.1 |
| seq-2chain | 20.5 | 21.0 | 21.4 |
| pool-branchy | 53.6 | 28.2 | 15.8 |
| pool-fast | 20.6 | 11.0 | 6.3 |
| pool-fast-x4 | 20.8 | 10.9 | 6.5 |
| go seq (user) | 63.3 | 64.0 | 65.3 |
| go mergePath (user) | 58.6 | 30.8 | 17.2 |
| go seq 2-chain kernel | 24.6 | 24.7 | 24.8 |
| go FAST (safe) | 24.0 | 13.3 | 7.5 |
| go FAST (unsafe) | 22.5 | 12.5 | 7.2 |
| go FAST x4 parts (unsafe) | 22.7 | 12.5 | 7.1 |

Speedup vs `seq (user baseline)` at t=1:

| implementation | t=1 | t=2 | t=4 |
|---|---:|---:|---:|
| seq (user baseline) | 1.00x | 1.01x | 0.97x |
| seq 2-chain kernel | 1.82x | 1.79x | 1.74x |
| malebolgia (user) | 1.02x | 1.95x | 3.41x |
| malebolgia + fast | 1.88x | 3.81x | 6.25x |
| seq-branchy | 1.30x | 1.29x | 1.27x |
| seq-2chain | 3.40x | 3.32x | 3.26x |
| pool-branchy | 1.30x | 2.47x | 4.42x |
| pool-fast | 3.38x | 6.33x | 10.98x |
| pool-fast-x4 | 3.36x | 6.39x | 10.77x |
| go seq (user) | 1.10x | 1.09x | 1.07x |
| go mergePath (user) | 1.19x | 2.26x | 4.05x |
| go seq 2-chain kernel | 2.84x | 2.82x | 2.81x |
| go FAST (safe) | 2.90x | 5.25x | 9.27x |
| go FAST (unsafe) | 3.10x | 5.57x | 9.62x |
| go FAST x4 parts (unsafe) | 3.07x | 5.58x | 9.82x |

### dst preallocated (merge only)

| implementation | t=1 | t=2 | t=4 |
|---|---:|---:|---:|
| seq (user baseline) | 53.2 | 54.4 | 55.4 |
| seq 2-chain kernel | 20.2 | 20.5 | 20.3 |
| malebolgia (user) | 53.6 | 27.4 | 15.1 |
| malebolgia + fast | 19.9 | 10.5 | 5.9 |
| seq-branchy | 53.3 | 54.1 | 55.1 |
| seq-2chain | 20.4 | 20.9 | 20.9 |
| pool-branchy | 54.0 | 28.2 | 16.0 |
| pool-fast | 21.3 | 11.3 | 6.3 |
| pool-fast-x4 | 20.8 | 10.9 | 6.2 |
| go seq (user) | 57.6 | 59.0 | 59.0 |
| go mergePath (user) | 57.2 | 29.7 | 16.3 |
| go seq 2-chain kernel | 22.8 | 23.5 | 22.9 |
| go FAST (safe) | 22.7 | 12.0 | 6.3 |
| go FAST (unsafe) | 21.6 | 11.2 | 6.0 |
| go FAST x4 parts (unsafe) | 21.2 | 11.4 | 5.9 |

Speedup vs `seq (user baseline)` at t=1:

| implementation | t=1 | t=2 | t=4 |
|---|---:|---:|---:|
| seq (user baseline) | 1.00x | 0.98x | 0.96x |
| seq 2-chain kernel | 2.63x | 2.60x | 2.61x |
| malebolgia (user) | 0.99x | 1.94x | 3.53x |
| malebolgia + fast | 2.67x | 5.04x | 9.08x |
| seq-branchy | 1.00x | 0.98x | 0.96x |
| seq-2chain | 2.61x | 2.54x | 2.54x |
| pool-branchy | 0.98x | 1.89x | 3.33x |
| pool-fast | 2.50x | 4.71x | 8.41x |
| pool-fast-x4 | 2.55x | 4.86x | 8.54x |
| go seq (user) | 0.92x | 0.90x | 0.90x |
| go mergePath (user) | 0.93x | 1.79x | 3.26x |
| go seq 2-chain kernel | 2.33x | 2.26x | 2.33x |
| go FAST (safe) | 2.34x | 4.43x | 8.38x |
| go FAST (unsafe) | 2.46x | 4.76x | 8.87x |
| go FAST x4 parts (unsafe) | 2.50x | 4.65x | 8.97x |

_Go rows use GOMAXPROCS=t. "(user)" rows run the original algorithm; "FAST" rows use fused splits + branchless 2-chain kernel (same design as the Nim FAST). In the preallocated table, Go (user) rows use mergePathInto = original mergePath with caller-provided destination. `seq-*` / `pool-*` rows are the nimony build, using std/threadpool + .passive tasks._
