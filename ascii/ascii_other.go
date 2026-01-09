//go:build !amd64 && !arm64

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

func IndexAny(s, chars string) int {
	return indexAnyGo(s, chars)
}

// CharSet represents a precomputed character set for fast IndexAny lookups.
// Build once with MakeCharSet, then reuse with IndexAnyCharSet.
type CharSet struct {
	bitset [4]uint64
}

// MakeCharSet creates a CharSet from the given characters.
func MakeCharSet(chars string) CharSet {
	var cs CharSet
	for i := 0; i < len(chars); i++ {
		c := chars[i]
		cs.bitset[c>>6] |= 1 << (c & 63)
	}
	return cs
}

// IndexAnyCharSet finds the first occurrence of any byte from cs in data.
// Returns -1 if no match is found.
func IndexAnyCharSet(data string, cs CharSet) int {
	if cs.bitset == [4]uint64{} {
		return -1
	}
	for i := 0; i < len(data); i++ {
		c := data[i]
		if cs.bitset[c>>6]&(1<<(c&63)) != 0 {
			return i
		}
	}
	return -1
}

// SearchNeedle finds the first case-insensitive match of the precomputed needle in haystack.
// On non-SIMD platforms, this falls back to IndexFold.
func SearchNeedle(haystack string, n Needle) int {
	return indexFoldGo(haystack, n.raw)
}
