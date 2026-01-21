//go:build (!amd64 && !arm64) || (noasm && arm64)

package ascii

func ValidString(s string) bool {
	return indexMaskGo(s, 0x80) == -1
}

func IndexMask(s string, mask byte) int {
	return indexMaskGo(s, mask)
}

func EqualFold(a, b string) bool {
	return equalFoldGo(a, b)
}

func IndexFold(a, b string) int {
	return indexFoldGo(a, b)
}

func indexFoldRabinKarp(a, b string) int {
	return indexFoldGo(a, b)
}

// IndexAny finds the first occurrence of any byte from chars in data.
func IndexAny(s, chars string) int {
	return NewCharSet(chars).IndexAny(s)
}

// IndexAny returns the index of the first byte in s that is in the CharSet,
// or -1 if no such byte exists.
func (cs CharSet) IndexAny(s string) int {
	if cs.bitset == [4]uint64{} {
		return -1
	}
	return indexAnyGoBitset(s, &cs.bitset)
}

// ContainsAny reports whether any byte in s is in the CharSet.
func (cs CharSet) ContainsAny(s string) bool {
	return cs.IndexAny(s) >= 0
}
