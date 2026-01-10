//go:build !noasm && arm64

package ascii

//go:noescape
func indexFoldNeedleSveG3(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
