package ascii

import (
	"github.com/mhr3/veloz/internal/bytealg"
	"golang.org/x/sys/cpu"
)

var (
	hasSSE41 = cpu.X86.HasSSE41
	hasAVX2  = cpu.X86.HasAVX2
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

// Index finds the first case-sensitive match of needle in haystack.
func Index(haystack, needle string) int {
	return bytealg.Index(haystack, needle)
}

// Searcher performs fast repeated substring searches.
// Construct once with NewSearcher, then call Index on multiple haystacks.
type Searcher struct {
	raw           string // original pattern
	norm          string // lowercase pattern (for case-insensitive verification)
	off1          int    // offset in pattern
	off2          int    // offset in pattern
	caseSensitive bool   // if true, use exact matching
}

// NewSearcher creates a Searcher for repeated substring searches.
// If caseSensitive is false, searches are case-insensitive (ASCII letters only).
func NewSearcher(pattern string, caseSensitive bool) Searcher {
	_, off1, _, off2 := selectRarePair(pattern, nil, caseSensitive)
	norm := ""
	if !caseSensitive {
		norm = normalizeASCII(pattern)
	}
	return Searcher{
		raw:           pattern,
		norm:          norm,
		off1:          off1,
		off2:          off2,
		caseSensitive: caseSensitive,
	}
}

// NewSearcherWithRanks creates a Searcher using a custom byte frequency table.
func NewSearcherWithRanks(pattern string, ranks []byte, caseSensitive bool) Searcher {
	if len(ranks) != 256 {
		panic("ranks must have exactly 256 entries")
	}
	_, off1, _, off2 := selectRarePair(pattern, ranks, caseSensitive)
	norm := ""
	if !caseSensitive {
		norm = normalizeASCII(pattern)
	}
	return Searcher{
		raw:           pattern,
		norm:          norm,
		off1:          off1,
		off2:          off2,
		caseSensitive: caseSensitive,
	}
}

// Index finds the first occurrence of the pattern in haystack.
func (s Searcher) Index(haystack string) int {
	if len(s.raw) == 0 {
		return 0
	}
	if len(haystack) < len(s.raw) {
		return -1
	}

	if s.caseSensitive {
		return bytealg.Index(haystack, s.raw)
	}
	return indexFoldGo(haystack, s.norm)
}
