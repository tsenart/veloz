//go:build !arm64 || noasm

package ascii

// searchWithRareBytes falls back to Go implementation on non-arm64 platforms.
func searchWithRareBytes(hay, normNeedle string, rare1 byte, off1 int, rare2 byte, off2 int) int {
	return indexFoldGo(hay, normNeedle)
}
