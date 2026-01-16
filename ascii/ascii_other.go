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

func IndexFold(haystack, needle string) int {
	return indexFoldGo(haystack, needle)
}

// Index finds the first case-sensitive match of needle in haystack.
func Index(haystack, needle string) int {
	return strings.Index(haystack, needle)
}

func indexFoldRabinKarp(a, b string) int {
	return indexFoldGo(a, b)
}

func IndexAny(s, chars string) int {
	return indexAnyGo(s, chars)
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

// Index finds the first occurrence of the pattern in haystack.
// Uses the case sensitivity specified when the Searcher was created.
// On non-SIMD platforms, this falls back to Go implementation.
func (s Searcher) Index(haystack string) int {
	if s.caseSensitive {
		return strings.Index(haystack, s.raw)
	}
	return indexFoldGo(haystack, s.raw)
}
