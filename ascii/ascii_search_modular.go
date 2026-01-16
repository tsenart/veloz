//go:build !noasm && arm64

package ascii

import "strings"

// Modular Go-driven substring search using staged NEON kernels.
// Architecture:
//   Stage 1: 1-byte filter (rare byte at off1)
//   Stage 2: 2-byte filter (rare bytes at off1 and off2)
//   Stage 3: SIMD Rabin-Karp (guaranteed linear)

const (
	exceededFlag = 1 << 63
)

func resultExceeded(r uint64) bool {
	// RESULT_NOT_FOUND is 0xFFFFFFFFFFFFFFFF which has bit 63 set,
	// but it's NOT an exceeded result - it means "not found"
	if r == ^uint64(0) {
		return false
	}
	return r&exceededFlag != 0
}

func resultPosition(r uint64) int {
	pos := int64(r &^ exceededFlag)
	if pos == int64(^uint64(0)&^exceededFlag) {
		return -1
	}
	return int(pos)
}

// IndexFoldModular performs case-insensitive substring search using staged kernels.
// Uses fixed positions for normal needles, selectRarePairSample only for pathological cases.
// Uses Raw variants that fold needle on-the-fly (no normalizeASCII overhead).
func IndexFoldModular(haystack, needle string) int {
	n := len(needle)
	if n == 0 {
		return 0
	}
	if len(haystack) < n {
		return -1
	}

	// Use fixed positions: first byte and last byte (maximum spread)
	// Fall back to middle byte if first==last (e.g., quoted strings like "num")
	off1 := 0
	off2 := n - 1
	if n > 2 && toLower(needle[0]) == toLower(needle[n-1]) {
		off2 = n / 2
	}

	var result uint64
	var resumePos int

	// For short needles, skip 1-byte stage (overhead not worth it)
	// For longer needles, 1-byte filter helps reduce false positives
	if n <= 16 {
		result = indexFold2ByteRaw(haystack, needle, off1, off2-off1)
	} else {
		// Stage 1: 1-byte filter
		result = indexFold1ByteRaw(haystack, needle, off1)

		if !resultExceeded(result) {
			return resultPosition(result)
		}

		// Stage 2: 2-byte filter
		resumePos = resultPosition(result)
		if resumePos > 0 {
			haystack = haystack[resumePos:]
		}

		result = indexFold2ByteRaw(haystack, needle, off1, off2-off1)
	}

	if !resultExceeded(result) {
		pos := resultPosition(result)
		if pos >= 0 {
			return pos + resumePos
		}
		return -1
	}

	// Stage 3: Rabin-Karp fallback (folds both strings internally)
	resumePos2 := resultPosition(result)
	if resumePos2 > 0 {
		haystack = haystack[resumePos2:]
		resumePos += resumePos2
	}

	pos := indexFoldRabinKarp(haystack, needle)
	if pos >= 0 {
		return pos + resumePos
	}
	return -1
}

// IndexExactModular performs case-sensitive substring search using staged kernels.
func IndexExactModular(haystack, needle string) int {
	n := len(needle)
	if n == 0 {
		return 0
	}
	if len(haystack) < n {
		return -1
	}

	// Use fixed positions: first byte and last byte (maximum spread)
	// Fall back to middle byte if first==last (e.g., quoted strings like "num")
	off1 := 0
	off2 := n - 1
	if n > 2 && needle[0] == needle[n-1] {
		off2 = n / 2
	}

	var result uint64
	var resumePos int

	// For short needles, skip 1-byte stage (overhead not worth it)
	// For longer needles, 1-byte filter helps reduce false positives
	if n <= 16 {
		result = indexExact2Byte(haystack, needle, off1, off2-off1)
	} else {
		// Stage 1: 1-byte filter
		result = indexExact1Byte(haystack, needle, off1)

		if !resultExceeded(result) {
			return resultPosition(result)
		}

		// Stage 2: 2-byte filter
		resumePos = resultPosition(result)
		if resumePos > 0 {
			haystack = haystack[resumePos:]
		}

		result = indexExact2Byte(haystack, needle, off1, off2-off1)
	}

	if !resultExceeded(result) {
		pos := resultPosition(result)
		if pos >= 0 {
			return pos + resumePos
		}
		return -1
	}

	// Stage 3: Fallback
	resumePos2 := resultPosition(result)
	if resumePos2 > 0 {
		haystack = haystack[resumePos2:]
		resumePos += resumePos2
	}

	// For short needles, use stdlib's brute-force (faster than RK)
	// For long needles, use SIMD Rabin-Karp
	var pos int
	if n <= 8 {
		pos = strings.Index(haystack, needle)
	} else {
		pos = indexExactRabinKarp(haystack, needle)
	}
	if pos >= 0 {
		return pos + resumePos
	}
	return -1
}

// SearcherModular provides pre-computed rare byte search using staged kernels.
func (s Searcher) IndexModular(haystack string) int {
	if len(s.raw) == 0 {
		return 0
	}
	if len(haystack) < len(s.raw) {
		return -1
	}

	if s.caseSensitive {
		return indexExactModularWithOffsets(haystack, s.raw, s.off1, s.off2)
	}
	return indexFoldModularWithOffsets(haystack, s.norm, s.off1, s.off2)
}

func indexFoldModularWithOffsets(haystack, normNeedle string, off1, off2 int) int {
	// Stage 1: 1-byte
	result := indexFold1Byte(haystack, normNeedle, off1)

	if !resultExceeded(result) {
		return resultPosition(result)
	}

	// Stage 2: 2-byte
	resumePos := resultPosition(result)
	if resumePos > 0 {
		haystack = haystack[resumePos:]
	}

	result = indexFold2Byte(haystack, normNeedle, off1, off2-off1)

	if !resultExceeded(result) {
		pos := resultPosition(result)
		if pos >= 0 {
			return pos + resumePos
		}
		return -1
	}

	// Stage 3: Fallback
	resumePos2 := resultPosition(result)
	if resumePos2 > 0 {
		haystack = haystack[resumePos2:]
		resumePos += resumePos2
	}

	// For short needles, use brute-force (faster than RK setup)
	// For long needles, use SIMD Rabin-Karp
	var pos int
	if len(normNeedle) <= 8 {
		pos = indexFoldBruteForce(haystack, normNeedle)
	} else {
		pos = indexFoldRabinKarp(haystack, normNeedle)
	}
	if pos >= 0 {
		return pos + resumePos
	}
	return -1
}

// indexFoldBruteForce is a simple brute-force case-insensitive search.
// Faster than Rabin-Karp for short needles due to lower setup overhead.
func indexFoldBruteForce(haystack, normNeedle string) int {
	n := len(normNeedle)
	for i := 0; i <= len(haystack)-n; i++ {
		if EqualFold(haystack[i:i+n], normNeedle) {
			return i
		}
	}
	return -1
}

func indexExactModularWithOffsets(haystack, needle string, off1, off2 int) int {
	// Stage 1: 1-byte
	result := indexExact1Byte(haystack, needle, off1)

	if !resultExceeded(result) {
		return resultPosition(result)
	}

	// Stage 2: 2-byte
	resumePos := resultPosition(result)
	if resumePos > 0 {
		haystack = haystack[resumePos:]
	}

	result = indexExact2Byte(haystack, needle, off1, off2-off1)

	if !resultExceeded(result) {
		pos := resultPosition(result)
		if pos >= 0 {
			return pos + resumePos
		}
		return -1
	}

	// Stage 3: Fallback
	resumePos2 := resultPosition(result)
	if resumePos2 > 0 {
		haystack = haystack[resumePos2:]
		resumePos += resumePos2
	}

	// For short needles, use stdlib's brute-force (faster than RK)
	// For long needles, use SIMD Rabin-Karp
	var pos int
	if len(needle) <= 8 {
		pos = strings.Index(haystack, needle)
	} else {
		pos = indexExactRabinKarp(haystack, needle)
	}
	if pos >= 0 {
		return pos + resumePos
	}
	return -1
}
