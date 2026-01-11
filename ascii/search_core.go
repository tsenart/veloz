package ascii

import "strings"

// Note: searchWithRareBytes calls IndexFoldNeedle which is implemented in:
// - ascii_neon.s (compiled from csrc/ascii_neon.c via gocc) for arm64
// - Falls back to Go implementation on other platforms

// selectRarePairFast selects two rare bytes from 8 evenly-spaced samples.
// This is O(1) with no loops and minimal branches - used for one-shot IndexFold.
// Returns (rare1, off1, rare2, off2) with off1 <= off2.
// Both bytes are normalized to lowercase.
func selectRarePairFast(needle string) (rare1 byte, off1 int, rare2 byte, off2 int) {
	n := len(needle)
	if n == 0 {
		return 0, 0, 0, 0
	}
	if n == 1 {
		b := toLower(needle[0])
		return b, 0, b, 0
	}

	// 8 evenly-spaced sample positions (branchless)
	// Using (n * k) >> 3 distributes samples across needle
	// p7 is always n-1 to ensure we sample the last byte
	p0 := 0
	p1 := (n * 1) >> 3
	p2 := (n * 2) >> 3
	p3 := (n * 3) >> 3
	p4 := (n * 4) >> 3
	p5 := (n * 5) >> 3
	p6 := (n * 6) >> 3
	p7 := n - 1

	// Load bytes (normalized to lowercase)
	b0 := toLower(needle[p0])
	b1 := toLower(needle[p1])
	b2 := toLower(needle[p2])
	b3 := toLower(needle[p3])
	b4 := toLower(needle[p4])
	b5 := toLower(needle[p5])
	b6 := toLower(needle[p6])
	b7 := toLower(needle[p7])

	// Load ranks
	r0 := caseFoldRank[b0]
	r1 := caseFoldRank[b1]
	r2 := caseFoldRank[b2]
	r3 := caseFoldRank[b3]
	r4 := caseFoldRank[b4]
	r5 := caseFoldRank[b5]
	r6 := caseFoldRank[b6]
	r7 := caseFoldRank[b7]

	// Tournament to find two rarest bytes
	// Using branchless conditional select: sel(cond, a, b) = cond ? a : b
	// where cond is 0 or 1

	// Round 1: Compare pairs, keep winner (lower rank) and loser
	// Pair (0,1)
	c01 := boolToInt(r0 <= r1)
	w01r, w01p, w01b := selRank(c01, r0, r1), selInt(c01, p0, p1), selByte(c01, b0, b1)
	l01r, l01p, l01b := selRank(1-c01, r0, r1), selInt(1-c01, p0, p1), selByte(1-c01, b0, b1)

	// Pair (2,3)
	c23 := boolToInt(r2 <= r3)
	w23r, w23p, w23b := selRank(c23, r2, r3), selInt(c23, p2, p3), selByte(c23, b2, b3)
	l23r, l23p, l23b := selRank(1-c23, r2, r3), selInt(1-c23, p2, p3), selByte(1-c23, b2, b3)

	// Pair (4,5)
	c45 := boolToInt(r4 <= r5)
	w45r, w45p, w45b := selRank(c45, r4, r5), selInt(c45, p4, p5), selByte(c45, b4, b5)
	l45r, l45p, l45b := selRank(1-c45, r4, r5), selInt(1-c45, p4, p5), selByte(1-c45, b4, b5)

	// Pair (6,7)
	c67 := boolToInt(r6 <= r7)
	w67r, w67p, w67b := selRank(c67, r6, r7), selInt(c67, p6, p7), selByte(c67, b6, b7)
	l67r, l67p, l67b := selRank(1-c67, r6, r7), selInt(1-c67, p6, p7), selByte(1-c67, b6, b7)

	// Round 2: Compare winners
	// Pair (w01, w23)
	c0123 := boolToInt(w01r <= w23r)
	w0123r, w0123p, w0123b := selRank(c0123, w01r, w23r), selInt(c0123, w01p, w23p), selByte(c0123, w01b, w23b)
	l0123r, l0123p, l0123b := selRank(1-c0123, w01r, w23r), selInt(1-c0123, w01p, w23p), selByte(1-c0123, w01b, w23b)

	// Pair (w45, w67)
	c4567 := boolToInt(w45r <= w67r)
	w4567r, w4567p, w4567b := selRank(c4567, w45r, w67r), selInt(c4567, w45p, w67p), selByte(c4567, w45b, w67b)
	l4567r, l4567p, l4567b := selRank(1-c4567, w45r, w67r), selInt(1-c4567, w45p, w67p), selByte(1-c4567, w45b, w67b)

	// Round 3: Final winner (rarest byte)
	cFinal := boolToInt(w0123r <= w4567r)
	_, minP, minB := selRank(cFinal, w0123r, w4567r), selInt(cFinal, w0123p, w4567p), selByte(cFinal, w0123b, w4567b)
	runnerFromWinners := selRank(1-cFinal, w0123r, w4567r)
	runnerFromWinnersP := selInt(1-cFinal, w0123p, w4567p)
	runnerFromWinnersB := selByte(1-cFinal, w0123b, w4567b)

	// Find second rarest among: runner-up from winners bracket + all losers
	// We need to find the minimum among 5 candidates:
	// runnerFromWinners, l01, l23, l45, l67, l0123, l4567
	// But l0123 and l4567 are the losers from round 2, which are already
	// among the round 1 winners who lost to the eventual winner.

	// Simplify: find min among the 7 candidates that has a DIFFERENT byte than the winner
	// Using branchless min-reduction with penalty for same-byte candidates

	// Penalty: add 0x8000 to rank if byte matches minB (pushes same-byte candidates to bottom)
	// This ensures we prefer different bytes, but still pick same byte if no alternative
	addPenalty := func(r uint16, b byte) uint16 {
		// Branchless: if b == minB, add 0x8000 to r
		same := boolToInt(b == minB)
		return r + uint16(same)*0x8000
	}

	// Apply penalty to all 7 candidates
	pr0 := addPenalty(runnerFromWinners, runnerFromWinnersB)
	pr1 := addPenalty(l0123r, l0123b)
	pr2 := addPenalty(l4567r, l4567b)
	pr3 := addPenalty(l01r, l01b)
	pr4 := addPenalty(l23r, l23b)
	pr5 := addPenalty(l45r, l45b)
	pr6 := addPenalty(l67r, l67b)

	// Branchless min-reduction across 7 candidates
	// Round 1: Compare pairs
	s01 := boolToInt(pr0 <= pr1)
	m01r, m01p, m01b := selRank(s01, pr0, pr1), selInt(s01, runnerFromWinnersP, l0123p), selByte(s01, runnerFromWinnersB, l0123b)

	s23 := boolToInt(pr2 <= pr3)
	m23r, m23p, m23b := selRank(s23, pr2, pr3), selInt(s23, l4567p, l01p), selByte(s23, l4567b, l01b)

	s45 := boolToInt(pr4 <= pr5)
	m45r, m45p, m45b := selRank(s45, pr4, pr5), selInt(s45, l23p, l45p), selByte(s45, l23b, l45b)

	// pr6 vs m01 winner
	s60 := boolToInt(pr6 <= m01r)
	m60r, m60p, m60b := selRank(s60, pr6, m01r), selInt(s60, l67p, m01p), selByte(s60, l67b, m01b)

	// Round 2: Compare winners
	s0123 := boolToInt(m60r <= m23r)
	mm0123r, mm0123p, mm0123b := selRank(s0123, m60r, m23r), selInt(s0123, m60p, m23p), selByte(s0123, m60b, m23b)

	// Final: mm0123 vs m45
	sFinal := boolToInt(mm0123r <= m45r)
	secondR := selRank(sFinal, mm0123r, m45r)
	secondP := selInt(sFinal, mm0123p, m45p)
	secondB := selByte(sFinal, mm0123b, m45b)

	// Clear penalty bit (not needed for result, just suppress warning)
	_ = secondR

	// Ensure off1 <= off2 (branchless)
	swap := boolToInt(minP > secondP)
	return selByte(1-swap, minB, secondB), selInt(1-swap, minP, secondP),
		selByte(1-swap, secondB, minB), selInt(1-swap, secondP, minP)
}

// Branchless helpers
func boolToInt(b bool) int {
	// Go compiler optimizes this to conditional move
	if b {
		return 1
	}
	return 0
}

func selInt(cond int, a, b int) int {
	// Returns a if cond==1, b if cond==0
	// Branchless: mask := -cond; return (a & mask) | (b &^ mask)
	mask := -cond
	return (a & mask) | (b &^ mask)
}

func selByte(cond int, a, b byte) byte {
	mask := byte(-cond)
	return (a & mask) | (b &^ mask)
}

func selRank(cond int, a, b uint16) uint16 {
	mask := uint16(-cond)
	return (a & mask) | (b &^ mask)
}

// IndexFoldV2 is the Go-driver implementation of case-insensitive substring search.
// It uses NEON kernels for the hot paths and falls back to SIMD Rabin-Karp for
// pathological cases.
func IndexFoldV2(hay, needle string) int {
	n := len(needle)

	// Early exits
	if n == 0 {
		return 0
	}
	if n > len(hay) {
		return -1
	}
	if n == 1 {
		// Single byte: use IndexByte with both cases
		c := needle[0]
		upper, lower := toUpperLower(c)
		i1 := strings.IndexByte(hay, upper)
		i2 := strings.IndexByte(hay, lower)
		if i1 < 0 {
			return i2
		}
		if i2 < 0 {
			return i1
		}
		if i1 < i2 {
			return i1
		}
		return i2
	}

	// O(1) rare byte selection
	rare1, off1, rare2, off2 := selectRarePairFast(needle)

	// Normalize needle once
	normNeedle := normalizeASCII(needle)

	return searchWithRareBytes(hay, normNeedle, rare1, off1, rare2, off2)
}

// SearchNeedleV2 searches using precomputed rare bytes from MakeNeedle.
// This is the "prepared" path with optimal rare byte selection.
func SearchNeedleV2(hay string, nd Needle) int {
	if len(nd.norm) == 0 {
		return 0
	}
	if len(nd.norm) > len(hay) {
		return -1
	}
	if len(nd.norm) == 1 {
		c := nd.norm[0]
		upper, lower := toUpperLower(c)
		i1 := strings.IndexByte(hay, upper)
		i2 := strings.IndexByte(hay, lower)
		if i1 < 0 {
			return i2
		}
		if i2 < 0 {
			return i1
		}
		if i1 < i2 {
			return i1
		}
		return i2
	}

	return searchWithRareBytes(hay, nd.norm, nd.rare1, nd.off1, nd.rare2, nd.off2)
}

// toUpperLower returns both case variants of a byte.
// For letters, returns (uppercase, lowercase). For non-letters, returns (b, b).
func toUpperLower(b byte) (upper, lower byte) {
	if b >= 'a' && b <= 'z' {
		return b - 0x20, b
	}
	if b >= 'A' && b <= 'Z' {
		return b, b + 0x20
	}
	return b, b
}


