//go:build !noasm && arm64

package ascii

//go:noescape
func indexFoldNeedleNeonFast(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
