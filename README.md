# mergepath-bench

Parallel **merge path** (merging two sorted arrays) in Nim on [nimcsp](https://github.com/ghazalialshafi/nimcsp) goroutines,
benchmarked against malebolgia and Go. Dependencies are vendored (nimcsp, malebolgia @ 239dd8779d).

| path | what |
|---|---|
| `src/mpcore.nim` | diagonal binary search + branchless 2-chain merge kernel |
| `src/mp_csp.nim` | nimcsp implementation (`mergePathCsp`) |
| `src/bench.nim` | harness: edge-case correctness, your baseline, malebolgia (original + fast kernel), nimcsp port, nimcsp fast |
| `go/user.go` | your original Go functions, verbatim (+ `mergePathInto`, same code with caller-provided destination) |
| `go/fast.go` | Go port of the FAST design (fused splits, branchless 2-chain kernel; safe and `unsafe` variants), `go test` covers edge cases |
| `go/main.go` | Go repetition harness (`-p` = preallocated destination, GOMAXPROCS=t) |
| `src/bench_nimony.nim` | Nimony harness: the same merge-path kernels on `std/threadpool` + `.passive` tasks |

Local run: `scripts/run_bench.sh [N] [reps]` (Nim 2.2.x, Go 1.22, x86-64 Linux). Output goes to `results/`.

The script builds `src/bench_nimony.nim` and adds its rows when the nimony compiler is available. It
looks for `nimony` on `PATH` and then for `../nimony/bin/nimony`; override with
`NIMONY=/path/to/nimony/bin/nimony`. If no compiler is found, the Nim and Go rows still run.

Notes: nimcsp uses `cspInit(t+1)` (main thread blocks, t workers compute). The WaitGroup state is heap-allocated and freed only
after every goroutine exits, because `wgWait` can return before the last `wgDone` has finished touching the mutex.
The nimony rows use the same partition strategies as the Nim FAST rows, but submit `.passive` tasks with
`submit(delay(...))` and join on a condition variable.

nimcsp's context switch is hand-written x86-64 assembly, so its rows are built only on `amd64`
(`when defined(amd64)` in `src/bench.nim`). On other hosts the baseline, 2-chain and malebolgia rows still run,
and the nimony rows are unaffected. The vendored `usleep` call now converts to its declared `Useconds`
type, which is `cuint` on amd64 but `int` on aarch64, so the monitor source itself is also type-correct there.
Licenses of vendored code are kept in their directories.
