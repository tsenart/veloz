//go:build arm64

package ascii

import "strings"

// indexFoldNeedleIndexByte uses Go's IndexByte for the main scan,
// then verifies case-insensitively. This should match Go's scan speed.
func indexFoldNeedleIndexByte(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int {
	needleLen := len(normNeedle)
	if needleLen == 0 {
		return 0
	}
	if len(haystack) < needleLen {
		return -1
	}

	// Search for rare1 at offset off1
	// We need to match both upper and lower case
	rare1Upper := rare1
	rare1Lower := rare1
	if rare1 >= 'A' && rare1 <= 'Z' {
		rare1Lower = rare1 | 0x20
	} else if rare1 >= 'a' && rare1 <= 'z' {
		rare1Upper = rare1 &^ 0x20
	}

	searchEnd := len(haystack) - needleLen + 1
	pos := off1

	for pos < searchEnd {
		// Use IndexByte to find next occurrence of rare1Upper
		idxU := strings.IndexByte(haystack[pos:searchEnd+off1], rare1Upper)
		idxL := -1
		if rare1Upper != rare1Lower {
			idxL = strings.IndexByte(haystack[pos:searchEnd+off1], rare1Lower)
		}

		// Find the first match
		var idx int
		if idxU < 0 && idxL < 0 {
			return -1
		} else if idxU < 0 {
			idx = idxL
		} else if idxL < 0 {
			idx = idxU
		} else if idxU < idxL {
			idx = idxU
		} else {
			idx = idxL
		}

		candidate := pos + idx - off1
		if candidate < 0 {
			pos = pos + idx + 1
			continue
		}
		if candidate >= searchEnd {
			return -1
		}

		// Verify the needle case-insensitively
		if equalFoldAt(haystack, candidate, normNeedle) {
			return candidate
		}

		pos = pos + idx + 1
	}

	return -1
}

// equalFoldAt checks if haystack[pos:pos+len(needle)] equals needle case-insensitively
func equalFoldAt(haystack string, pos int, needle string) bool {
	for i := 0; i < len(needle); i++ {
		h := haystack[pos+i]
		n := needle[i]
		if h == n {
			continue
		}
		// Normalize to uppercase
		if h >= 'a' && h <= 'z' {
			h -= 32
		}
		if h != n {
			return false
		}
	}
	return true
}
