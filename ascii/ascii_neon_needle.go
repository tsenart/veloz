//go:build !noasm && arm64

package ascii

// indexFoldNeedleNEON is the optimized NEON implementation for case-insensitive
// substring search. It uses a 1-byte fast path with inline cutover to 2-byte mode.
// Starts by searching for rare1 only (faster scan). When false positives exceed
// the threshold (4 + bytes_scanned>>8), it switches to 2-byte filtering inline.
//
// Parameters:
//   - haystack: the string to search
//   - rare1: the rarest byte in needle (case-normalized)
//   - off1: offset of rare1 within needle
//   - rare2: second rarest byte in needle (case-normalized)
//   - off2: offset of rare2 within needle
//   - normNeedle: lowercase-normalized needle for verification
//
//go:noescape
func indexFoldNeedleNEON(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
