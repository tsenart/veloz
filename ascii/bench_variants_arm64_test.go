//go:build !noasm && arm64

package ascii

import (
	"strings"
	"testing"
)

func BenchmarkIndexAnyVariants(b *testing.B) {
	sizes := []int{16, 64, 256, 1024, 1024 * 1024}

	for _, size := range sizes {
		data := strings.Repeat("x", size-1) + "y"
		chars := "y"
		b0, b1, b2, b3 := buildBitset(chars)

		b.Run(strings.ReplaceAll(b.Name(), "BenchmarkIndexAnyVariants/", "")+"/go-"+itoa(size), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				indexAnyGo(data, chars)
			}
			b.SetBytes(int64(size))
		})

		b.Run(strings.ReplaceAll(b.Name(), "BenchmarkIndexAnyVariants/", "")+"/neon-bitset-"+itoa(size), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				indexAnyNeonBitset(data, b0, b1, b2, b3)
			}
			b.SetBytes(int64(size))
		})

		if hasSVE2 {
			b.Run(strings.ReplaceAll(b.Name(), "BenchmarkIndexAnyVariants/", "")+"/sve2-"+itoa(size), func(b *testing.B) {
				for i := 0; i < b.N; i++ {
					indexAnySve2(data, chars)
				}
				b.SetBytes(int64(size))
			})
		}
	}
}

var benchSink int

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// BenchmarkSearchNeedleVariants compares NEON vs NEON-128B vs SVE2.
func BenchmarkSearchNeedleVariants(b *testing.B) {
	commonHaystack := strings.Repeat("the quick brown fox jumps over the dog ", 100) + "zephyr"
	rareHaystack := strings.Repeat("abcdefghijklmnopqrstuvw ", 100) + "xylophone"
	jsonHaystack := strings.Repeat(`{"key":"value","cnt":123},`, 100) + `{"num":999}`
	largeHaystack := strings.Repeat("abcdefghijklmnopqrstuvw ", 1024*1024/24) + "xylophone"

	testCases := []struct {
		name     string
		haystack string
		needle   string
	}{
		{"common-4KB", commonHaystack, "zephyr"},
		{"rare-2KB", rareHaystack, "xylophone"},
		{"json-2KB", jsonHaystack, `"num"`},
		{"large-1MB", largeHaystack, "xylophone"},
	}

	// Pure scan benchmark (no verification - needle not found)
	pureScanHaystack := strings.Repeat("abcdefghijklmnoprstuvwy ", 1024*1024/24)
	pureScanNeedle := MakeNeedle("quartz")

	b.Run("pure-scan-1MB/NEON", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = IndexFoldNeedle(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-128B", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeon128(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/Go-Index", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = strings.Index(pureScanHaystack, "quartz")
		}
	})
	if hasSVE2 {
		b.Run("pure-scan-1MB/SVE2", func(b *testing.B) {
			b.SetBytes(int64(len(pureScanHaystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleSve2(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
			}
		})
	}

	for _, tc := range testCases {
		n := MakeNeedle(tc.needle)

		b.Run(tc.name+"/NEON", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = IndexFoldNeedle(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			}
		})

		b.Run(tc.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			}
		})

		if hasSVE2 {
			b.Run(tc.name+"/SVE2", func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = indexFoldNeedleSve2(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				}
			})
		}

		b.Run(tc.name+"/Adaptive", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = SearchNeedle(tc.haystack, n)
			}
		})
	}
}

func TestNeon128BJSON(t *testing.T) {
	jsonHaystack := strings.Repeat(`{"key":"value","cnt":123},`, 100) + `{"num":999}`
	n := MakeNeedle(`"num"`)
	t.Logf("needle: rare1=%c@%d, rare2=%c@%d, norm=%q", n.rare1, n.off1, n.rare2, n.off2, n.norm)
	t.Logf("haystack len: %d", len(jsonHaystack))

	result := indexFoldNeedleNeon128(jsonHaystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
	t.Logf("result: %d", result)

	expected := strings.Index(strings.ToLower(jsonHaystack), strings.ToLower(`"num"`))
	if result != expected {
		t.Errorf("got %d, want %d", result, expected)
	}
}
