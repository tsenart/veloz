package ascii

import (
	"golang.org/x/sys/cpu"
)

var (
	hasSSE41 = cpu.X86.HasSSE41
	hasAVX2  = cpu.X86.HasAVX
)

func ValidString(s string) bool {
	if hasAVX2 {
		return isAsciiAvx(s)
	}

	if hasSSE41 {
		return isAsciiSse(s)
	}

	return isAsciiGo(s)
}

func IndexMask(s string, mask byte) int {
	if hasAVX2 {
		return indexMaskAvx(s, mask)
	}

	return indexMaskGo(s, mask)
}

func EqualFold(a, b string) bool {
	if len(a) < 32 || !hasAVX2 {
		return equalFoldGo(a, b)
	}

	return equalFoldAvx(a, b)
}

func IndexFold(a, b string) int {
	// TODO: implement acceleration for this
	return indexFoldGo(a, b)
}

func indexFoldRabinKarp(a, b string) int {
	// FIXME: definitely not Rabin-Karp
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
// On amd64, this falls back to IndexFold (no SIMD acceleration yet).
func SearchNeedle(haystack string, n Needle) int {
	return indexFoldGo(haystack, n.raw)
}
