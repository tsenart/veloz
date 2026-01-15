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

			// IndexExactModular (ad-hoc, staged kernels)
			b.Run(name(tc.scenario, tc.size, "modular"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = IndexExactModular(tc.haystack, tc.needle)
				}
			})

			// Searcher with pre-computed rare bytes (case-sensitive)
			searcher := NewSearcher(tc.needle, true)
			b.Run(name(tc.scenario, tc.size, "searcher"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = searcher.Index(tc.haystack)
				}
			})

			// Searcher.IndexModular (pre-computed + staged kernels)
			b.Run(name(tc.scenario, tc.size, "searcher_mod"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = searcher.IndexModular(tc.haystack)
				}
			})

			// Searcher with corpus-computed ranks (optimal rare byte selection)
			ranks := buildRankTable(tc.haystack)
			corpusSearcher := NewSearcherWithRanks(tc.needle, ranks[:], true)
			b.Run(name(tc.scenario, tc.size, "corpus_mod"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = corpusSearcher.IndexModular(tc.haystack)
				}
			})
		}
	})

	// Case-insensitive implementations
	b.Run("mode=fold", func(b *testing.B) {
		for _, tc := range cases {
			// IndexFold (asm, rare-byte selection)
			b.Run(name(tc.scenario, tc.size, "asm"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = IndexFold(tc.haystack, tc.needle)
				}
			})

			// IndexFoldModular (staged kernels)
			b.Run(name(tc.scenario, tc.size, "modular"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = IndexFoldModular(tc.haystack, tc.needle)
				}
			})

			// Searcher (pre-computed, case-insensitive)
			searcher := NewSearcher(tc.needle, false)
			b.Run(name(tc.scenario, tc.size, "searcher"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = searcher.Index(tc.haystack)
				}
			})

			// Searcher.IndexModular
			b.Run(name(tc.scenario, tc.size, "searcher_mod"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = searcher.IndexModular(tc.haystack)
				}
			})

			// Searcher with corpus-computed ranks (optimal rare byte selection)
			ranks := buildRankTable(tc.haystack)
			corpusSearcher := NewSearcherWithRanks(tc.needle, ranks[:], false)
			b.Run(name(tc.scenario, tc.size, "corpus_mod"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = corpusSearcher.IndexModular(tc.haystack)
				}
			})

			// IndexFoldOriginal (for regression comparison)
			b.Run(name(tc.scenario, tc.size, "original"), func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = IndexFoldOriginal(tc.haystack, tc.needle)
				}
			})
		}
	})
}
