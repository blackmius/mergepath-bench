import std/[random, algorithm, monotimes, strutils, parseopt, os]
import malebolgia
import csp, mp_csp   # mp_csp re-exports mpcore
{.push checks:off, boundChecks:off, overflowChecks:off.}

proc now(): int64 = getMonotime().ticks
var master = createMaster()

# ---- user's baseline, algorithm verbatim -------------------------------
proc seqMerge(a, b: P, alen, blen: int, dst: P) =
  var i, j, k: int
  while i < alen and j < blen:
    if a[i] <= b[j]: dst[k] = a[i]; inc i
    else: dst[k] = b[j]; inc j
    inc k
  while i < alen: dst[k] = a[i]; inc i; inc k
  while j < blen: dst[k] = b[j]; inc j; inc k

proc findSplits(a, b: P, alen, blen, cores: int, splits: P) =
  let total = alen + blen
  for core in 0 ..< cores:
    let diag = core * total div cores
    var lo = max(0, diag - blen)
    var hi = min(diag, alen)
    while lo <= hi:
      let x = (lo + hi) shr 1
      let y = diag - x
      if x < alen and y > 0 and a[x] < b[y-1]: lo = x + 1
      elif x > 0 and y < blen and a[x-1] > b[y]: hi = x - 1
      else:
        splits[core*2] = x; splits[core*2+1] = y
        break
  splits[cores*2] = alen
  splits[cores*2+1] = blen

proc worker(core, cores: int, a, b, splits, dst: P, alen, blen, total: int) =
  let sx = splits[core*2]; let sy = splits[core*2+1]
  let ex = splits[(core+1)*2]; let ey = splits[(core+1)*2+1]
  var i = sx; var j = sy; var k = core * total div cores
  while i < ex and j < ey:
    if a[i] <= b[j]: dst[k] = a[i]; inc i
    else: dst[k] = b[j]; inc j
    inc k
  while i < ex: dst[k] = a[i]; inc i; inc k
  while j < ey: dst[k] = b[j]; inc j; inc k

proc mbUser(a, b: P, alen, blen: int, dst: P, cores: int) =
  var splits = newSeqUninitialized[int](cores*2 + 2)
  let sp = cast[P](addr splits[0])
  findSplits(a, b, alen, blen, cores, sp)
  master.awaitAll:
    for c in 0 ..< cores:
      master.spawn worker(c, cores, a, b, sp, dst, alen, blen, alen + blen)

proc mbFast(a, b: P, alen, blen: int, dst: P, parts: int) =
  master.awaitAll:
    for c in 0 ..< parts:
      master.spawn mergePart(a, b, dst, alen, blen, c, parts)

# ---- faithful nimcsp port of the baseline (seq splits, branchy kernel) ---
type PT = object
  core, cores: int
  a, b, sp, dst: P
  alen, blen: int
  wg: ptr WaitGroupT
var portWg: WaitGroupT
proc portWorker(arg: pointer) {.cdecl.} =
  let t = cast[ptr PT](arg)
  worker(t.core, t.cores, t.a, t.b, t.sp, t.dst, t.alen, t.blen, t.alen + t.blen)
  wgDone(t.wg[])
proc cspPort(a, b: P, alen, blen: int, dst: P, cores: int) =
  var splits = newSeqUninitialized[int](cores*2 + 2)
  let sp = cast[P](addr splits[0])
  findSplits(a, b, alen, blen, cores, sp)
  var ts = newSeq[PT](cores)
  wgInit(portWg); wgAdd(portWg, cores)
  for c in 0 ..< cores:
    ts[c] = PT(core: c, cores: cores, a: a, b: b, sp: sp, dst: dst, alen: alen, blen: blen, wg: addr portWg)
    discard cspProcCreate(0, portWorker, addr ts[c])
  wgWait(portWg)
  os.sleep(0)   # (port is only a timing reference)
{.pop.}

proc fixPort() = discard

when isMainModule:
  var n = 10 * 1024 * 1024
  var t = 1
  var reps = 9
  var prealloc = false
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case key
    of "n": n = parseInt(val)
    of "t": t = parseInt(val)
    of "r": reps = parseInt(val)
    of "p": prealloc = true
    else: discard
  cspInit(t + 1)

  # ---- correctness on edge cases (small / empty / duplicates / disjoint) ----
  block:
    randomize(7)
    for (la, lb, mx) in [(0,0,1),(0,5,10),(7,0,10),(1,1,1),(3,100,2),(100,3,2),(1000,1000,5),(257,1031,1_000_000),(500,500,1)]:
      for parts in [1, 2, 3, 7, 16, 64]:
        var a = newSeq[int](la); var b = newSeq[int](lb)
        for i in 0 ..< la: a[i] = rand(mx)
        for i in 0 ..< lb: b[i] = rand(mx)
        a.sort(); b.sort()
        var expect = a & b
        expect.sort()
        doAssert mergePathCsp(a, b, parts) == expect, "csp mismatch " & $(la, lb, mx, parts)
    # disjoint ranges (all a < all b and vice versa)
    var lo = newSeq[int](100_000); var hi = newSeq[int](100_000)
    for i in 0 ..< lo.len: lo[i] = i; hi[i] = i + 1_000_000
    doAssert mergePathCsp(lo, hi, 5) == lo & hi
    doAssert mergePathCsp(hi, lo, 5) == lo & hi
    echo "correctness: all edge cases OK"

  randomize(12345)
  var a = newSeq[int](n); var b = newSeq[int](n)
  for i in 0 ..< n: a[i] = rand(100_000_000); b[i] = rand(100_000_000)
  a.sort(); b.sort()
  let ap = cast[P](addr a[0]); let bp = cast[P](addr b[0])
  var refv = newSeq[int](2*n)
  seqMerge(ap, bp, n, n, cast[P](addr refv[0]))

  type Impl = proc(dst: P)
  proc run(name: string, f: Impl): float =
    var times: seq[int64]
    for r in -2 ..< reps:
      var d: seq[int]
      if prealloc:
        d = newSeq[int](2*n)        # zeroed => pre-faulted & can't hide stale data
      let t0 = now()
      if not prealloc: d = newSeqUninitialized[int](2*n)
      f(cast[P](addr d[0]))
      let el = now() - t0
      doAssert equalMem(addr d[0], addr refv[0], 2*n*8), name & ": WRONG RESULT"
      if r >= 0: times.add el
    times.sort()
    let mn = times[0].float / 1e6
    let md = times[times.len div 2].float / 1e6
    echo name.alignLeft(22), " min ", mn.formatFloat(ffDecimal, 1).align(7), " ms   median ", md.formatFloat(ffDecimal, 1).align(7), " ms"
    echo "CSV,", name, ",", t, ",", (if prealloc: "prealloc" else: "alloc"), ",", mn.formatFloat(ffDecimal, 3), ",", md.formatFloat(ffDecimal, 3)
    mn

  echo "n=", n, " per array, tasks/threads t=", t, ", reps=", reps, (if prealloc: ", dst PREALLOCATED" else: ", dst allocation INCLUDED")
  discard run("seq (user baseline)", proc(d: P) = seqMerge(ap, bp, n, n, d))
  discard run("seq 2-chain kernel", proc(d: P) = kTwo(ap, bp, 0, n, 0, n, d))
  discard run("malebolgia (user)", proc(d: P) = mbUser(ap, bp, n, n, d, t))
  discard run("malebolgia + fast", proc(d: P) = mbFast(ap, bp, n, n, d, t))
  discard run("nimcsp port", proc(d: P) = cspPort(ap, bp, n, n, d, t))
  discard run("nimcsp FAST", proc(d: P) = mergePathCsp(ap, bp, d, n, n, t))
  discard run("nimcsp FAST x4 parts", proc(d: P) = mergePathCsp(ap, bp, d, n, n, 4*t))
