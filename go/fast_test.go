package main

import (
	"math/rand"
	"sort"
	"testing"
)

func TestEdgeCases(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	for _, c := range [][3]int{{0, 0, 1}, {0, 5, 10}, {7, 0, 10}, {1, 1, 1}, {3, 100, 2}, {100, 3, 2}, {1000, 1000, 5}, {257, 1031, 1000000}, {500, 500, 1}} {
		for _, parts := range []int{1, 2, 3, 7, 16, 64} {
			a, b := make([]int, c[0]), make([]int, c[1])
			for i := range a {
				a[i] = r.Intn(c[2])
			}
			for i := range b {
				b[i] = r.Intn(c[2])
			}
			sort.Ints(a)
			sort.Ints(b)
			want := append(append([]int{}, a...), b...)
			sort.Ints(want)
			for _, u := range []bool{false, true} {
				got := make([]int, len(want))
				mergeFast(a, b, got, parts, u)
				for i := range want {
					if got[i] != want[i] {
						t.Fatalf("mismatch %v parts=%d unsafe=%v", c, parts, u)
					}
				}
			}
		}
	}
}
