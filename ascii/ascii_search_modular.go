//go:build !noasm && arm64

package ascii

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
// Uses first byte for stage 1, then middle/last byte for stage 2 if needed.
// Uses Raw variants that fold needle on-the-fly (no normalizeASCII overhead).
func IndexFoldModular(haystack, needle string) int {
	n := len(needle)
	if n == 0 {
		return 0
	}
	if len(haystack) < n {
		return -1
	}

	// Stage 1: 1-byte filter on first byte (Raw: folds needle on-the-fly)
	off1 := 0
	result := indexFold1ByteRaw(haystack, needle, off1)

	if !resultExceeded(result) {
		return resultPosition(result)
	}

	// Stage 2: 2-byte filter, pick second byte from middle or end
	off2 := n - 1
	if n > 2 {
		off2 = n / 2
	}
	resumePos := resultPosition(result)
	if resumePos > 0 {
		haystack = haystack[resumePos:]
	}

	result = indexFold2ByteRaw(haystack, needle, off1, off2-off1)

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

	// Stage 1: 1-byte filter on first byte
	off1 := 0
	result := indexExact1Byte(haystack, needle, off1)

	if !resultExceeded(result) {
		return resultPosition(result)
	}

	// Stage 2: 2-byte filter
	off2 := n - 1
	if n > 2 {
		off2 = n / 2
	}
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

	// Stage 3: Rabin-Karp
	resumePos2 := resultPosition(result)
	if resumePos2 > 0 {
		haystack = haystack[resumePos2:]
		resumePos += resumePos2
	}

	pos := indexFoldRabinKarp(haystack, normNeedle)
	if pos >= 0 {
		return pos + resumePos
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

	// Stage 3: Rabin-Karp
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
