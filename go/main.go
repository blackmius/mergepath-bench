package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"sort"
	"time"
)

type impl struct {
	name  string
	alloc func() []int    // allocates the result itself (timed with allocation)
	into  func(dst []int) // writes into caller-provided dst (preallocated mode)
}

func main() {
	var xn, yn, t, reps int
	var pre bool
	flag.IntVar(&xn, "x", 10485760, "")
	flag.IntVar(&yn, "y", 10485760, "")
	flag.IntVar(&t, "t", 1, "threads / partitions")
	flag.IntVar(&reps, "r", 9, "")
	flag.BoolVar(&pre, "p", false, "preallocate (and pre-fault) destination")
	flag.Parse()
	runtime.GOMAXPROCS(t) // same number of OS threads the Nim runs use
	A, B := generateAB(xn, yn)
	ref := seriesMergeSort(A, B)
	n := xn + yn
	mode := "alloc"
	if pre {
		mode = "prealloc"
	}

	impls := []impl{
		{"go seq (user)", func() []int { return seriesMergeSort(A, B) }, func(d []int) { seqBranchy(A, B, d) }},
		{"go mergePath (user)", func() []int { return mergePath(A, B, t) }, func(d []int) { mergePathInto(A, B, d, t) }},
		{"go seq 2-chain kernel", nil, func(d []int) { kTwo(A, B, d) }},
		{"go FAST (safe)", nil, func(d []int) { mergeFast(A, B, d, t, false) }},
		{"go FAST (unsafe)", nil, func(d []int) { mergeFast(A, B, d, t, true) }},
		{"go FAST x4 parts (unsafe)", nil, func(d []int) { mergeFast(A, B, d, 4*t, true) }},
	}
	fmt.Printf("Go n=%d t=%d GOMAXPROCS=%d reps=%d mode=%s\n", xn, t, runtime.GOMAXPROCS(0), reps, mode)
	for _, im := range impls {
		var ts []int64
		for r := -2; r < reps; r++ {
			var d []int
			var el int64
			if pre {
				d = make([]int, n)
				for i := range d { // pre-fault the pages, outside the timer
					d[i] = 0
				}
				s := time.Now()
				im.into(d)
				el = time.Since(s).Nanoseconds()
			} else {
				s := time.Now()
				if im.alloc != nil {
					d = im.alloc()
				} else {
					d = make([]int, n)
					im.into(d)
				}
				el = time.Since(s).Nanoseconds()
			}
			for i := range ref {
				if d[i] != ref[i] {
					fmt.Println("WRONG RESULT:", im.name)
					os.Exit(1)
				}
			}
			if r >= 0 {
				ts = append(ts, el)
			}
		}
		sort.Slice(ts, func(i, j int) bool { return ts[i] < ts[j] })
		mn, md := float64(ts[0])/1e6, float64(ts[len(ts)/2])/1e6
		fmt.Printf("%-26s min %7.1f ms   median %7.1f ms\n", im.name, mn, md)
		fmt.Printf("CSV,%s,%d,%s,%.3f,%.3f\n", im.name, t, mode, mn, md)
	}
}
