# mergepath-bench

Parallel **merge path** (merging two sorted arrays) in Nim on [nimcsp](https://github.com/ghazalialshafi/nimcsp) goroutines,
benchmarked against malebolgia and Go. Dependencies are vendored (nimcsp @ 343ac683fb, malebolgia @ 239dd8779d).

| path | what |
|---|---|
| `src/mpcore.nim` | diagonal binary search + branchless 2-chain merge kernel |
| `src/mp_csp.nim` | nimcsp implementation (`mergePathCsp`) |
| `src/bench.nim` | harness: edge-case correctness, your baseline, malebolgia (original + fast kernel), nimcsp port, nimcsp fast |
| `go/user.go` | your original Go functions, verbatim (+ `mergePathInto`, same code with caller-provided destination) |
| `go/fast.go` | Go port of the FAST design (fused splits, branchless 2-chain kernel; safe and `unsafe` variants), `go test` covers edge cases |
| `go/main.go` | Go repetition harness (`-p` = preallocated destination, GOMAXPROCS=t) |
| `.github/workflows/bench.yml` | CI sweep over thread counts up to the runner's core count |

Local run: `scripts/run_bench.sh [N] [reps]` (Nim 2.2.x, Go 1.22, x86-64 Linux). Output goes to `results/`.

Notes: nimcsp uses `cspInit(t+1)` (main thread blocks, t workers compute). The WaitGroup state is heap-allocated and freed only
after every goroutine exits, because `wgWait` can return before the last `wgDone` has finished touching the mutex.
Licenses of vendored code are kept in their directories.

## Patch applied to vendored nimcsp
`patches/0001-nimcsp-do-not-pin-threads-to-cpu0.patch` (already applied in `vendor/`): upstream `cspCoreInitMain` pins the main thread
to CPU 0 and the worker threads created afterwards inherit that mask, so all workers share one core. Verify on any machine with
`grep Cpus_allowed_list /proc/<pid>/task/*/status`.
