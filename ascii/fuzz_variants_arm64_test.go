//go:build !noasm && arm64

package ascii

import (
	"strings"
	"testing"
)

// FuzzIndexAnyAllVariants tests all implementation variants against each other.
// This ensures SVE2, NEON, and Go implementations all produce identical results.
func FuzzIndexAnyAllVariants(f *testing.F) {
	f.Add("hello world", " ")
	f.Add("abcdefghij", "xyz")
	f.Add(strings.Repeat("a", 100), "b")
	f.Add(strings.Repeat("x", 1000), "abc")
	f.Add("", "a")
	f.Add("abc", "")
	f.Add("test", strings.Repeat("x", 20)) // >16 chars

	f.Fuzz(func(t *testing.T, s, chars string) {
		want := indexAnyGo(s, chars)

		// Test IndexAny (the main entry point)
		if got := IndexAny(s, chars); got != want {
			t.Fatalf("IndexAny(%q, %q) = %d, want %d", s, chars, got, want)
		}

		// Test IndexAnyCharSet
		cs := MakeCharSet(chars)
		if got := IndexAnyCharSet(s, cs); got != want {
			t.Fatalf("IndexAnyCharSet(%q, %q) = %d, want %d", s, chars, got, want)
		}

		// Test NEON bitset directly (always available on arm64)
		if len(chars) > 0 {
			var bitset [4]uint64
			for i := 0; i < len(chars); i++ {
				c := chars[i]
				bitset[c>>6] |= 1 << (c & 63)
			}
			got := indexAnyNeonBitset(s, bitset[0], bitset[1], bitset[2], bitset[3])
			if got != want {
				t.Fatalf("indexAnyNeonBitset(%q, %q) = %d, want %d", s, chars, got, want)
			}
		}

		// Test SVE2 (if available)
		if hasSVE2 && len(chars) <= 64 && len(chars) > 0 {
			got := indexAnySve2(s, chars)
			if got != want {
				t.Fatalf("indexAnySve2(%q, %q) = %d, want %d", s, chars, got, want)
			}
		}
	})
}

// FuzzSearchNeedleAllVariants tests all SearchNeedle implementation variants against each other.
// This ensures SVE2, NEON, and Go implementations all produce identical results.
func FuzzSearchNeedleAllVariants(f *testing.F) {
	f.Add("the quick brown fox jumps over the lazy dog", "lazy")
	f.Add("HELLO WORLD", "world")
	f.Add(strings.Repeat("abcdefghij", 100), "xyz")
	f.Add(strings.Repeat("x", 1000), "xylophone")
	f.Add("", "a")
	f.Add("abc", "")
	f.Add("test", "TEST")
	f.Add("CaSe InSeNsItIvE", "insensitive")
	f.Add("JSON: {\"key\": \"value\"}", "key")

	f.Fuzz(func(t *testing.T, haystack, needle string) {
		// Reference: Go implementation
		want := indexFoldGo(haystack, needle)

		// Test IndexFold (NEON path)
		if got := IndexFold(haystack, needle); got != want {
			t.Fatalf("IndexFold(%q, %q) = %d, want %d", haystack, needle, got, want)
		}

		// Test SearchNeedle (dispatches to SVE2 or NEON based on CPU)
		n := MakeNeedle(needle)
		if got := SearchNeedle(haystack, n); got != want {
			t.Fatalf("SearchNeedle(%q, %q) = %d, want %d", haystack, needle, got, want)
		}

		// Test NEON path directly
		if len(needle) > 0 && len(haystack) >= 16 {
			got := IndexFoldNeedle(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Fatalf("IndexFoldNeedle(%q, %q) = %d, want %d", haystack, needle, got, want)
			}
		}

		// Test SVE2 path directly (if available)
		if hasSVE2 && len(needle) > 0 && len(haystack) >= 16 {
			got := indexFoldNeedleSve2(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Fatalf("indexFoldNeedleSve2(%q, %q) = %d, want %d", haystack, needle, got, want)
			}
		}

		// Test NEON-V2 (aligned loads variant)
		if len(needle) > 0 && len(haystack) >= 16 {
			got := indexFoldNeedleNeonV2(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Fatalf("indexFoldNeedleNeonV2(%q, %q) = %d, want %d", haystack, needle, got, want)
			}
		}

		// Test NEON-128B (128-byte loop variant)
		if len(needle) > 0 && len(haystack) >= 16 {
			got := indexFoldNeedleNeon128(haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			if got != want {
				t.Fatalf("indexFoldNeedleNeon128(%q, %q) = %d, want %d", haystack, needle, got, want)
			}
		}
	})
}
