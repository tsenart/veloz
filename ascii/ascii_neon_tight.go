//go:build !noasm && arm64

package ascii

// indexFoldNeedleNeonTight is a tighter 64-byte loop with minimal
// instructions between load and early exit check.
//
//go:noescape
func indexFoldNeedleNeonTight(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
