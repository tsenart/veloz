//go:build !noasm && arm64

package ascii

import "testing"

func BenchmarkIndex(b *testing.B) {
	runIndexBenchmarks(b, nil)
}
