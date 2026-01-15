//go:build !noasm && arm64

package ascii

import (
	"fmt"
	"strings"
	"testing"
)

var benchSink int

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

	needleStr := "quartz"
	needle := NewSearcher(needleStr, false)

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24)

		b.Run(s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run(s.name+"/IndexFold", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFold(haystack, needleStr)
			}
		})

		b.Run(s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
			}
		})

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
	needle := NewSearcher(needleStr, false)

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24) + needleStr

		b.Run(s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run(s.name+"/IndexFold", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFold(haystack, needleStr)
			}
		})

		b.Run(s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
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
	jsonNeedle := NewSearcher(jsonNeedleStr, false)

	for _, s := range sizes {
		jsonHaystack := strings.Repeat(jsonPattern, s.size/len(jsonPattern)) + `{"num":999}`

		b.Run("JSON-"+s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(jsonHaystack, jsonNeedleStr)
			}
		})

		b.Run("JSON-"+s.name+"/IndexFold", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFold(jsonHaystack, jsonNeedleStr)
			}
		})

		b.Run("JSON-"+s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = jsonNeedle.Index(jsonHaystack)
			}
		})
	}

	// All same char (worst case for 1-byte search)
	sameCharNeedleStr := "aab"
	sameCharNeedle := NewSearcher(sameCharNeedleStr, false)

	for _, s := range sizes {
		sameCharHaystack := strings.Repeat("a", s.size) + "aab"

		b.Run("SameChar-"+s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(sameCharHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = sameCharNeedle.Index(sameCharHaystack)
			}
		})
	}
}

// BenchmarkThresholdSweep tests various sizes around the 32/128-byte loop cutover.
func BenchmarkThresholdSweep(b *testing.B) {
	sizes := []int{
		256, 512, 768, 1024, 1280, 1536, 1792, 2048, 2304, 2560, 3072, 4096, 8192,
	}

	needle := NewSearcher("quartz", false) // letter needle

	for _, size := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", size/24)

		b.Run(fmt.Sprintf("%dB/NEON", size), func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNEON(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(fmt.Sprintf("%dB/Go", size), func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, "quartz")
			}
		})
	}
}

// BenchmarkCutoverContinue tests the optimization where 2-byte mode continues
// from current position instead of restarting from the beginning.
// This matters when cutover happens late in a large haystack.
func BenchmarkCutoverContinue(b *testing.B) {
	// Large haystack with rare characters (no false positives) for first ~50KB
	// Then dense false positives that trigger cutover, followed by match
	prefix := strings.Repeat("x", 50000) // 50KB of no-match chars
	falsePos := strings.Repeat("h", 500) // 500 'h' chars = false positives for 'H'
	suffix := "HHHHHHHH0"                // The actual match
	haystack := prefix + falsePos + suffix

	needle := NewSearcher("HHHHHHHH0", false)
	expected := len(prefix) + len(falsePos)

	b.SetBytes(int64(len(haystack)))
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		result := needle.Index(haystack)
		if result != expected {
			b.Fatalf("wrong result: got %d, want %d", result, expected)
		}
	}
}

// BenchmarkNonLetterNeedle tests non-letter rare bytes (uses faster VAND-free path).
func BenchmarkNonLetterNeedle(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	// Needle with digits (non-letter rare bytes)
	needleStr := "12345"
	needle := NewSearcher(needleStr, false)

	for _, s := range sizes {
		// Haystack without digits (pure scan, no match)
		haystack := strings.Repeat("abcdefghijklmnopqrstuvwxyz", s.size/26)

		b.Run("PureScan-"+s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run("PureScan-"+s.name+"/IndexFold", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFold(haystack, needleStr)
			}
		})

		b.Run("PureScan-"+s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
			}
		})
	}

	// Match at end
	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnopqrstuvwxyz", s.size/26) + needleStr

		b.Run("MatchEnd-"+s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run("MatchEnd-"+s.name+"/IndexFold", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFold(haystack, needleStr)
			}
		})

		b.Run("MatchEnd-"+s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
			}
		})
	}
}

// BenchmarkCaseSensitive compares case-sensitive search variants.
func BenchmarkCaseSensitive(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	needleStr := "xylophone"
	needle := NewSearcher(needleStr, true) // case-sensitive

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24) + needleStr

		b.Run(s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run(s.name+"/Searcher.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
			}
		})
	}
}

// BenchmarkCaseSensitiveFair uses a needle where first byte IS in haystack.
// This makes strings.Index do similar work (scanning with false positives).
func BenchmarkCaseSensitiveFair(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	// "elephant" starts with 'e' which IS in the haystack pattern.
	// Both strings.Index and Searcher will have false positives to handle.
	needleStr := "elephant"
	needle := NewSearcher(needleStr, true) // case-sensitive

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24) + needleStr

		b.Run(s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run(s.name+"/Searcher.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
			}
		})
	}
}

// BenchmarkCaseSensitiveNoMatch tests pure scan (no match in haystack).
// Uses needle with first byte NOT in haystack for apples-to-apples comparison.
func BenchmarkCaseSensitiveNoMatch(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"64KB", 64 * 1024},
		{"1MB", 1024 * 1024},
	}

	// "zzz123" has 'z' as first byte which is NOT in haystack.
	// Both should scan at full speed with no false positives.
	needleStr := "zzz123"
	needle := NewSearcher(needleStr, true) // case-sensitive

	for _, s := range sizes {
		// Haystack has no 'z' or digits
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24)

		b.Run(s.name+"/strings.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, needleStr)
			}
		})

		b.Run(s.name+"/Searcher.Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = needle.Index(haystack)
			}
		})
	}
}
