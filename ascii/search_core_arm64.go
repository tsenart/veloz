//go:build !noasm && arm64

package ascii

// searchWithRareBytes delegates to the handwritten NEON assembly.
// The NEON kernel uses a 2-byte prefilter with case-folding and expects
// a lowercase normalized needle.
func searchWithRareBytes(hay, normNeedle string, rare1 byte, off1 int, rare2 byte, off2 int) int {
	return indexFoldNeedleNEON(hay, rare1, off1, rare2, off2, normNeedle)
}
