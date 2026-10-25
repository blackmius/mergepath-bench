## mergepath -- merge two sorted arrays with merge-path partitioning, on
## Nimony's `std/threadpool`.
##
## This is the Nimony build of the same benchmark (the other implementations
## live in `src/bench.nim` and `go/`). The concurrency runtime is swapped:
## `malebolgia`/`nimcsp` goroutines are replaced by Nimony's process-wide
## `std/threadpool` worker pool and `.passive` tasks. The point of the port is
## to exercise the pool's `delay`/`submit` path on a short, CPU-bound,
## fork-join workload -- a handful of submissions and one join per merge --
## rather than on the I/O-shaped work `std/threadpool` usually sees.
##
## Two partitioning strategies are measured, the same pair the original bench
## compares:
##
## * `pool-branchy` finds every split in a serial phase, then each worker merges
##   its slice with the textbook two-pointer loop.
## * `pool-fast` lets every worker find its *own* two split points and merges
##   with the branchless two-chain kernel (`kTwo`). There is no serial split
##   phase and no barrier between "find splits" and "merge".
##
## The sequential `seq-*` rows are controls: they say what the same kernels cost
## without the pool, so the pool's overhead is visible rather than inferred.
##
## Every result is checked against the sequential merge before it is timed.
## `-d:benchSmoke` shrinks the problem and prints only a fixed word, which is
## what a build-and-smoke check wants; the checks still run, so a broken kernel
## or a pool that loses a task fails that run rather than merely producing a
## different number.
##
## Usage::
##
##   mergepath [options]
##
##   --n:N          elements per input array (default 10485760)
##   --threads:N    worker-pool threads and merge partitions (default 4)
##   --reps:N       timed runs per benchmark, min and median reported (default 9)
##   --prealloc     allocate and pre-fault the destination outside the timer
##   --only:SUBSTR  run only benchmarks whose name contains SUBSTR
##   --list         print the benchmark names and exit
##
## Run it with::
##
##   nimony c -d:danger -r src/bench_nimony.nim --n:10485760 --threads:4
##
## Build with `-d:danger` when the numbers matter: the kernels read through
## `ptr UncheckedArray` and the harness keeps checks on in a normal build.

import std / [syncio, monotimes, parseopt, strutils, threadpool, locks,
            random, algorithm]

{.feature: "lenientnils".}  # `inputPtr` returns nil for an empty input

const
  smoke = defined(benchSmoke)
    ## A build-and-smoke check compiles this file with `-d:benchSmoke`: the
    ## question there is whether the workload still builds and still produces
    ## the same result, not how long it takes.

  DefaultN = when smoke: 8192 else: 10 * 1024 * 1024
  DefaultThreads = when smoke: 2 else: 4
  DefaultReps = when smoke: 1 else: 9
  WarmupRuns = 2   ## untimed runs before the measured ones

# ---- merge-path kernels ---------------------------------------------------

type
  P = ptr UncheckedArray[int]

template off(p: P; n: int): P =
  cast[P](cast[uint](p) + uint(n) * uint(sizeof(int)))

template mstep(a, b, dst: P; i, j, k: untyped) =
  let av = a[i]
  let bv = b[j]
  let takeA = av <= bv            # '<=' : a wins ties, so the merge is stable
  dst[k] = (if takeA: av else: bv)
  i += int(takeA)
  j += 1 - int(takeA)
  inc k

proc diagSplit(a, b: P; alen, blen, d: int): int =
  ## Number of elements among the first `d` outputs of the stable merge that
  ## come from `a`: the smallest x in [max(0, d-blen), min(d, alen)] with
  ## `a[x] > b[d-x-1]` (with a[alen] = +inf, b[-1] = -inf). Inside the loop
  ## `mid < alen`, `mid < d` and `d-mid-1` in [0, blen), so every access is in
  ## range even for an empty input.
  var lo = max(0, d - blen)
  var hi = min(d, alen)
  while lo < hi:
    let mid = (lo + hi) shr 1
    if a[mid] > b[d - mid - 1]: hi = mid
    else: lo = mid + 1
  lo

proc kOne(a, b: P; i0, ex, j0, ey: int; dst: P) =
  ## Single branchless merge chain. Runs `min(remaining_a, remaining_b)` steps
  ## at a time, so the hot loop needs no bounds test.
  var i = i0
  var j = j0
  var k = 0
  while i < ex and j < ey:
    let n = min(ex - i, ey - j)
    for _ in 0 ..< n:
      mstep(a, b, dst, i, j, k)
  while i < ex:
    dst[k] = a[i]
    inc i
    inc k
  while j < ey:
    dst[k] = b[j]
    inc j
    inc k

proc kTwo(a, b: P; i0, ex, j0, ey: int; dst: P) =
  ## Two independent merge chains, the halves of the output interleaved. One
  ## chain is latency-bound (the next load address depends on the previous
  ## compare); two chains give the CPU something to overlap it with.
  let n = (ex - i0) + (ey - j0)
  let h = n shr 1
  let mx = i0 + diagSplit(off(a, i0), off(b, j0), ex - i0, ey - j0, h)
  let my = j0 + h - (mx - i0)
  var iL = i0
  var jL = j0
  var kL = 0
  var iR = mx
  var jR = my
  var kR = h
  while true:
    let m = min(min(mx - iL, my - jL), min(ex - iR, ey - jR))
    if m <= 0: break
    for _ in 0 ..< m:
      mstep(a, b, dst, iL, jL, kL)
      mstep(a, b, dst, iR, jR, kR)
  kOne(a, b, iL, mx, jL, my, off(dst, kL))
  kOne(a, b, iR, ex, jR, ey, off(dst, kR))

proc mergePart(a, b, dst: P; alen, blen, idx, parts: int) =
  ## Merge exactly partition `idx` of `parts`, finding its own split points so
  ## there is no serial phase before the workers start.
  let total = alen + blen
  let d0 = idx * total div parts
  let d1 = (idx + 1) * total div parts
  let x0 = diagSplit(a, b, alen, blen, d0)
  let x1 = diagSplit(a, b, alen, blen, d1)
  kTwo(a, b, x0, x1, d0 - x0, d1 - x1, off(dst, d0))

# ---- the baseline: serial split phase, branchy kernel ---------------------

proc seqMerge(a, b: P; alen, blen: int; dst: P) =
  ## The original branchy two-pointer merge, used both as the `seq-branchy`
  ## control and as the reference every other implementation is checked against.
  var i = 0
  var j = 0
  var k = 0
  while i < alen and j < blen:
    if a[i] <= b[j]:
      dst[k] = a[i]
      inc i
    else:
      dst[k] = b[j]
      inc j
    inc k
  while i < alen:
    dst[k] = a[i]
    inc i
    inc k
  while j < blen:
    dst[k] = b[j]
    inc j
    inc k

proc findSplits(a, b: P; alen, blen, parts: int; splits: P) =
  ## One binary search per diagonal, in the calling thread. Two ints per
  ## partition; the last pair is the end of the input.
  let total = alen + blen
  for core in 0 ..< parts:
    let diag = core * total div parts
    var lo = max(0, diag - blen)
    var hi = min(diag, alen)
    while lo <= hi:
      let x = (lo + hi) shr 1
      let y = diag - x
      if x < alen and y > 0 and a[x] < b[y - 1]:
        lo = x + 1
      elif x > 0 and y < blen and a[x - 1] > b[y]:
        hi = x - 1
      else:
        splits[core * 2] = x
        splits[core * 2 + 1] = y
        break
  splits[parts * 2] = alen
  splits[parts * 2 + 1] = blen

proc branchyPart(a, b, splits, dst: P; alen, blen, idx, parts: int) =
  ## Merge partition `idx` from the precomputed split table.
  let sx = splits[idx * 2]
  let sy = splits[idx * 2 + 1]
  let ex = splits[(idx + 1) * 2]
  let ey = splits[(idx + 1) * 2 + 1]
  var i = sx
  var j = sy
  var k = idx * (alen + blen) div parts
  while i < ex and j < ey:
    if a[i] <= b[j]:
      dst[k] = a[i]
      inc i
    else:
      dst[k] = b[j]
      inc j
    inc k
  while i < ex:
    dst[k] = a[i]
    inc i
    inc k
  while j < ey:
    dst[k] = b[j]
    inc j
    inc k

# ---- the thread pool implementation ---------------------------------------

var
  doneLock: Lock
  doneCond: Cond
  completed: int
    ## Finished `.passive` tasks, guarded by `doneLock`.

proc markDone() =
  acquire(doneLock)
  inc completed
  signal(doneCond)
  release(doneLock)

proc awaitTasks(count: int) =
  ## Wait for `count` tasks on the condition variable. Deliberately no
  ## `poolHelp`: draining the queue on the joining thread would trampoline the
  ## very partitions we just submitted, one after another, and the "parallel"
  ## rows would measure a serial merge. Blocking rather than spinning also
  ## leaves the core to the workers instead of stealing one from them.
  acquire(doneLock)
  while completed < count:
    wait(doneCond, doneLock)
  completed = 0
  release(doneLock)

proc branchyTask(a, b, splits, dst: P; alen, blen, idx, parts: int) {.passive.} =
  ## One worker for the serial-split design. The split table is read-only here
  ## and outlives the task because the joiner waits for every task before the
  ## table's owner can drop it.
  branchyPart(a, b, splits, dst, alen, blen, idx, parts)
  markDone()

proc fastTask(a, b, dst: P; alen, blen, idx, parts: int) {.passive.} =
  ## One self-partitioning worker: it finds its own splits and merges.
  mergePart(a, b, dst, alen, blen, idx, parts)
  markDone()

proc mergePathPool(a, b, dst: P; alen, blen, parts: int) =
  ## Submit one `.passive` task per partition and wait for all of them.
  for i in 0 ..< parts:
    # Spread the batch over the pool's stripes. Without the hint every task
    # lands on the submitting thread's stripe (0), and one worker's bulk
    # dequeue can take the whole batch and run it serially.
    submit(delay(fastTask(a, b, dst, alen, blen, i, parts)), i)
  awaitTasks(parts)

proc mergePathPoolBranchy(a, b, dst: P; alen, blen, parts: int) =
  ## The faithful port of the baseline: splits are found serially, then the
  ## workers only merge. The split table is allocated per call, inside the
  ## timer, exactly like the original port.
  let splits = newSeqUninit[int](parts * 2 + 2)
  let sp = cast[P](addr splits[0])
  findSplits(a, b, alen, blen, parts, sp)
  for i in 0 ..< parts:
    submit(delay(branchyTask(a, b, sp, dst, alen, blen, i, parts)), i)
  awaitTasks(parts)

proc inputPtr(s: seq[int]): P =
  ## `nil` for an empty seq: the kernels never dereference it, but taking
  ## `addr s[0]` on an empty seq would still be a bug.
  if s.len > 0: cast[P](unsafeAddr s[0]) else: nil

proc mergePathPoolSeq(a, b: seq[int]; parts: int): seq[int] =
  ## Convenience wrapper for the edge-case checks.
  result = newSeqUninit[int](a.len + b.len)
  if result.len == 0: return
  mergePathPool(inputPtr(a), inputPtr(b), cast[P](addr result[0]),
                a.len, b.len, parts)

# ---- harness --------------------------------------------------------------

type
  Impl = enum
    SeqBranchy, SeqTwo, PoolBranchy, PoolFast, PoolFastX4

const
  AllImpls = [SeqBranchy, SeqTwo, PoolBranchy, PoolFast, PoolFastX4]

proc implName(kind: Impl): string =
  result =
    case kind
    of SeqBranchy: "seq-branchy"
    of SeqTwo: "seq-2chain"
    of PoolBranchy: "pool-branchy"
    of PoolFast: "pool-fast"
    of PoolFastX4: "pool-fast-x4"

proc wanted(name, only: string): bool =
  only.len == 0 or find(name, only) >= 0

proc sameInts(a, b: seq[int]): bool =
  ## `equalMem` by another name: `cmpMem` is the qword/byte comparison the
  ## runtime already needs, and a per-element loop over 20M ints would add
  ## more than the merge itself.
  if a.len != b.len: return false
  if a.len == 0: return true
  result = cmpMem(unsafeAddr a[0], unsafeAddr b[0], a.len * sizeof(int)) == 0

proc digestOf(s: seq[int]): int64 =
  ## FNV-1a over the values, so two builds can compare their whole arrays with
  ## one printed integer.
  var h = 0xcbf29ce484222325'u64
  for x in s:
    h = (h xor uint64(x)) * 0x100000001b3'u64
  result = int64(h)

proc millis3(ns: int64): string =
  ## `ns` as milliseconds with three decimals, integer arithmetic only:
  ## `formatFloat` bottoms out in libc's `snprintf`, and a libc-free
  ## `nimony n` image has no libc to link it from.
  let us = ns div 1000
  let whole = us div 1000
  let frac = us mod 1000
  result = $whole & "." &
           (if frac < 100: "0" else: "") &
           (if frac < 10: "0" else: "") & $frac

proc pad(s: string; w: int): string = s & repeat(' ', max(1, w - s.len))

var
  gN = DefaultN
  gThreads = DefaultThreads
  gReps = DefaultReps
  gPrealloc = false
  gOnly = ""
  gA: seq[int]
  gB: seq[int]
  gRef: seq[int]

proc run(kind: Impl; parts, reps: int; prealloc: bool): int64 =
  ## Run one implementation `WarmupRuns` times untimed, then `reps` times
  ## measured. Every run is compared against `gRef` before it counts.
  var times = newSeq[int64]()
  result = 0
  let total = gN * 2
  for r in 0 ..< WarmupRuns + reps:
    var dst = newSeqUninit[int](0)
    if prealloc:
      dst = newSeq[int](total)       # zeroed: pre-faulted, no stale contents
    let t0 = getMonoTime().ticks
    if not prealloc:
      dst = newSeqUninit[int](total)
    case kind
    of SeqBranchy:
      seqMerge(inputPtr(gA), inputPtr(gB), gN, gN, cast[P](addr dst[0]))
    of SeqTwo:
      kTwo(inputPtr(gA), inputPtr(gB), 0, gN, 0, gN, cast[P](addr dst[0]))
    of PoolBranchy:
      mergePathPoolBranchy(inputPtr(gA), inputPtr(gB), cast[P](addr dst[0]),
                           gN, gN, parts)
    of PoolFast:
      mergePathPool(inputPtr(gA), inputPtr(gB), cast[P](addr dst[0]),
                    gN, gN, parts)
    of PoolFastX4:
      mergePathPool(inputPtr(gA), inputPtr(gB), cast[P](addr dst[0]),
                    gN, gN, parts * 4)
    let elapsed = getMonoTime().ticks - t0
    if not sameInts(dst, gRef):
      quit "WRONG RESULT: " & implName(kind)
    if r == WarmupRuns + reps - 1:
      result = digestOf(dst)
    if r >= WarmupRuns:
      times.add elapsed
  times.sort()
  let best = times[0]
  let median = times[times.len div 2]
  let name = implName(kind)
  when not smoke:
    echo pad(name, 18), " min ", pad(millis3(best) & " ms", 12),
         " median ", millis3(median) & " ms"
    echo "CSV,", name, ",", parts, ",", (if prealloc: "prealloc" else: "alloc"),
         ",", millis3(best), ",", millis3(median), ",", result

proc checkEdgeCases() =
  ## Empty inputs, one empty side, duplicates and disjoint ranges -- the cases
  ## where a diagonal search or a partition boundary tends to go wrong.
  randomize(7)
  for i in 0 ..< 9:
    let la = [0, 0, 7, 1, 3, 100, 1000, 257, 500][i]
    let lb = [0, 5, 0, 1, 100, 3, 1000, 1031, 500][i]
    let mx = [1, 10, 10, 1, 2, 2, 5, 1_000_000, 1][i]
    var a = newSeq[int](la)
    var b = newSeq[int](lb)
    for j in 0 ..< a.len: a[j] = rand(mx)
    for j in 0 ..< b.len: b[j] = rand(mx)
    sort(a)
    sort(b)
    var expect = newSeq[int](la + lb)
    for j in 0 ..< la: expect[j] = a[j]
    for j in 0 ..< lb: expect[la + j] = b[j]
    sort(expect)
    for parts in [1, 2, 3, 7, 16]:
      if not sameInts(mergePathPoolSeq(a, b, parts), expect):
        quit "edge-case mismatch: " & $la & " " & $lb & " " & $mx & " " & $parts
  # disjoint ranges, both orders
  var lo = newSeq[int](100_000)
  var hi = newSeq[int](100_000)
  for i in 0 ..< lo.len:
    lo[i] = i
    hi[i] = i + 1_000_000
  var expect = newSeq[int](lo.len + hi.len)
  for i in 0 ..< lo.len:
    expect[i] = lo[i]
    expect[lo.len + i] = hi[i]
  if not sameInts(mergePathPoolSeq(lo, hi, 5), expect):
    quit "disjoint ranges mismatch"
  if not sameInts(mergePathPoolSeq(hi, lo, 5), expect):
    quit "disjoint ranges mismatch (reversed)"

proc main =
  # Nimony's `parseInt` raises, and an uncaught exception would push `.raises`
  # onto everything main reaches; the leaf catches it and falls back instead.
  proc toInt(s: string; fallback: int): int =
    try: result = parseInt(s)
    except: result = fallback

  for kind, key, val in getopt():
    case kind
    of cmdArgument: quit "unexpected argument: " & key
    of cmdLongOption, cmdShortOption:
      case key
      of "n": gN = max(1, toInt(val, DefaultN))
      of "threads", "t": gThreads = max(1, toInt(val, DefaultThreads))
      of "reps", "r": gReps = max(1, toInt(val, DefaultReps))
      of "prealloc", "p": gPrealloc = true
      of "only": gOnly = val
      of "list":
        for i in 0 ..< AllImpls.len: echo implName(AllImpls[i])
        return
      of "help", "h":
        echo "mergepath [--n:N] [--threads:N] [--reps:N] [--prealloc] " &
             "[--only:SUBSTR] [--list]"
        return
      else: quit "unknown option: " & key
    of cmdEnd: discard

  # The edge-case checks use the pool too, and the pool is a process-wide
  # singleton anyway: start it once, before anything is timed.
  initPool(gThreads)
  initLock(doneLock)
  initCond(doneCond)

  when not smoke:
    echo "mergepath: n=", gN, " per array, parts/threads=", gThreads,
         ", reps=", gReps, ", ",
         (if gPrealloc: "dst PREALLOCATED" else: "dst allocation INCLUDED")

  checkEdgeCases()

  # A fresh seed right before the measured inputs: the digests must not depend
  # on how many random numbers the edge-case block happened to consume.
  randomize(12345)
  gA = newSeq[int](gN)
  gB = newSeq[int](gN)
  for i in 0 ..< gN:
    gA[i] = rand(100_000_000)
    gB[i] = rand(100_000_000)
  sort(gA)
  sort(gB)
  gRef = newSeq[int](gN * 2)
  seqMerge(inputPtr(gA), inputPtr(gB), gN, gN, cast[P](addr gRef[0]))

  for i in 0 ..< AllImpls.len:
    let kind = AllImpls[i]
    if wanted(implName(kind), gOnly):
      discard run(kind, gThreads, gReps, gPrealloc)

  shutdownPool()

when defined(windows):
  # Nimony does not exercise pool workers on Windows yet, so skip the run and
  # keep the same deterministic word a smoke build expects.
  when smoke:
    echo "mergepath ok"
  else:
    echo "mergepath: skipped on Windows"
else:
  main()
  when smoke:
    echo "mergepath ok"

{.feature: "assumeSync".}  # bench: the input arrays are shared by design
