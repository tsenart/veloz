//go:build !noasm && arm64

package ascii

// searchWithRareBytes delegates to the handwritten NEON assembly.
func searchWithRareBytes(hay, normNeedle string, rare1 byte, off1 int, rare2 byte, off2 int) int {
	return indexFoldNeedleNEON(hay, rare1, off1, rare2, off2, normNeedle)
}

// searchWithRareBytesGoDriver implements adaptive case-insensitive substring search
// using Go driver + C primitives (IndexByteFoldNeon, IndexTwoBytesFoldNeon).
//
// Strategy (matching handwritten ASM):
// 1. Start with 1-byte fast path using IndexByteFoldNeon to find rare1 candidates
// 2. Verify matches with EqualFold
// 3. Track verification failures - when failures > 4 + (bytes_scanned >> 8), switch to 2-byte mode
// 4. 2-byte mode uses IndexTwoBytesFoldNeon for dual-byte filtering (lower false positive rate)
//
// The >> 8 threshold (1 extra failure per 256 bytes) was empirically determined
// to balance pure scan speed (~80-90% of strings.Index) with high false-positive handling.
func searchWithRareBytesGoDriver(hay, normNeedle string, rare1 byte, off1 int, rare2 byte, off2 int) int {
	needleLen := len(normNeedle)
	if needleLen == 0 {
		return 0
	}
	if needleLen > len(hay) {
		return -1
	}

	searchLen := len(hay) - needleLen + 1
	if searchLen <= 0 {
		return -1
	}

	// Determine if rare bytes are letters (for case-insensitive matching)
	isLetter1 := isLetter(rare1)
	isLetter2 := isLetter(rare2)

	// Start at off1 position for 1-byte search
	pos := 0
	failures := 0

	// 1-BYTE MODE: Fast path with single rare byte
	for pos < searchLen {
		// Search for rare1 starting at current position + off1
		searchStart := pos + off1
		searchEnd := searchLen + off1 // We can search up to this position
		if searchStart >= searchEnd {
			break
		}

		// Find next candidate where rare1 matches
		idx := IndexByteFoldNeon(hay[searchStart:searchEnd], rare1, boolToInt64(isLetter1))
		if idx < 0 {
			break // No more candidates
		}

		// Convert back to haystack position
		candidate := pos + idx
		if candidate >= searchLen {
			break
		}

		// Verify the full needle at this position
		if EqualFold(hay[candidate:candidate+needleLen], normNeedle) {
			return candidate
		}

		// Verification failed - track it
		failures++

		// Check cutover threshold: failures > 4 + (bytes_scanned >> 8)
		bytesScanned := candidate + 1
		threshold := 4 + (bytesScanned >> 8)
		if failures > threshold {
			// Cutover to 2-byte mode from current position
			return search2ByteMode(hay[candidate:], normNeedle, rare1, off1, isLetter1, rare2, off2, isLetter2, candidate)
		}

		// Continue from next position
		pos = candidate + 1
	}

	return -1
}

// search2ByteMode uses dual-byte filtering for lower false positive rate.
// startOffset is the offset in the original haystack where this search starts.
func search2ByteMode(hay, normNeedle string, rare1 byte, off1 int, isLetter1 bool, rare2 byte, off2 int, isLetter2 bool, startOffset int) int {
	needleLen := len(normNeedle)
	searchLen := len(hay) - needleLen + 1
	if searchLen <= 0 {
		return -1
	}

	pos := 0
	for pos < searchLen {
		// Find position where both rare1 at off1 AND rare2 at off2 match
		// The C function searches from pos, loading hay[pos+off1] and hay[pos+off2]
		remaining := searchLen - pos
		if remaining <= 0 {
			break
		}

		// We need to ensure we don't read past the end
		// The max offset we need to access is max(off1, off2) from any search position
		maxOff := off1
		if off2 > maxOff {
			maxOff = off2
		}

		// Adjust remaining to account for offset reads
		if pos+maxOff >= len(hay) {
			break
		}

		idx := IndexTwoBytesFoldNeon(hay[pos:], rare1, off1, boolToInt64(isLetter1), rare2, off2, boolToInt64(isLetter2))
		if idx < 0 {
			break
		}

		candidate := pos + idx
		if candidate >= searchLen {
			break
		}

		// Verify the full needle
		if EqualFold(hay[candidate:candidate+needleLen], normNeedle) {
			return startOffset + candidate
		}

		pos = candidate + 1
	}

	return -1
}

// isLetter returns true if b is an ASCII letter (a-z or A-Z).
func isLetter(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// boolToInt64 converts bool to int64 for C interop (gocc doesn't support bool).
func boolToInt64(b bool) int {
	if b {
		return 1
	}
	return 0
}

// indexFoldRabinKarp is a compatibility stub for tests.
// On arm64, we use the Go driver approach instead.
func indexFoldRabinKarp(a, b string) int {
	return indexFoldGo(a, b)
}

// IndexFoldNeedle is a compatibility wrapper for tests/benchmarks.
// It calls the new Go driver implementation.
func IndexFoldNeedle(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int {
	return searchWithRareBytes(haystack, normNeedle, rare1, off1, rare2, off2)
}
