//go:build !noasm && arm64

package ascii

// indexFoldNeedleNeonGolike uses Go stdlib's IndexByte loop structure
// with mask-based case folding. Single rare byte prefilter.
//
//go:noescape
func indexFoldNeedleNeonGolike(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
