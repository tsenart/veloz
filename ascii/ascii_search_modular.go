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
func IndexFoldModular(haystack, needle string) int {
	n := len(needle)
	if n == 0 {
		return 0
	}
	if len(haystack) < n {
		return -1
	}

	// Use first + last byte (max spread), or first + middle if first==last
	first := toLower(needle[0])
	last := toLower(needle[n-1])
	off2 := n - 1
	if n > 2 && first == last {
		off2 = n / 2
	}

	// Decide strategy: skip 1-byte filter for pathological patterns
	// Pathological patterns:
	// 1. first == last (like "aab", quoted strings like "num")
	// 2. first byte is a very common letter (a,e,i,o,u,t,n,s,r - top 9 by frequency)
	skip1Byte := first == last || (first >= 'a' && first <= 'z' && byteRank[first] > 240)

	var result uint64
	var resumePos int

	if !skip1Byte {
		// Stage 1: 1-byte filter (fast scan, adaptive threshold)
		result = indexFold1ByteRaw(haystack, needle, 0)
		if !resultExceeded(result) {
			return resultPosition(result)
		}
		resumePos = resultPosition(result)
		if resumePos > 0 {
			haystack = haystack[resumePos:]
		}
	}

	// Stage 2: 2-byte filter (more selective)
	result = indexFold2ByteRaw(haystack, needle, 0, off2)
	if !resultExceeded(result) {
		pos := resultPosition(result)
		if pos >= 0 {
			return pos + resumePos
		}
		return -1
	}

	// Stage 3: Rabin-Karp fallback
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

	// Use first + last byte (max spread), or first + middle if first==last
	first := needle[0]
	off2 := n - 1
	if n > 2 && first == needle[n-1] {
		off2 = n / 2
	}

	// Skip 1-byte filter for pathological patterns:
	// 1. first == last (like "aab", quoted strings)
	// 2. first byte is a very common letter
	skip1Byte := first == needle[n-1] || (first >= 'a' && first <= 'z' && byteRank[first] > 240)

	var result uint64
	var resumePos int

	if !skip1Byte {
		// Stage 1: 1-byte filter (fast scan, adaptive threshold)
		result = indexExact1Byte(haystack, needle, 0)
		if !resultExceeded(result) {
			return resultPosition(result)
		}
		resumePos = resultPosition(result)
		if resumePos > 0 {
			haystack = haystack[resumePos:]
		}
	}

	// Stage 2: 2-byte filter (more selective)
	result = indexExact2Byte(haystack, needle, 0, off2)
	if !resultExceeded(result) {
		pos := resultPosition(result)
		if pos >= 0 {
			return pos + resumePos
		}
		return -1
	}

	// Stage 3: Rabin-Karp fallback
	resumePos2 := resultPosition(result)
	if resumePos2 > 0 {
		haystack = haystack[resumePos2:]
		resumePos += resumePos2
	}

	pos := indexExactRabinKarp(haystack, needle)
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
	// Searcher already selected rare bytes via corpus analysis or selectRarePairFull.
	// Only skip 1-byte for the pathological case where both offsets are the same.
	skip1Byte := off1 == off2

	var result uint64
	var resumePos int

	if !skip1Byte {
		result = indexFold1Byte(haystack, normNeedle, off1)
		if !resultExceeded(result) {
			return resultPosition(result)
		}
		resumePos = resultPosition(result)
		if resumePos > 0 {
			haystack = haystack[resumePos:]
		}
	}

	// Stage 2: 2-byte
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
	// Searcher already selected rare bytes. Only skip 1-byte if offsets are the same.
	skip1Byte := off1 == off2

	var result uint64
	var resumePos int

	if !skip1Byte {
		result = indexExact1Byte(haystack, needle, off1)
		if !resultExceeded(result) {
			return resultPosition(result)
		}
		resumePos = resultPosition(result)
		if resumePos > 0 {
			haystack = haystack[resumePos:]
		}
	}

	// Stage 2: 2-byte
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
