package ascii

import (
	"fmt"
	"strings"
	"testing"
)

func TestIndexFoldV2_Basic(t *testing.T) {
	tests := []struct {
		hay, needle string
		want        int
	}{
		{"", "", 0},
		{"a", "", 0},
		{"", "a", -1},
		{"abc", "a", 0},
		{"abc", "b", 1},
		{"abc", "c", 2},
		{"abc", "d", -1},
		{"abc", "A", 0},
		{"abc", "B", 1},
		{"abc", "C", 2},
		{"ABC", "a", 0},
		{"ABC", "b", 1},
		{"ABC", "c", 2},
		{"hello world", "WORLD", 6},
		{"HELLO WORLD", "world", 6},
		{"hello WORLD", "o w", 4},
		{"abcdefghij", "FGH", 5},
		{strings.Repeat("x", 100) + "needle", "NEEDLE", 100},
		{strings.Repeat("x", 1000) + "needle", "NEEDLE", 1000},
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("%s/%s", truncate(tt.hay, 20), tt.needle), func(t *testing.T) {
			got := IndexFoldV2(tt.hay, tt.needle)
			if got != tt.want {
				t.Errorf("IndexFoldV2(%q, %q) = %d, want %d", tt.hay, tt.needle, got, tt.want)
			}
		})
	}
}

func TestIndexFoldV2_MatchesReference(t *testing.T) {
	testCases := []struct {
		hay, needle string
	}{
		{"abc", "bc"},
		{"abc", "bcd"},
		{"abc", ""},
		{"", "a"},
		{"0123abcd", "B"},
		{"xxxxxx", "01"},
		{"01xxxx", "01"},
		{"xx01xx", "01"},
		{"xxxx01", "01"},
		{strings.Repeat("a", 10000) + "aab", "aab"},
		{`{"key":"value","cnt":123},` + strings.Repeat(`{"key":"value","cnt":123},`, 100), `"num"`},
		{strings.Repeat(`{"key":"value","cnt":123},`, 100) + `{"num":999}`, `"num"`},
		{strings.Repeat("a", 100) + "aaaa", "aaaa"},
		{strings.Repeat("A", 100) + "AAAA", "aaaa"},
		{"xxxaaaaxxx", "aaaa"},
		{"xxxAAAAxxx", "aaaa"},
		{"xxx1111xxx", "1111"},
		{strings.Repeat("z", 50) + "zzzz", "zzzz"},
	}

	for _, tc := range testCases {
		want := indexFoldGo(tc.hay, tc.needle)
		got := IndexFoldV2(tc.hay, tc.needle)
		if got != want {
			t.Errorf("IndexFoldV2(%q..., %q) = %d, want %d",
				truncate(tc.hay, 30), tc.needle, got, want)
		}
	}
}

func TestSelectRarePairFast(t *testing.T) {
	tests := []struct {
		needle string
	}{
		{""},
		{"a"},
		{"ab"},
		{"abc"},
		{"hello"},
		{"the quick brown fox"},
		{`"num"`},
		{strings.Repeat("a", 100)},
		{strings.Repeat("x", 50) + "Q" + strings.Repeat("x", 50)},
		{"aaaa"},
		{"AAAA"},
		{"aAaA"},
		{"zzzz"},
		{"1111"},
		{"!!!!"},
	}

	for _, tt := range tests {
		t.Run(truncate(tt.needle, 20), func(t *testing.T) {
			rare1, off1, rare2, off2 := selectRarePairFast(tt.needle)

			if len(tt.needle) == 0 {
				return
			}

			// Verify offsets are in bounds
			if off1 < 0 || off1 >= len(tt.needle) {
				t.Errorf("off1=%d out of bounds for len=%d", off1, len(tt.needle))
			}
			if off2 < 0 || off2 >= len(tt.needle) {
				t.Errorf("off2=%d out of bounds for len=%d", off2, len(tt.needle))
			}

			// Verify off1 <= off2
			if off1 > off2 {
				t.Errorf("off1=%d > off2=%d", off1, off2)
			}

			// Verify bytes match positions
			if rare1 != toLower(tt.needle[off1]) {
				t.Errorf("rare1=%c doesn't match needle[%d]=%c", rare1, off1, tt.needle[off1])
			}
			if rare2 != toLower(tt.needle[off2]) {
				t.Errorf("rare2=%c doesn't match needle[%d]=%c", rare2, off2, tt.needle[off2])
			}

			t.Logf("needle=%q -> rare1=%c@%d, rare2=%c@%d", tt.needle, rare1, off1, rare2, off2)
		})
	}
}

func BenchmarkIndexFoldV2_vs_V1(b *testing.B) {
	sizes := []int{64, 256, 1024, 4096}
	needle := "needle"

	for _, size := range sizes {
		hay := strings.Repeat("x", size-6) + "NEEDLE"

		b.Run(fmt.Sprintf("V1/size=%d", size), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				IndexFold(hay, needle)
			}
		})

		b.Run(fmt.Sprintf("V2/size=%d", size), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				IndexFoldV2(hay, needle)
			}
		})
	}
}

func BenchmarkIndexFoldV2_NotFound(b *testing.B) {
	sizes := []int{64, 256, 1024, 4096}
	needle := "QXYZ" // rare bytes, won't be found

	for _, size := range sizes {
		hay := strings.Repeat("abcdefghij", size/10)

		b.Run(fmt.Sprintf("V1/size=%d", size), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				IndexFold(hay, needle)
			}
		})

		b.Run(fmt.Sprintf("V2/size=%d", size), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				IndexFoldV2(hay, needle)
			}
		})
	}
}

func BenchmarkIndexFoldV2_Comparison(b *testing.B) {
	sizes := []int{64, 256, 1024, 4096, 16384}
	needle := "needle"
	needleUpper := "NEEDLE"

	for _, size := range sizes {
		hay := strings.Repeat("x", size-6) + "NEEDLE"

		b.Run(fmt.Sprintf("V2/size=%d", size), func(b *testing.B) {
			b.SetBytes(int64(size))
			for i := 0; i < b.N; i++ {
				IndexFoldV2(hay, needle)
			}
		})

		b.Run(fmt.Sprintf("V1/size=%d", size), func(b *testing.B) {
			b.SetBytes(int64(size))
			for i := 0; i < b.N; i++ {
				IndexFold(hay, needle)
			}
		})

		b.Run(fmt.Sprintf("Go/size=%d", size), func(b *testing.B) {
			b.SetBytes(int64(size))
			for i := 0; i < b.N; i++ {
				indexFoldGo(hay, needle)
			}
		})

		b.Run(fmt.Sprintf("strings.Index/size=%d", size), func(b *testing.B) {
			b.SetBytes(int64(size))
			for i := 0; i < b.N; i++ {
				strings.Index(hay, needleUpper)
			}
		})
	}
}
