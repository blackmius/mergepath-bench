## mp_csp.nim -- merge path on top of nimcsp goroutines.
##
## Usage:   cspInit(workers + 1)       # main thread coordinates & blocks in
##                                     # wgWait, `workers` OS threads compute
##          mergePathCsp(a, b, dst, alen, blen, parts)
import csp
import std/[atomics, posix]
import mpcore
export mpcore

type
  MPJob = object
    a, b, dst: P
    alen, blen, parts: int
    wg: WaitGroupT
    exited: Atomic[int]
  MPTask = object
    job: ptr MPJob
    idx: int

proc mpWorker(arg: pointer) {.cdecl.} =
  let t = cast[ptr MPTask](arg)
  let j = t.job
  mergePart(j.a, j.b, j.dst, j.alen, j.blen, t.idx, j.parts)
  wgDone(j.wg)
  # Last touch of the job. nimcsp's WaitGroup.wait() returns lock-free as soon
  # as the counter hits 0, while the final done() may still be about to lock
  # wg.mtx -- so the job (which holds the WaitGroup) must not be freed until
  # every goroutine has reported here.
  discard j.exited.fetchAdd(1, moRelease)

proc mergePathCsp*(a, b, dst: P, alen, blen, parts: int) =
  let job = cast[ptr MPJob](allocShared0(sizeof(MPJob)))
  let tasks = cast[ptr UncheckedArray[MPTask]](allocShared0(parts * sizeof(MPTask)))
  job.a = a; job.b = b; job.dst = dst
  job.alen = alen; job.blen = blen; job.parts = parts
  wgInit(job.wg)
  wgAdd(job.wg, parts)
  for i in 0 ..< parts:
    tasks[i].job = job
    tasks[i].idx = i
    discard cspProcCreate(0, mpWorker, addr tasks[i])
  wgWait(job.wg)
  while job.exited.load(moAcquire) < parts:
    discard sched_yield()
  deallocShared(tasks)
  deallocShared(job)

proc mergePathCsp*(a, b: seq[int], parts: int): seq[int] =
  result = newSeqUninitialized[int](a.len + b.len)
  if result.len == 0: return
  mergePathCsp(cast[P](if a.len > 0: unsafeAddr a[0] else: nil),
               cast[P](if b.len > 0: unsafeAddr b[0] else: nil),
               cast[P](addr result[0]), a.len, b.len, parts)
