//go:build !noasm && arm64

package ascii

// indexFoldNeedleNeon128 processes 64 bytes per iteration with interleaved
// loads and compute for better instruction-level parallelism on Graviton 4.
//
//go:noescape
func indexFoldNeedleNeon128(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
