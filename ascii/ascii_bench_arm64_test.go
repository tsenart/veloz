//go:build !noasm && arm64

package ascii

import (
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

	needle := MakeNeedle("quartz")

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", s.size/24)

		b.Run(s.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNEON(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
			}
		})

		b.Run(s.name+"/Go-Index", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(haystack, "quartz")
			}
		})
	}
}

// BenchmarkMatchAtEndNEON tests full scan + verification (typical case).
func BenchmarkMatchAtEndNEON(b *testing.B) {
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
				benchSink = indexFoldNeedleNEON(haystack, needle.rare1, needle.off1, needle.rare2, needle.off2, needle.norm)
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

		b.Run("JSON-"+s.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNEON(jsonHaystack, jsonNeedle.rare1, jsonNeedle.off1, jsonNeedle.rare2, jsonNeedle.off2, jsonNeedle.norm)
			}
		})

		b.Run("JSON-"+s.name+"/Go-Index", func(b *testing.B) {
			b.SetBytes(int64(len(jsonHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = strings.Index(jsonHaystack, jsonNeedleStr)
			}
		})
	}

	// All same char (worst case for 1-byte search)
	sameCharNeedleStr := "aab"
	sameCharNeedle := MakeNeedle(sameCharNeedleStr)

	for _, s := range sizes {
		sameCharHaystack := strings.Repeat("a", s.size) + "aab"

		b.Run("SameChar-"+s.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(sameCharHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNEON(sameCharHaystack, sameCharNeedle.rare1, sameCharNeedle.off1, sameCharNeedle.rare2, sameCharNeedle.off2, sameCharNeedle.norm)
			}
		})
	}
}
