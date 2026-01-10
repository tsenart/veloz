//go:build !noasm && arm64

package ascii

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// testVariant represents a NEON implementation variant to test.
type testVariant struct {
	name string
	fn   func(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
}

// allVariants returns the NEON variants for comprehensive testing.
func allVariants() []testVariant {
	variants := []testVariant{
		{"NEON", IndexFoldNeedle},              // 2-byte filtering, 17 GB/s consistent
		{"NEON-128B", indexFoldNeedleNeon128},  // 1-byte filtering, 36.5 GB/s pure scan
		{"Adaptive", indexFoldNeedleAdaptive},  // 1-byte with 2-byte cutover
	}
	if hasSVE && !hasSVE2 {
		variants = append(variants, testVariant{"SVE-G3", indexFoldNeedleSveG3})
	}
	return variants
}

// Phase 1.1: Needle Length Variations
// Tests needle lengths that stress different code paths in SIMD implementations.

func TestNeedleLengthVariations(t *testing.T) {
	lengths := []int{1, 2, 3, 4, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65}

	for _, needleLen := range lengths {
		t.Run(fmt.Sprintf("len%d", needleLen), func(t *testing.T) {
			// Create a needle of the required length using unique chars
			needle := strings.Repeat("x", needleLen)
			if needleLen > 1 {
				// Make needle more interesting: "xQZx...x"
				b := []byte(needle)
				b[1] = 'Q' // rare byte
				if needleLen > 2 {
					b[needleLen-1] = 'Z' // rare byte at end
				}
				needle = string(b)
			}

			// Build haystack: prefix + needle + suffix
			prefix := strings.Repeat("a", 256)
			suffix := strings.Repeat("b", 256)
			haystack := prefix + needle + suffix

			n := MakeNeedle(needle)
			want := indexFoldGo(haystack, needle)

			for _, v := range allVariants() {
				t.Run(v.name, func(t *testing.T) {
					got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
					if got != want {
						t.Errorf("%s: got %d, want %d (needle=%q)", v.name, got, want, needle)
					}
				})
			}

			// Also test SearchNeedle (the main entry point)
			if got := SearchNeedle(haystack, n); got != want {
				t.Errorf("SearchNeedle: got %d, want %d", got, want)
			}
		})
	}
}

// TestNeedleLengthNotFound tests that we correctly return -1 for various needle lengths.
func TestNeedleLengthNotFound(t *testing.T) {
	lengths := []int{1, 2, 3, 4, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65}
	haystack := strings.Repeat("abcdefghijklmnop", 100) // 1600 bytes, no 'Q' or 'Z'

	for _, needleLen := range lengths {
		t.Run(fmt.Sprintf("len%d", needleLen), func(t *testing.T) {
			// Needle uses chars not in haystack
			needle := strings.Repeat("Q", needleLen)
			if needleLen > 1 {
				b := []byte(needle)
				b[needleLen-1] = 'Z'
				needle = string(b)
			}

			n := MakeNeedle(needle)

			for _, v := range allVariants() {
				t.Run(v.name, func(t *testing.T) {
					got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
					if got != -1 {
						t.Errorf("%s: got %d, want -1 (needle=%q)", v.name, got, needle)
					}
				})
			}
		})
	}
}

// Phase 1.2: Alignment Tests
// Test matches at every position modulo chunk size (16/32/64/128).

func TestAlignmentVariations(t *testing.T) {
	needle := "QZXY" // 4 bytes with rare chars
	n := MakeNeedle(needle)

	// Test all alignments 0-127
	for align := 0; align <= 127; align++ {
		t.Run(fmt.Sprintf("align%d", align), func(t *testing.T) {
			// Build haystack: align bytes of padding + needle + suffix
			prefix := bytes.Repeat([]byte{'a'}, align)
			suffix := bytes.Repeat([]byte{'b'}, 256)
			haystack := string(prefix) + needle + string(suffix)

			want := indexFoldGo(haystack, needle)
			if want != align {
				t.Fatalf("reference implementation broken: got %d, want %d", want, align)
			}

			for _, v := range allVariants() {
				got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

// TestAlignmentWithLongNeedle tests alignments with longer needles.
func TestAlignmentWithLongNeedle(t *testing.T) {
	needle := "QZXYQZXYQZXYQZXY" // 16 bytes exactly one SIMD chunk
	n := MakeNeedle(needle)

	for align := 0; align <= 127; align++ {
		t.Run(fmt.Sprintf("align%d", align), func(t *testing.T) {
			prefix := bytes.Repeat([]byte{'a'}, align)
			suffix := bytes.Repeat([]byte{'b'}, 256)
			haystack := string(prefix) + needle + string(suffix)

			want := indexFoldGo(haystack, needle)

			for _, v := range allVariants() {
				got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

// Phase 1.3: Chunk Boundary Straddle Tests
// Test matches that span chunk boundaries (16, 32, 64, 128 bytes).

func TestChunkBoundaryStraddle(t *testing.T) {
	boundaries := []int{16, 32, 64, 128}
	needleLens := []int{4, 8, 16}

	for _, boundary := range boundaries {
		for _, needleLen := range needleLens {
			// Test match starting 1, 2, 3 bytes before boundary
			for offset := 1; offset <= 3; offset++ {
				startPos := boundary - offset
				if startPos < 0 {
					continue
				}

				t.Run(fmt.Sprintf("boundary%d/needleLen%d/offset%d", boundary, needleLen, offset), func(t *testing.T) {
					// Create needle
					needle := strings.Repeat("Q", needleLen)
					if needleLen > 1 {
						b := []byte(needle)
						b[needleLen-1] = 'Z'
						needle = string(b)
					}
					n := MakeNeedle(needle)

					// Build haystack: startPos bytes of 'a' + needle + suffix
					prefix := bytes.Repeat([]byte{'a'}, startPos)
					suffix := bytes.Repeat([]byte{'b'}, 256)
					haystack := string(prefix) + needle + string(suffix)

					want := indexFoldGo(haystack, needle)
					if want != startPos {
						t.Fatalf("reference: got %d, want %d", want, startPos)
					}

					for _, v := range allVariants() {
						got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
						if got != want {
							t.Errorf("%s: got %d, want %d", v.name, got, want)
						}
					}
				})
			}
		}
	}
}

// TestChunkBoundaryExactEnd tests when needle ends exactly at a boundary.
func TestChunkBoundaryExactEnd(t *testing.T) {
	boundaries := []int{16, 32, 64, 128}
	needleLens := []int{4, 8, 16}

	for _, boundary := range boundaries {
		for _, needleLen := range needleLens {
			startPos := boundary - needleLen
			if startPos < 0 {
				continue
			}

			t.Run(fmt.Sprintf("boundary%d/needleLen%d", boundary, needleLen), func(t *testing.T) {
				needle := strings.Repeat("Q", needleLen)
				if needleLen > 1 {
					b := []byte(needle)
					b[needleLen-1] = 'Z'
					needle = string(b)
				}
				n := MakeNeedle(needle)

				prefix := bytes.Repeat([]byte{'a'}, startPos)
				suffix := bytes.Repeat([]byte{'b'}, 256)
				haystack := string(prefix) + needle + string(suffix)

				want := indexFoldGo(haystack, needle)

				for _, v := range allVariants() {
					got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
					if got != want {
						t.Errorf("%s: got %d, want %d", v.name, got, want)
					}
				}
			})
		}
	}
}

// Phase 1.4: High False-Positive Density Tests
// Test workloads with many candidates that fail verification.

func TestHighFalsePositiveJSON(t *testing.T) {
	// JSON-like data with many quote characters
	jsonData := strings.Repeat(`{"key":"value","cnt":123},`, 100)
	needle := `"num"` // Will match many " characters

	testHighFP(t, "JSON", jsonData, needle)
}

func TestHighFalsePositiveDNA(t *testing.T) {
	// DNA-like data with repeated patterns
	dnaData := strings.Repeat("ACGTACGT", 500)
	needle := "GATTACA"

	testHighFP(t, "DNA", dnaData, needle)
}

func TestHighFalsePositiveHex(t *testing.T) {
	// Hex-like data
	hexData := strings.Repeat("0123456789ABCDEF", 250)
	needle := "DEADBEEF"

	testHighFP(t, "Hex", hexData, needle)
}

func TestHighFalsePositiveSameChar(t *testing.T) {
	// All same character - worst case for 1-byte search
	data := strings.Repeat("a", 4000)
	needle := "aaa"

	testHighFP(t, "SameChar", data, needle)
}

func TestHighFalsePositiveAlternating(t *testing.T) {
	// Alternating pattern
	data := strings.Repeat("ab", 2000)
	needle := "aba"

	testHighFP(t, "Alternating", data, needle)
}

func TestHighFalsePositiveQuoteHeavy(t *testing.T) {
	// Many quote characters
	data := strings.Repeat(`"x"`, 1000)
	needle := `"ab"`

	testHighFP(t, "QuoteHeavy", data, needle)
}

func testHighFP(t *testing.T, name, haystack, needle string) {
	// Append needle at the end so we have a match
	haystack = haystack + needle

	n := MakeNeedle(needle)
	want := indexFoldGo(haystack, needle)

	for _, v := range allVariants() {
		t.Run(v.name, func(t *testing.T) {
			got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Errorf("%s/%s: got %d, want %d", name, v.name, got, want)
			}
		})
	}

	// Also test with no match
	t.Run("NoMatch", func(t *testing.T) {
		haystackNoMatch := haystack[:len(haystack)-len(needle)] // Remove the needle
		noMatchNeedle := "QZXY123QZXY"                          // Definitely not in any of the test data
		nm := MakeNeedle(noMatchNeedle)

		for _, v := range allVariants() {
			got := v.fn(haystackNoMatch, nm.rare1, nm.off1, nm.rare2, nm.off2, nm.norm)
			if got != -1 {
				t.Errorf("%s/%s/NoMatch: got %d, want -1", name, v.name, got)
			}
		}
	})
}

// Phase 1.5: Cutover-Specific Tests
// Test scenarios designed to trigger the adaptive cutover.

func TestCutoverEveryPositionMatchesRare1(t *testing.T) {
	// Haystack where every position matches rare1 but verification fails
	// This is the worst case for 1-byte search
	haystack := strings.Repeat("Q", 4000) + "QZXY"
	needle := "QZXY"

	n := MakeNeedle(needle)
	want := indexFoldGo(haystack, needle)

	for _, v := range allVariants() {
		t.Run(v.name, func(t *testing.T) {
			got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Errorf("%s: got %d, want %d", v.name, got, want)
			}
		})
	}
}

func TestCutoverOneMatchPerChunk(t *testing.T) {
	// Haystack with failures at positions 0, 16, 32, 48... (one per chunk)
	var buf bytes.Buffer
	for i := 0; i < 256; i++ {
		if i%16 == 0 {
			buf.WriteString("Qaaa") // Matches rare1 'Q' but fails verification
			buf.WriteString(strings.Repeat("a", 12))
		} else {
			buf.WriteString(strings.Repeat("a", 16))
		}
	}
	buf.WriteString("QZXY") // Actual match
	haystack := buf.String()
	needle := "QZXY"

	n := MakeNeedle(needle)
	want := indexFoldGo(haystack, needle)

	for _, v := range allVariants() {
		t.Run(v.name, func(t *testing.T) {
			got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Errorf("%s: got %d, want %d", v.name, got, want)
			}
		})
	}
}

func TestCutoverClusteredThenClean(t *testing.T) {
	// High false positives in first 1KB, then clean
	highFP := strings.Repeat("Q", 1024)      // Every byte matches rare1
	clean := strings.Repeat("a", 10*1024)    // No matches
	haystack := highFP + clean + "QZXY"
	needle := "QZXY"

	n := MakeNeedle(needle)
	want := indexFoldGo(haystack, needle)

	for _, v := range allVariants() {
		t.Run(v.name, func(t *testing.T) {
			got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Errorf("%s: got %d, want %d", v.name, got, want)
			}
		})
	}
}

func TestCutoverCleanThenHighFP(t *testing.T) {
	// Clean for 10KB, then high false positives
	clean := strings.Repeat("a", 10*1024)
	highFP := strings.Repeat("Q", 1024)
	haystack := clean + highFP + "QZXY"
	needle := "QZXY"

	n := MakeNeedle(needle)
	want := indexFoldGo(haystack, needle)

	for _, v := range allVariants() {
		t.Run(v.name, func(t *testing.T) {
			got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Errorf("%s: got %d, want %d", v.name, got, want)
			}
		})
	}
}

// Phase 1.6: Rare Byte Selection Edge Cases

func TestRareByteAllCommonLetters(t *testing.T) {
	// Needles with all common letters (e, t, a, o, i, n, s, h, r)
	needles := []string{"letter", "between", "state", "there", "another"}

	haystack := strings.Repeat("the quick brown fox jumps over ", 100)

	for _, needle := range needles {
		t.Run(needle, func(t *testing.T) {
			hs := haystack + needle // Append needle for a match
			n := MakeNeedle(needle)
			want := indexFoldGo(hs, needle)

			for _, v := range allVariants() {
				got := v.fn(hs, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

func TestRareByteRarePunctuation(t *testing.T) {
	// Needles with rare punctuation
	needles := []string{"foo::bar", "a.b.c", "x->y", "a[0]b"}

	haystack := strings.Repeat("normal text here ", 100)

	for _, needle := range needles {
		t.Run(needle, func(t *testing.T) {
			hs := haystack + needle
			n := MakeNeedle(needle)
			want := indexFoldGo(hs, needle)

			for _, v := range allVariants() {
				got := v.fn(hs, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

func TestRareByteRare1EqualsRare2(t *testing.T) {
	// Needles where rare1 == rare2 (same character appears twice)
	needles := []string{"::foo::", "ababa", "//comment//", "[x][y]"}

	haystack := strings.Repeat("normal text here ", 100)

	for _, needle := range needles {
		t.Run(needle, func(t *testing.T) {
			hs := haystack + needle
			n := MakeNeedle(needle)
			t.Logf("%s: rare1=%c@%d, rare2=%c@%d", needle, n.rare1, n.off1, n.rare2, n.off2)

			want := indexFoldGo(hs, needle)

			for _, v := range allVariants() {
				got := v.fn(hs, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

func TestRareByteSingleDistinctChar(t *testing.T) {
	// Needles with only one distinct character
	needles := []string{"aaa", "xxxxx", "eeee"}

	haystack := strings.Repeat("bcd ", 500)

	for _, needle := range needles {
		t.Run(needle, func(t *testing.T) {
			hs := haystack + needle
			n := MakeNeedle(needle)
			want := indexFoldGo(hs, needle)

			for _, v := range allVariants() {
				got := v.fn(hs, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

func TestRareByteHighBit(t *testing.T) {
	// Needles with high-bit bytes (non-ASCII in needle)
	needles := []string{"\x7f\x7f", "caf\xe9", "na\xefve"}

	haystack := strings.Repeat("ascii only here ", 100)

	for _, needle := range needles {
		t.Run(fmt.Sprintf("%q", needle), func(t *testing.T) {
			hs := haystack + needle
			n := MakeNeedle(needle)
			want := indexFoldGo(hs, needle)

			for _, v := range allVariants() {
				got := v.fn(hs, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

func TestRareByteShortCommonNeedle(t *testing.T) {
	// Short needles (2-3 chars) with common chars
	needles := []string{"th", "an", "er", "the", "and", "ing"}

	haystack := strings.Repeat("xyz xyz xyz ", 100)

	for _, needle := range needles {
		t.Run(needle, func(t *testing.T) {
			hs := haystack + needle
			n := MakeNeedle(needle)
			want := indexFoldGo(hs, needle)

			for _, v := range allVariants() {
				got := v.fn(hs, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

// TestCaseFolding verifies case-insensitive matching works correctly.
func TestCaseFoldingVariations(t *testing.T) {
	testCases := []struct {
		haystack string
		needle   string
		want     int
	}{
		{"HELLO WORLD", "world", 6},
		{"hello world", "WORLD", 6},
		{"HeLLo WoRLd", "world", 6},
		{"abcXYZdef", "xyz", 3},
		{"ABCxyzDEF", "XYZ", 3},
		{"The Quick Brown Fox", "QUICK", 4},
		{"THE QUICK BROWN FOX", "quick", 4},
	}

	for _, tc := range testCases {
		t.Run(tc.needle, func(t *testing.T) {
			n := MakeNeedle(tc.needle)

			for _, v := range allVariants() {
				got := v.fn(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != tc.want {
					t.Errorf("%s: got %d, want %d", v.name, got, tc.want)
				}
			}
		})
	}
}

// TestEmptyAndShortHaystack tests edge cases with very short haystacks.
func TestEmptyAndShortHaystack(t *testing.T) {
	needle := "test"
	n := MakeNeedle(needle)

	testCases := []struct {
		name     string
		haystack string
		want     int
	}{
		{"empty", "", -1},
		{"shorter_than_needle", "tes", -1},
		{"exact_match", "test", 0},
		{"one_char_padding", "xtest", 1},
		{"15_bytes", "xxxxxxxxxxxtestxxx"[:15], -1}, // 15 bytes, less than 16
		{"16_bytes_match", "xxxxxxxxxxxttest", 11},  // 16 bytes exactly
		{"17_bytes_match", "xxxxxxxxxxxxttest", 12}, // 17 bytes
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Only test variants that handle short strings correctly
			got := SearchNeedle(tc.haystack, n)
			want := indexFoldGo(tc.haystack, needle)
			if got != want {
				t.Errorf("SearchNeedle: got %d, want %d (haystack=%q)", got, want, tc.haystack)
			}
		})
	}
}

// TestMultipleMatchesFirstFound verifies we return the FIRST match.
func TestMultipleMatchesFirstFound(t *testing.T) {
	needle := "xyz"
	n := MakeNeedle(needle)

	haystack := "abcxyzdefxyzghixyz"
	want := 3 // First occurrence

	for _, v := range allVariants() {
		t.Run(v.name, func(t *testing.T) {
			got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Errorf("%s: got %d, want %d", v.name, got, want)
			}
		})
	}
}

// TestMatchAtVeryEnd tests when the match is at the very end of the haystack.
func TestMatchAtVeryEnd(t *testing.T) {
	sizes := []int{16, 32, 64, 128, 256, 1024, 4096}
	needle := "QZXY"
	n := MakeNeedle(needle)

	for _, size := range sizes {
		t.Run(fmt.Sprintf("size%d", size), func(t *testing.T) {
			haystack := strings.Repeat("a", size-len(needle)) + needle
			want := size - len(needle)

			for _, v := range allVariants() {
				got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}

// TestMatchAtVeryStart tests when the match is at position 0.
func TestMatchAtVeryStart(t *testing.T) {
	sizes := []int{16, 32, 64, 128, 256, 1024, 4096}
	needle := "QZXY"
	n := MakeNeedle(needle)

	for _, size := range sizes {
		t.Run(fmt.Sprintf("size%d", size), func(t *testing.T) {
			haystack := needle + strings.Repeat("a", size-len(needle))
			want := 0

			for _, v := range allVariants() {
				got := v.fn(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				if got != want {
					t.Errorf("%s: got %d, want %d", v.name, got, want)
				}
			}
		})
	}
}
