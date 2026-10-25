import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]))); cores = sys.argv[2]
print(f"## Merge-path benchmark ({cores} cores) — min of N runs, ms (lower is better)\n")
for mode in ("alloc", "prealloc"):
    sub = [r for r in rows if r["mode"] == mode]
    if not sub: continue
    ths = sorted({int(r["threads"]) for r in sub}); impls = list(dict.fromkeys(r["impl"] for r in sub))
    d = {(r["impl"], int(r["threads"])): float(r["min_ms"]) for r in sub}
    print(f"### dst {'allocation included' if mode=='alloc' else 'preallocated (merge only)'}\n")
    print("| implementation | " + " | ".join(f"t={t}" for t in ths) + " |")
    print("|---|" + "---:|" * len(ths))
    for i in impls:
        print(f"| {i} | " + " | ".join(f"{d[(i,t)]:.1f}" if (i,t) in d else "-" for t in ths) + " |")
    base = "seq (user baseline)"
    if (base, ths[0]) in d:
        print(f"\nSpeedup vs `{base}` at t={ths[0]}:\n")
        print("| implementation | " + " | ".join(f"t={t}" for t in ths) + " |"); print("|---|" + "---:|" * len(ths))
        for i in impls:
            print(f"| {i} | " + " | ".join(f"{d[(base,ths[0])]/d[(i,t)]:.2f}x" if (i,t) in d else "-" for t in ths) + " |")
    print()
print("_Go rows use GOMAXPROCS=t. \"(user)\" rows run the original algorithm; \"FAST\" rows use fused splits + branchless 2-chain kernel (same design as the Nim FAST). In the preallocated table, Go (user) rows use mergePathInto = original mergePath with caller-provided destination. `seq-*` / `pool-*` rows are the nimony build, using std/threadpool + .passive tasks._")
