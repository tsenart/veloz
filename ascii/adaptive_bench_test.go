//go:build !noasm && arm64

package ascii

import (
	"strings"
	"testing"
)

// Phase 1.7: Comprehensive Benchmark Coverage

// BenchmarkPureScan tests raw scan throughput without matches (best case).
func BenchmarkPureScan(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
		{"16MB", 16 * 1024 * 1024},
	}

	// Needle that won't match: uses Q and Z which aren't in haystack
	needle := MakeNeedle("quartz")

	for _, s := range sizes {
		// Pure ASCII haystack without Q or Z
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24)

		b.Run(s.name+"/Adaptive", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleAdaptive(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/NEON-64B", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/Go-Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, "quartz")
			}
		})

		if hasSVE && !hasSVE2 {
			b.Run(s.name+"/SVE-G3", func(b *testing.B) {
				b.SetBytes(int64(len(haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = indexFoldNeedleSveG3(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
				}
			})
		}
	}
}

// BenchmarkMatchAtEnd tests full scan + verification (typical case).
func BenchmarkMatchAtEnd(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	needleStr := "xylophone"
	needle := MakeNeedle(needleStr)

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24) + needleStr

		b.Run(s.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/Go-Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})
	}
}

// BenchmarkMatchAtStart tests early exit performance.
func BenchmarkMatchAtStart(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	needleStr := "xylophone"
	needle := MakeNeedle(needleStr)

	for _, s := range sizes {
		haystack := needleStr + strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24)

		b.Run(s.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})
	}
}

// BenchmarkHighFalsePositive tests worst-case scenarios.
func BenchmarkHighFalsePositive(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"2KB", 2 * 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	// JSON-like data (many " characters)
	jsonPattern := `{"key":"value","cnt":123},`
	jsonNeedleStr := `"num"`
	jsonNeedle := MakeNeedle(jsonNeedleStr)

	for _, s := range sizes {
		jsonHaystack := strings.Repeat(jsonPattern, s.size/len(jsonPattern)) + `{"num":999}`

		b.Run("JSON-"+s.name+"/Adaptive", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleAdaptive(jsonHaystack, jsonNeedle.rare1, jsonNeedle.off1, jsonNeedle.rare2, jsonNeedle.off2, jsonNeedle.norm)
			}
		})

		b.Run("JSON-"+s.name+"/NEON-64B", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(jsonHaystack, jsonNeedle.rare1, jsonNeedle.off1, jsonNeedle.rare2, jsonNeedle.off2, jsonNeedle.norm)
			}
		})

		b.Run("JSON-"+s.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(jsonHaystack, jsonNeedle.rare1, jsonNeedle.off1, jsonNeedle.rare2, jsonNeedle.off2, jsonNeedle.norm)
			}
		})

		b.Run("JSON-"+s.name+"/Go-Index", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(jsonHaystack, jsonNeedleStr)
			}
		})

		if hasSVE && !hasSVE2 {
			b.Run("JSON-"+s.name+"/SVE-G3", func(b *testing.B) {
				b.SetBytes(int64(len(jsonHaystack)))
				for i := 0; i < b.N; i++ {
					benchSink = indexFoldNeedleSveG3(jsonHaystack, jsonNeedle.rare1, jsonNeedle.off1, jsonNeedle.rare2, jsonNeedle.off2, jsonNeedle.norm)
				}
			})
		}
	}

	// All same char (worst case for 1-byte search)
	sameCharNeedleStr := "aab"
	sameCharNeedle := MakeNeedle(sameCharNeedleStr)

	for _, s := range sizes {
		sameCharHaystack := strings.Repeat("a", s.size) + "aab"

		b.Run("SameChar-"+s.name+"/Adaptive", func(b *testing.B) {
			b.SetBytes(int64(len(sameCharHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleAdaptive(sameCharHaystack, sameCharNeedle.rare1, sameCharNeedle.off1, sameCharNeedle.rare2, sameCharNeedle.off2, sameCharNeedle.norm)
			}
		})

		b.Run("SameChar-"+s.name+"/NEON-64B", func(b *testing.B) {
			b.SetBytes(int64(len(sameCharHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(sameCharHaystack, sameCharNeedle.rare1, sameCharNeedle.off1, sameCharNeedle.rare2, sameCharNeedle.off2, sameCharNeedle.norm)
			}
		})

		b.Run("SameChar-"+s.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(sameCharHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(sameCharHaystack, sameCharNeedle.rare1, sameCharNeedle.off1, sameCharNeedle.rare2, sameCharNeedle.off2, sameCharNeedle.norm)
			}
		})
	}
}

// BenchmarkCutoverScenarios measures transition overhead.
func BenchmarkCutoverScenarios(b *testing.B) {
	// Scenario 1: High FP in first 1KB, then clean 64KB
	highFP := strings.Repeat("Q", 1024)
	clean := strings.Repeat("a", 64*1024)
	needle1 := MakeNeedle("QZXY")
	haystack1 := highFP + clean + "QZXY"

	b.Run("HighFP-then-Clean/NEON", func(b *testing.B) {
		b.SetBytes(int64(len(haystack1)))
		for i := 0; i < b.N; i++ {
			benchSink = IndexFoldNeedle(haystack1, needle1.rare1, needle1.off1, needle1.rare2, needle1.off2, needle1.norm)
		}
	})

	b.Run("HighFP-then-Clean/NEON-128B", func(b *testing.B) {
		b.SetBytes(int64(len(haystack1)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeon128(haystack1, needle1.rare1, needle1.off1, needle1.rare2, needle1.off2, needle1.norm)
		}
	})

	// Scenario 2: Clean 64KB, then high FP 1KB
	haystack2 := clean + highFP + "QZXY"

	b.Run("Clean-then-HighFP/NEON", func(b *testing.B) {
		b.SetBytes(int64(len(haystack2)))
		for i := 0; i < b.N; i++ {
			benchSink = IndexFoldNeedle(haystack2, needle1.rare1, needle1.off1, needle1.rare2, needle1.off2, needle1.norm)
		}
	})

	b.Run("Clean-then-HighFP/NEON-128B", func(b *testing.B) {
		b.SetBytes(int64(len(haystack2)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeon128(haystack2, needle1.rare1, needle1.off1, needle1.rare2, needle1.off2, needle1.norm)
		}
	})

	// Scenario 3: One false positive per 16-byte chunk (simulates sparse failures)
	var sparseBuilder strings.Builder
	for i := 0; i < 4096; i++ {
		if i%16 == 0 {
			sparseBuilder.WriteString("Qaaa") // Match rare1 'Q' but fail verification
			for j := 0; j < 12; j++ {
				sparseBuilder.WriteByte('a')
			}
		} else {
			for j := 0; j < 16; j++ {
				sparseBuilder.WriteByte('a')
			}
		}
	}
	sparseBuilder.WriteString("QZXY")
	haystack3 := sparseBuilder.String()

	b.Run("SparseFailures/NEON", func(b *testing.B) {
		b.SetBytes(int64(len(haystack3)))
		for i := 0; i < b.N; i++ {
			benchSink = IndexFoldNeedle(haystack3, needle1.rare1, needle1.off1, needle1.rare2, needle1.off2, needle1.norm)
		}
	})

	b.Run("SparseFailures/NEON-128B", func(b *testing.B) {
		b.SetBytes(int64(len(haystack3)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeon128(haystack3, needle1.rare1, needle1.off1, needle1.rare2, needle1.off2, needle1.norm)
		}
	})
}

// BenchmarkNeedleLengths measures performance across needle lengths.
func BenchmarkNeedleLengths(b *testing.B) {
	lengths := []int{2, 4, 8, 16, 32, 64}
	haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", 1024*1024/24)

	for _, needleLen := range lengths {
		needleStr := strings.Repeat("x", needleLen)
		// Make it more interesting
		if needleLen > 1 {
			nb := []byte(needleStr)
			nb[0] = 'Q'
			nb[needleLen-1] = 'Z'
			needleStr = string(nb)
		}

		// Append needle for a match
		hs := haystack + needleStr
		needle := MakeNeedle(needleStr)

		b.Run(itoa(needleLen)+"B/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(hs)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(hs, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(itoa(needleLen)+"B/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(hs)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(hs, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})
	}
}

// BenchmarkRareByteScenarios compares performance with different rare byte distributions.
func BenchmarkRareByteScenarios(b *testing.B) {
	haystack := strings.Repeat("the quick brown fox jumps over the lazy dog ", 1024*64/44)

	scenarios := []struct {
		name   string
		needle string
	}{
		{"rare_punctuation", "foo::bar"},
		{"common_letters", "letter"},
		{"rare_equals_rare", "::foo::"},
		{"all_rare", "qzxy"},
	}

	for _, sc := range scenarios {
		needle := MakeNeedle(sc.needle)
		hs := haystack + sc.needle

		b.Run(sc.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(hs)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(hs, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(sc.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(hs)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(hs, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})
	}
}
