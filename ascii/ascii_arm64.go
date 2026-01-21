//go:build !noasm && arm64

package ascii

// IndexAny returns the index of the first byte in s that is in the CharSet,
// or -1 if no such byte exists.
func (cs CharSet) IndexAny(s string) int {
	if cs.bitset == [4]uint64{} {
		return -1
	}
	if len(s) < 16 {
		return indexAnyGoBitset(s, &cs.bitset)
	}
	return indexAnyNeonBitset(s, cs.bitset[0], cs.bitset[1], cs.bitset[2], cs.bitset[3])
}

// ContainsAny reports whether any byte in s is in the CharSet.
func (cs CharSet) ContainsAny(s string) bool {
	return cs.IndexAny(s) >= 0
}

// IndexAny finds the first occurrence of any byte from chars in data.
// Returns -1 if no match is found.
// Dispatch: Go (<16B data) → NEON bitset (default)
func IndexAny(data, chars string) int {
	return NewCharSet(chars).IndexAny(data)
}
