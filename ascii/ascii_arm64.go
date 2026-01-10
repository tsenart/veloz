//go:build !noasm && arm64

package ascii

import (
	"golang.org/x/sys/cpu"
)

var hasSVE = cpu.ARM64.HasSVE
var hasSVE2 = cpu.ARM64.HasSVE2

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
	if len(data) < 16 {
		return indexAnyCharSetGo(data, cs)
	}
	return indexAnyNeonBitset(data, cs.bitset[0], cs.bitset[1], cs.bitset[2], cs.bitset[3])
}

// indexAnyCharSetGo is a Go fallback for small data using prebuilt CharSet.
func indexAnyCharSetGo(s string, cs CharSet) int {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if cs.bitset[c>>6]&(1<<(c&63)) != 0 {
			return i
		}
	}
	return -1
}

// IndexAny finds the first occurrence of any byte from chars in data.
// Returns -1 if no match is found.
// Dispatch: Go (<16B data) → SVE2 (>32 chars) → NEON bitset (default)
func IndexAny(data, chars string) int {
	if len(chars) == 0 {
		return -1
	}
	// For very small data, Go is faster (bitset building overhead dominates)
	if len(data) < 16 {
		return indexAnyGo(data, chars)
	}
	// Note: SVE2 MATCH was removed - use NEON bitset for all char set sizes
	// Build 256-bit bitset from chars
	var bitset [4]uint64
	for i := 0; i < len(chars); i++ {
		c := chars[i]
		bitset[c>>6] |= 1 << (c & 63)
	}
	return indexAnyNeonBitset(data, bitset[0], bitset[1], bitset[2], bitset[3])
}

// SearchNeedle finds the first case-insensitive match of the precomputed needle in haystack.
// This is the optimized entry point that uses:
// - memchr's rare byte selection (fewer false positives)
// - Sneller's compare+XOR normalization (no table lookup)
// - Sneller's tail masking (no scalar remainder)
// For repeated searches with the same needle, this is faster than IndexFold.
// On SVE2-capable CPUs (Graviton 4, Neoverse V2), uses svmatch for even faster matching.
func SearchNeedle(haystack string, n Needle) int {
	if len(n.raw) == 0 {
		return 0
	}
	if len(haystack) < len(n.raw) {
		return -1
	}
	// For very short haystacks, use Go fallback
	if len(haystack) < 16 {
		return indexFoldGo(haystack, n.raw)
	}
	// Use SVE path on Graviton 3 (256-bit vectors, 2× throughput)
	// SVE2 was removed - only G3 SVE (non-SVE2) is supported
	if hasSVE && !hasSVE2 {
		return indexFoldNeedleSveG3(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
	}
	// Frequency-based algorithm selection:
	// - If rare1 is truly rare (frequency < threshold): use adaptive 1-byte fast path
	// - Otherwise: use 2-byte NEON directly (avoids cutover overhead)
	if isRareByte(n.rare1) {
		return indexFoldNeedleAdaptive(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
	}
	return IndexFoldNeedle(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
}
