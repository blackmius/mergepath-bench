package main

// fast.go: Go port of the "FAST" Nim algorithm (src/mpcore.nim):
//  1. every goroutine finds its OWN two split points (no serial phase),
//  2. branchless merge kernel (Go's SSA branchelim turns the if into CMOV),
//  3. two independent merge chains interleaved in one loop (ILP),
//  4. no bounds test in the hot loop (n = min(remaining) steps per round).
// fastSafe keeps Go's bounds checks; fastUnsafe removes them with unsafe.

import (
	"sync"
	"unsafe"
)

func diagSplit(a, b []int, d int) int {
	lo := d - len(b)
	if lo < 0 {
		lo = 0
	}
	hi := d
	if len(a) < hi {
		hi = len(a)
	}
	for lo < hi {
		mid := int(uint(lo+hi) >> 1)
		if a[mid] > b[d-mid-1] {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

// ---------- safe (bounds-checked) kernels ----------
func kOne(a, b, dst []int) {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		n := len(a) - i
		if m := len(b) - j; m < n {
			n = m
		}
		for s := 0; s < n; s++ {
			av, bv := a[i], b[j]
			v, inc := bv, 0
			if av <= bv {
				v, inc = av, 1
			}
			dst[k] = v
			i += inc
			j += 1 - inc
			k++
		}
	}
	k += copy(dst[k:], a[i:])
	copy(dst[k:], b[j:])
}

func kTwo(a, b, dst []int) {
	n := len(a) + len(b)
	h := n >> 1
	mx := diagSplit(a, b, h)
	my := h - mx
	aL, bL, dL := a[:mx], b[:my], dst[:h]
	aR, bR, dR := a[mx:], b[my:], dst[h:]
	var iL, jL, kL, iR, jR, kR int
	for {
		m := len(aL) - iL
		if x := len(bL) - jL; x < m {
			m = x
		}
		if x := len(aR) - iR; x < m {
			m = x
		}
		if x := len(bR) - jR; x < m {
			m = x
		}
		if m <= 0 {
			break
		}
		for s := 0; s < m; s++ {
			av, bv := aL[iL], bL[jL]
			v, inc := bv, 0
			if av <= bv {
				v, inc = av, 1
			}
			dL[kL] = v
			iL += inc
			jL += 1 - inc
			kL++

			av, bv = aR[iR], bR[jR]
			v, inc = bv, 0
			if av <= bv {
				v, inc = av, 1
			}
			dR[kR] = v
			iR += inc
			jR += 1 - inc
			kR++
		}
	}
	kOne(aL[iL:], bL[jL:], dL[kL:])
	kOne(aR[iR:], bR[jR:], dR[kR:])
}

// ---------- unsafe (no bounds checks) kernels ----------
func ld(p unsafe.Pointer, i int) int             { return *(*int)(unsafe.Add(p, uintptr(i)*8)) }
func st(p unsafe.Pointer, i, v int)              { *(*int)(unsafe.Add(p, uintptr(i)*8)) = v }
func off(p unsafe.Pointer, i int) unsafe.Pointer { return unsafe.Add(p, uintptr(i)*8) }

func kOneU(a, b, dst unsafe.Pointer, alen, blen int) {
	i, j, k := 0, 0, 0
	for i < alen && j < blen {
		n := alen - i
		if m := blen - j; m < n {
			n = m
		}
		for s := 0; s < n; s++ {
			av, bv := ld(a, i), ld(b, j)
			v, inc := bv, 0
			if av <= bv {
				v, inc = av, 1
			}
			st(dst, k, v)
			i += inc
			j += 1 - inc
			k++
		}
	}
	for ; i < alen; i++ {
		st(dst, k, ld(a, i))
		k++
	}
	for ; j < blen; j++ {
		st(dst, k, ld(b, j))
		k++
	}
}

func kTwoU(a, b, dst unsafe.Pointer, alen, blen int, as, bs []int) {
	n := alen + blen
	h := n >> 1
	mx := diagSplit(as, bs, h)
	my := h - mx
	aR, bR, dR := off(a, mx), off(b, my), off(dst, h)
	aLen, bLen := mx, my
	aRLen, bRLen := alen-mx, blen-my
	var iL, jL, kL, iR, jR, kR int
	for {
		m := aLen - iL
		if x := bLen - jL; x < m {
			m = x
		}
		if x := aRLen - iR; x < m {
			m = x
		}
		if x := bRLen - jR; x < m {
			m = x
		}
		if m <= 0 {
			break
		}
		for s := 0; s < m; s++ {
			av, bv := ld(a, iL), ld(b, jL)
			v, inc := bv, 0
			if av <= bv {
				v, inc = av, 1
			}
			st(dst, kL, v)
			iL += inc
			jL += 1 - inc
			kL++

			av, bv = ld(aR, iR), ld(bR, jR)
			v, inc = bv, 0
			if av <= bv {
				v, inc = av, 1
			}
			st(dR, kR, v)
			iR += inc
			jR += 1 - inc
			kR++
		}
	}
	kOneU(off(a, iL), off(b, jL), off(dst, kL), aLen-iL, bLen-jL)
	kOneU(off(aR, iR), off(bR, jR), off(dR, kR), aRLen-iR, bRLen-jR)
}

// ---------- parallel drivers ----------
func fastPart(a, b, dst []int, p, parts int, unsafeK bool) {
	total := len(a) + len(b)
	d0 := p * total / parts
	d1 := (p + 1) * total / parts
	x0 := diagSplit(a, b, d0)
	x1 := diagSplit(a, b, d1)
	as, bs, ds := a[x0:x1], b[d0-x0:d1-x1], dst[d0:d1]
	if unsafeK {
		var ap, bp, dp unsafe.Pointer
		if len(as) > 0 {
			ap = unsafe.Pointer(&as[0])
		}
		if len(bs) > 0 {
			bp = unsafe.Pointer(&bs[0])
		}
		if len(ds) > 0 {
			dp = unsafe.Pointer(&ds[0])
		}
		kTwoU(ap, bp, dp, len(as), len(bs), as, bs)
	} else {
		kTwo(as, bs, ds)
	}
}

func mergeFast(a, b, dst []int, parts int, unsafeK bool) {
	var wg sync.WaitGroup
	wg.Add(parts)
	for p := 0; p < parts; p++ {
		go func(p int) {
			defer wg.Done()
			fastPart(a, b, dst, p, parts, unsafeK)
		}(p)
	}
	wg.Wait()
}

// branchy sequential merge into dst (same loop as the Nim seqMerge baseline)
func seqBranchy(a, b, dst []int) {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		if a[i] <= b[j] {
			dst[k] = a[i]
			i++
		} else {
			dst[k] = b[j]
			j++
		}
		k++
	}
	k += copy(dst[k:], a[i:])
	copy(dst[k:], b[j:])
}
