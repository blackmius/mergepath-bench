## mpcore.nim -- runtime-agnostic pieces of the merge-path implementation.
##
##  * diagSplit : binary search on a merge-path diagonal (no bounds checks needed)
##  * kTwo      : sequential merge kernel, branchless, TWO independent chains
##                interleaved for instruction-level parallelism
##  * mergePart : merge exactly partition `idx` of `parts` -- finds its OWN two
##                split points, so there is no serial split phase and no barrier
##                between "find splits" and "merge".
{.push checks: off, boundChecks: off, overflowChecks: off.}

type P* = ptr UncheckedArray[int]

template off*(p: P, n: int): P = cast[P](cast[uint](p) + uint(n) * uint(sizeof(int)))

template mstep(a, b, dst: P, i, j, k: untyped) =
  let av = a[i]
  let bv = b[j]
  let t = av <= bv            # '<=' : a wins ties => stable
  dst[k] = (if t: av else: bv)
  i += int(t)
  j += 1 - int(t)
  inc k

## Number of elements among the first `d` outputs of the stable merge that come
## from `a`. Smallest x in [max(0,d-blen), min(d,alen)] with a[x] > b[d-x-1]
## (a[alen] = +inf, b[-1] = -inf). Inside the loop mid < alen, mid < d and
## d-mid-1 in [0, blen), so every access is in range.
proc diagSplit*(a, b: P, alen, blen, d: int): int {.inline.} =
  var lo = max(0, d - blen)
  var hi = min(d, alen)
  while lo < hi:
    let mid = (lo + hi) shr 1
    if a[mid] > b[d - mid - 1]: hi = mid
    else: lo = mid + 1
  lo

## single-chain branchless merge of a[i0..ex) and b[j0..ey) into dst[0..).
## Runs n = min(remaining_a, remaining_b) steps at a time: neither input can be
## exhausted inside such a round, so the hot loop has no bounds test.
proc kOne*(a, b: P, i0, ex, j0, ey: int, dst: P) {.inline.} =
  var i = i0
  var j = j0
  var k = 0
  while i < ex and j < ey:
    let n = min(ex - i, ey - j)
    for _ in 0 ..< n:
      mstep(a, b, dst, i, j, k)
  while i < ex:
    dst[k] = a[i]; inc i; inc k
  while j < ey:
    dst[k] = b[j]; inc j; inc k

## Two independent merge chains (first half / second half of the outputs) run in
## lock-step. A single merge chain is latency-bound (next load address depends
## on the previous compare); two chains let the CPU overlap them.
proc kTwo*(a, b: P, i0, ex, j0, ey: int, dst: P) {.inline.} =
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

proc mergePart*(a, b, dst: P, alen, blen, idx, parts: int) =
  let total = alen + blen
  let d0 = idx * total div parts
  let d1 = (idx + 1) * total div parts
  let x0 = diagSplit(a, b, alen, blen, d0)
  let x1 = diagSplit(a, b, alen, blen, d1)
  kTwo(a, b, x0, x1, d0 - x0, d1 - x1, off(dst, d0))
{.pop.}
