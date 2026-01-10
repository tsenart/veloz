//go:build !noasm && arm64

package ascii

// indexFoldNeedleNeonSingle searches for a needle using only the first rare byte.
// This is faster than the 2-rare-byte approach because it only does one load per position.
// Trade-off: More false positives require more verification, but the main loop is 2x faster.
//
//go:noescape
func indexFoldNeedleNeonSingle(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
