//go:build !noasm && arm64

package ascii

import (
	"strings"
	"testing"
)

var benchSink int

// =============================================================================
// BenchmarkSearch: Unified comprehensive benchmark for all search implementations
//
// Naming: BenchmarkSearch/mode=exact/scenario=notfound/size=1KB/impl=stdlib
// This enables easy benchstat comparison with:
//   benchstat -filter '/scenario:notfound' old.txt new.txt
//   benchstat -filter '/impl:stdlib' old.txt new.txt
// =============================================================================

func BenchmarkSearch(b *testing.B) {
	type benchCase struct {
		scenario string
		size     string
		haystack string
		needle   string
	}

	name := func(scenario, size, impl string) string {
		return "scenario=" + scenario + "/size=" + size + "/impl=" + impl
	}

	// Generate comprehensive test cases
	cases := []benchCase{
		// Pure scan (no match) - tests raw throughput
		{"notfound", "1KB", strings.Repeat("abcdefghijklmnoprstuvwy ", 43), "quartz"},
		{"notfound", "64KB", strings.Repeat("abcdefghijklmnoprstuvwy ", 2730), "quartz"},
		{"notfound", "1MB", strings.Repeat("abcdefghijklmnoprstuvwy ", 43690), "quartz"},

		// Match at end - tests full scan + verification
		{"match_end", "1KB", strings.Repeat("abcdefghijklmnoprstuvwy ", 42) + "xylophone", "xylophone"},
		{"match_end", "64KB", strings.Repeat("abcdefghijklmnoprstuvwy ", 2728) + "xylophone", "xylophone"},
		{"match_end", "1MB", strings.Repeat("abcdefghijklmnoprstuvwy ", 43688) + "xylophone", "xylophone"},

		// Match at start - tests early exit
		{"match_start", "1KB", "xylophone" + strings.Repeat("abcdefghijklmnoprstuvwy ", 42), "xylophone"},

		// Match in middle
		{"match_mid", "1KB", strings.Repeat("x", 500) + "needle" + strings.Repeat("y", 500), "needle"},

		// JSON-like data (high false positives from quotes)
		{"json", "1KB", strings.Repeat(`{"k":"v"},`, 100) + `{"num":1}`, `"num"`},
		{"json", "64KB", strings.Repeat(`{"k":"v"},`, 6500) + `{"num":1}`, `"num"`},

		// Periodic patterns (stress 2-byte filter)
		{"periodic", "1KB", strings.Repeat("abcd", 250) + "abce", "abce"},

		// Same char (worst case - triggers Rabin-Karp fallback)
		{"samechar", "1KB", strings.Repeat("a", 1000) + "aab", "aab"},
		{"samechar", "64KB", strings.Repeat("a", 64000) + "aab", "aab"},

		// Rare bytes (best case - few false positives)
		{"rarebyte", "1KB", strings.Repeat("abcdefghijklmnoprstuvwy ", 42) + "quartz", "quartz"},
		{"rarebyte", "64KB", strings.Repeat("abcdefghijklmnoprstuvwy ", 2728) + "quartz", "quartz"},

		// Different needle lengths
		{"needle3", "1KB", strings.Repeat("x", 1000) + "abc", "abc"},
		{"needle8", "1KB", strings.Repeat("x", 1000) + "abcdefgh", "abcdefgh"},
		{"needle16", "1KB", strings.Repeat("x", 1000) + "abcdefghijklmnop", "abcdefghijklmnop"},

		// =============================================================================
		// Edge cases for skip1Byte heuristic testing
		// These test bytes below 240 threshold but very common in specific corpora
		// =============================================================================

		// Log timestamps: '2' (rank 204) is common in logs but below 240 threshold
		// Should stress Stage 1 when searching for date patterns
		{"logdate", "1KB", strings.Repeat("2024-01-15T10:30:45.123Z INFO Processing request\n", 20) + "2024-99-99", "2024-99"},
		{"logdate", "64KB", strings.Repeat("2024-01-15T10:30:45.123Z INFO Processing request\n", 1280) + "2024-99-99", "2024-99"},

		// Hex data: '0' (rank 208) and hex chars common in dumps
		// Tests patterns starting with '0x' which should trigger Stage 1
		{"hexdata", "1KB", strings.Repeat("0x0000 0x1234 0xABCD 0xFFFF\n", 35) + "0xDEAD", "0xDEAD"},
		{"hexdata", "64KB", strings.Repeat("0x0000 0x1234 0xABCD 0xFFFF\n", 2275) + "0xDEAD", "0xDEAD"},

		// Code-like text: '{' (rank 182) common in code, 'c' (rank 238) just below 240
		// Tests brace-heavy patterns
		{"codebraces", "1KB", strings.Repeat("{\"key\": \"value\"}\n", 60) + "{NOTFOUND}", "{NOTFOUND}"},
		{"codebraces", "64KB", strings.Repeat("{\"key\": \"value\"}\n", 3840) + "{NOTFOUND}", "{NOTFOUND}"},

		// DNA sequences: 'A', 'T', 'C', 'G' with varying corpus distributions
		// 'A' (rank 191), 'T' (rank 188), 'C' (rank 194), 'G' (rank 161) - all below threshold
		{"dna", "1KB", strings.Repeat("ATCGATCGATCG", 83) + "ZZZZZ", "ZZZZZ"},
		{"dna", "64KB", strings.Repeat("ATCGATCGATCG", 5333) + "ZZZZZ", "ZZZZZ"},

		// Digits-heavy: searching in numeric data where digits are common
		// Tests '1' (rank 220) at start - just below 240 threshold
		{"digits", "1KB", strings.Repeat("123456789012345678901234567890\n", 32) + "1999999", "1999999"},
		{"digits", "64KB", strings.Repeat("123456789012345678901234567890\n", 2065) + "1999999", "1999999"},
	}

	// Case-sensitive implementations
	b.Run("mode=exact", func(b *testing.B) {
		for _, tc := range cases {
			// strings.Index (stdlib baseline)
			b.Run(name(tc.scenario, tc.size, "stdlib"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = strings.Index(tc.haystack, tc.needle)
				}
			})

			// Index (ad-hoc)
			b.Run(name(tc.scenario, tc.size, "Index"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = Index(tc.haystack, tc.needle)
				}
			})

			// Searcher with pre-computed rare bytes (case-sensitive)
			searcher := NewSearcher(tc.needle, true)
			b.Run(name(tc.scenario, tc.size, "Searcher"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = searcher.Index(tc.haystack)
				}
			})

			// Searcher with corpus-computed ranks (optimal rare byte selection)
			ranks := buildRankTable(tc.haystack)
			corpusSearcher := NewSearcherWithRanks(tc.needle, ranks[:], true)
			b.Run(name(tc.scenario, tc.size, "Searcher_corpus"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = corpusSearcher.Index(tc.haystack)
				}
			})
		}
	})

	// Case-insensitive implementations
	b.Run("mode=fold", func(b *testing.B) {
		for _, tc := range cases {
			// IndexFold (ad-hoc)
			b.Run(name(tc.scenario, tc.size, "IndexFold"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = IndexFold(tc.haystack, tc.needle)
				}
			})

			// Searcher (pre-computed, case-insensitive)
			searcher := NewSearcher(tc.needle, false)
			b.Run(name(tc.scenario, tc.size, "Searcher"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = searcher.Index(tc.haystack)
				}
			})

			// Searcher with corpus-computed ranks (optimal rare byte selection)
			ranks := buildRankTable(tc.haystack)
			corpusSearcher := NewSearcherWithRanks(tc.needle, ranks[:], false)
			b.Run(name(tc.scenario, tc.size, "Searcher_corpus"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = corpusSearcher.Index(tc.haystack)
				}
			})
		}
	})
}
