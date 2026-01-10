//go:build !noasm && arm64

package ascii

// indexFoldNeedleAdaptive uses 1-byte fast path with inline cutover to 2-byte mode.
// It starts by searching for rare1 only (faster scan). When false positives exceed
// the threshold (4 + bytes_scanned>>4), it switches to 2-byte filtering inline.
//
// Parameters match IndexFoldNeedle for compatibility:
//   - haystack: the string to search
//   - rare1: the rarest byte in needle (case-normalized)
//   - off1: offset of rare1 within needle
//   - rare2: second rarest byte in needle (case-normalized)
//   - off2: offset of rare2 within needle
//   - normNeedle: uppercase-normalized needle for verification
//
//go:noescape
func indexFoldNeedleAdaptive(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
