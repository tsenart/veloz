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
	needle := MakeNeedle(needleStr)

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
				benchSink = SearchNeedle(haystack, needle)
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
	needle := MakeNeedle(needleStr)

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
				benchSink = SearchNeedle(haystack, needle)
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
				benchSink = SearchNeedle(jsonHaystack, jsonNeedle)
			}
		})
	}

	// All same char (worst case for 1-byte search)
	sameCharNeedleStr := "aab"
	sameCharNeedle := MakeNeedle(sameCharNeedleStr)

	for _, s := range sizes {
		sameCharHaystack := strings.Repeat("a", s.size) + "aab"

		b.Run("SameChar-"+s.name+"/SearchNeedle", func(b *testing.B) {
			b.SetBytes(int64(len(sameCharHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = SearchNeedle(sameCharHaystack, sameCharNeedle)
			}
		})
	}
}

// BenchmarkThresholdSweep tests various sizes around the 32/128-byte loop cutover.
func BenchmarkThresholdSweep(b *testing.B) {
	sizes := []int{
		256, 512, 768, 1024, 1280, 1536, 1792, 2048, 2304, 2560, 3072, 4096, 8192,
	}

	needle := MakeNeedle("quartz") // letter needle

	for _, size := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", size/24)

		b.Run(fmt.Sprintf("%dB/NEON", size), func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNEON(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
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
	needle := MakeNeedle(needleStr)

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
				benchSink = SearchNeedle(haystack, needle)
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
				benchSink = SearchNeedle(haystack, needle)
			}
		})
	}
}


