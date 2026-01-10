//go:build !noasm && arm64

package ascii

// indexFoldNeedleNeonDual uses dual VCMEQ (upper + lower) + VORR
// instead of VAND + VCMEQ. Tests which approach is faster.
//
//go:noescape
func indexFoldNeedleNeonDual(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
