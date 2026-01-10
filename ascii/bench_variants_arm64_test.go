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

func BenchmarkIndexAnyVariantsMultiChar(b *testing.B) {
	data := strings.Repeat("\x01", 1023) + "\x00"
	allChars := "\x00\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOP"
	
	for _, charCount := range []int{1, 4, 8, 16, 32, 64} {
		chars := allChars[:charCount]
		b0, b1, b2, b3 := buildBitset(chars)
		
		b.Run("go-chars"+itoa(charCount), func(b *testing.B) {
			b.SetBytes(1024)
			for i := 0; i < b.N; i++ {
				benchSink = indexAnyGo(data, chars)
			}
		})
		


		b.Run("neon-bitset-chars"+itoa(charCount), func(b *testing.B) {
			b.SetBytes(1024)
			for i := 0; i < b.N; i++ {
				benchSink = indexAnyNeonBitset(data, b0, b1, b2, b3)
			}
		})

		b.Run("neon-bitset-full-chars"+itoa(charCount), func(b *testing.B) {
			b.SetBytes(1024)
			for i := 0; i < b.N; i++ {
				// Include bitset building like real IndexAny call
				var bs [4]uint64
				for j := 0; j < len(chars); j++ {
					c := chars[j]
					bs[c>>6] |= 1 << (c & 63)
				}
				benchSink = indexAnyNeonBitset(data, bs[0], bs[1], bs[2], bs[3])
			}
		})

		if hasSVE2 && charCount <= 64 {
			b.Run("sve2-chars"+itoa(charCount), func(b *testing.B) {
				b.SetBytes(1024)
				for i := 0; i < b.N; i++ {
					benchSink = indexAnySve2(data, chars)
				}
			})
		}
	}
}

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


func BenchmarkIndexAnySmallData(b *testing.B) {
	allChars := "\x00\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
	
	for _, dataSize := range []int{4, 8, 16, 32, 64} {
		data := strings.Repeat("\x01", dataSize-1) + "\x00"
		chars := allChars[:4]
		b0, b1, b2, b3 := buildBitset(chars)
		
		b.Run("go-"+itoa(dataSize)+"B", func(b *testing.B) {
			b.SetBytes(int64(dataSize))
			for i := 0; i < b.N; i++ {
				benchSink = indexAnyGo(data, chars)
			}
		})
		
		b.Run("neon-bitset-"+itoa(dataSize)+"B", func(b *testing.B) {
			b.SetBytes(int64(dataSize))
			for i := 0; i < b.N; i++ {
				benchSink = indexAnyNeonBitset(data, b0, b1, b2, b3)
			}
		})
		
		b.Run("neon-bitset-full-"+itoa(dataSize)+"B", func(b *testing.B) {
			b.SetBytes(int64(dataSize))
			for i := 0; i < b.N; i++ {
				var bs [4]uint64
				for j := 0; j < len(chars); j++ {
					c := chars[j]
					bs[c>>6] |= 1 << (c & 63)
				}
				benchSink = indexAnyNeonBitset(data, bs[0], bs[1], bs[2], bs[3])
			}
		})
	}
}

// BenchmarkSearchNeedleVariants compares NEON vs SVE2 implementations directly.
// All benchmarks have needle at END to measure full-scan throughput.
func BenchmarkSearchNeedleVariants(b *testing.B) {
	// Needle at end for accurate full-scan measurement
	commonHaystack := strings.Repeat("the quick brown fox jumps over the dog ", 100) + "zephyr"
	rareHaystack := strings.Repeat("abcdefghijklmnopqrstuvw ", 100) + "xylophone"
	jsonHaystack := strings.Repeat(`{"key":"value","cnt":123},`, 100) + `{"num":999}`

	// 1MB haystack for prefetch testing (exceeds L2 cache)
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
	pureScanNeedle := MakeNeedle("quartz") // Q and Z never appear
	
	b.Run("pure-scan-1MB/NEON", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = IndexFoldNeedle(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-Fast", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeonFast(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-Single", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeonSingle(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-Golike", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeonGolike(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-64B", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeon64(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-V2", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeonV2(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-128B", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeon128(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/NEON-Tight", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleNeonTight(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	b.Run("pure-scan-1MB/IndexByte", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = indexFoldNeedleIndexByte(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
		}
	})
	// NEON-Dual has a bounds bug - disabled for now
	// b.Run("pure-scan-1MB/NEON-Dual", func(b *testing.B) {
	// 	b.SetBytes(int64(len(pureScanHaystack)))
	// 	for i := 0; i < b.N; i++ {
	// 		benchSink = indexFoldNeedleNeonDual(pureScanHaystack, pureScanNeedle.rare1, pureScanNeedle.off1, pureScanNeedle.rare2, pureScanNeedle.off2, pureScanNeedle.norm)
	// 	}
	// })
	// Baseline: Go's strings.Index for comparison (case-sensitive)
	b.Run("pure-scan-1MB/Go-Index", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = strings.Index(pureScanHaystack, "quartz")
		}
	})
	// Go's IndexByte for true single-byte baseline
	b.Run("pure-scan-1MB/Go-IndexByte", func(b *testing.B) {
		b.SetBytes(int64(len(pureScanHaystack)))
		for i := 0; i < b.N; i++ {
			benchSink = strings.IndexByte(pureScanHaystack, 'q')
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

		b.Run(tc.name+"/NEON-64B", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon64(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			}
		})

		b.Run(tc.name+"/NEON-128B", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeon128(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			}
		})

		b.Run(tc.name+"/NEON-Fast", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = indexFoldNeedleNeonFast(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
			}
		})

		if hasSVE2 {
			b.Run(tc.name+"/SVE2", func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = indexFoldNeedleSve2(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				}
			})
			b.Run(tc.name+"/SVE2-Opt", func(b *testing.B) {
				b.SetBytes(int64(len(tc.haystack)))
				for i := 0; i < b.N; i++ {
					benchSink = indexFoldNeedleSve2Opt(tc.haystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
				}
			})
		}

		// Test adaptive dispatch (SearchNeedle chooses best path)
		b.Run(tc.name+"/Adaptive", func(b *testing.B) {
			b.SetBytes(int64(len(tc.haystack)))
			for i := 0; i < b.N; i++ {
				benchSink = SearchNeedle(tc.haystack, n)
			}
		})
	}
}

func TestNeon64BJSON(t *testing.T) {
	jsonHaystack := strings.Repeat(`{"key":"value","cnt":123},`, 100) + `{"num":999}`
	n := MakeNeedle(`"num"`)
	t.Logf("needle: rare1=%c@%d, rare2=%c@%d, norm=%q", n.rare1, n.off1, n.rare2, n.off2, n.norm)
	t.Logf("haystack len: %d", len(jsonHaystack))
	
	result := indexFoldNeedleNeon64(jsonHaystack, n.rare1, n.off1, n.rare2, n.off2, n.norm)
	t.Logf("result: %d", result)
	
	expected := strings.Index(strings.ToLower(jsonHaystack), strings.ToLower(`"num"`))
	if result != expected {
		t.Errorf("got %d, want %d", result, expected)
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

func TestAdaptiveDispatchJSON(t *testing.T) {
	// This needle has rare1 == rare2 == '"', which triggers high false positives in JSON
	n := MakeNeedle(`"num"`)
	
	// With the adaptive dispatch, short needles with rare1 == rare2 should use NEON
	// Verify the rare bytes are indeed the same
	if n.rare1 != n.rare2 {
		t.Logf("rare1=%c rare2=%c (different, will use SVE2)", n.rare1, n.rare2)
	} else {
		t.Logf("rare1=%c rare2=%c (same, should use NEON for short needles)", n.rare1, n.rare2)
		if len(n.raw) >= 8 {
			t.Logf("needle len=%d >= 8, will use SVE2", len(n.raw))
		} else {
			t.Logf("needle len=%d < 8, will use NEON", len(n.raw))
		}
	}
	
	// Verify the search still works correctly
	jsonHaystack := `{"key":"value","cnt":123},{"num":999}`
	idx := SearchNeedle(jsonHaystack, n)
	if idx != 27 {
		t.Errorf("SearchNeedle returned %d, expected 27", idx)
	}
}
