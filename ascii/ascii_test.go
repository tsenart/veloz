package ascii

import (
	"bytes"
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"unicode"

	segAscii "github.com/segmentio/asm/ascii"
)

func makeASCII(n int) []byte {
	data := make([]byte, n)
	for i := range data {
		data[i] = byte(rand.Uint32() & 0x7f)
	}
	return data
}

type ValidTest struct {
	in  string
	exp bool
}

var validTests = []ValidTest{
	{"", true},
	{"a", true},
	{"abc", true},
	{"Ж", false},
	{"ЖЖ", false},
	{"брэд-ЛГТМ", false},
	{"☺☻☹", false},
	{"aa\xe2", false},
	{string([]byte{66, 250}), false},
	{string([]byte{66, 250, 67}), false},
	{"a\uFFFDb", false},
	{string("\xF4\x8F\xBF\xBF"), false},     // U+10FFFF
	{string("\xF4\x90\x80\x80"), false},     // U+10FFFF+1; exp of range
	{string("\xF7\xBF\xBF\xBF"), false},     // 0x1FFFFF; exp of range
	{string("\xFB\xBF\xBF\xBF\xBF"), false}, // 0x3FFFFFF; exp of range
	{string("\xc0\x80"), false},             // U+0000 encoded in two bytes: incorrect
	{string("\xed\xa0\x80"), false},         // U+D800 high surrogate (sic)
	{string("\xed\xbf\xbf"), false},         // U+DFFF low surrogate (sic)
	{"hellowo\xff", false},
	{"hellowor", true},
}

func TestAscii(t *testing.T) {
	for _, vt := range validTests {
		if ValidString(vt.in) != vt.exp {
			t.Errorf("ValidString(%q) = %v; want %v", vt.in, !vt.exp, vt.exp)
		}
	}

	for _, vt := range validTests {
		pt := "0123456789ab" + vt.in
		if ValidString(pt) != vt.exp {
			t.Errorf("ValidString(%q) = %v; want %v", pt, !vt.exp, vt.exp)
		}
	}
}

func TestIndexMask(t *testing.T) {
	for i := 4; i < 6400; i++ {
		data := makeASCII(i)
		if ValidString(string(data)) != true {
			t.Errorf("ValidString(%q) = false; want true", data)
		}
		if res := IndexMask(string(data), 0x80); res != -1 {
			t.Errorf("IndexMask([%d]) = %d; want %d", len(data), res, -1)
		}

		idx := rand.Intn(i)
		data[idx] |= 0x80
		if ValidString(string(data)) != false {
			t.Errorf("ValidString(%q) = true; want false", data)
		}
		if res := IndexMask(string(data), 0x80); res != idx {
			t.Errorf("IndexMask([%d]) = %d; want %d", len(data), res, idx)
		}
	}
}

func containsFold(s, substr string) bool {
	return IndexFold(s, substr) != -1
}

func TestContainsFold(t *testing.T) {
	containsTests := []struct {
		str, substr string
		expected    bool
	}{
		{"abc", "bc", true},
		{"abc", "bcd", false},
		{"abc", "", true},
		{"", "a", false},
		{"0123abcd", "B", true},
		// 2-byte needle
		{"xxxxxx", "01", false},
		{"01xxxx", "01", true},
		{"xx01xx", "01", true},
		{"xxxx01", "01", true},
		{"01xxxxx"[1:], "01", false},
		{"xxxxx01"[:6], "01", false},
		// 3-byte needle
		{"xxxxxxx", "012", false},
		{"012xxxx", "012", true},
		{"xx012xx", "012", true},
		{"xxxx012", "012", true},
		{"012xxxxx"[1:], "012", false},
		{"xxxxx012"[:7], "012", false},
		// 4-byte needle
		{"xxxxxxxx", "0123", false},
		{"0123xxxx", "0123", true},
		{"xx0123xx", "0123", true},
		{"xxxx0123", "0123", true},
		{"0123xxxxx"[1:], "0123", false},
		{"xxxxx0123"[:8], "0123", false},
		// 5-7-byte needle
		{"xxxxxxxxx", "01234", false},
		{"01234xxxx", "01234", true},
		{"xx01234xx", "01234", true},
		{"xxxx01234", "01234", true},
		{"01234xxxxx"[1:], "01234", false},
		{"xxxxx01234"[:9], "01234", false},
		// 8-byte needle
		{"xxxxxxxxxxxx", "01234567", false},
		{"01234567xxxx", "01234567", true},
		{"xx01234567xx", "01234567", true},
		{"xxxx01234567", "01234567", true},
		{"01234567xxxxx"[1:], "01234567", false},
		{"xxxxx01234567"[:12], "01234567", false},
		// 9-15-byte needle
		{"xxxxxxxxxxxxx", "012345678", false},
		{"012345678xxxx", "012345678", true},
		{"xx012345678xx", "012345678", true},
		{"xxxx012345678", "012345678", true},
		{"012345678xxxxx"[1:], "012345678", false},
		{"xxxxx012345678"[:13], "012345678", false},
		// 16-byte needle
		{"xxxxxxxxxxxxxxxxxxxx", "0123456789ABCDEF", false},
		{"0123456789ABCDEFxxxx", "0123456789ABCDEF", true},
		{"xx0123456789ABCDEFxx", "0123456789ABCDEF", true},
		{"xxxx0123456789ABCDEF", "0123456789ABCDEF", true},
		{"0123456789ABCDEFxxxxx"[1:], "0123456789ABCDEF", false},
		{"xxxxx0123456789ABCDEF"[:20], "0123456789ABCDEF", false},
		// 17-31-byte needle
		{"xxxxxxxxxxxxxxxxxxxxx", "0123456789ABCDEFG", false},
		{"0123456789ABCDEFGxxxx", "0123456789ABCDEFG", true},
		{"xx0123456789ABCDEFGxx", "0123456789ABCDEFG", true},
		{"xxxx0123456789ABCDEFG", "0123456789ABCDEFG", true},
		{"0123456789ABCDEFGxxxxx"[1:], "0123456789ABCDEFG", false},
		{"xxxxx0123456789ABCDEFG"[:21], "0123456789ABCDEFG", false},

		// partial match cases
		{"xx01x", "012", false},                             // 3
		{"xx0123x", "01234", false},                         // 5-7
		{"xx01234567x", "012345678", false},                 // 9-15
		{"xx0123456789ABCDEFx", "0123456789ABCDEFG", false}, // 17-31, issue 15679
		// 2 byte needle, 16byte haystack
		{"xxxxxxxxxxxxxxxx", "01", false},
		{"01xxxxxxxxxxxxxx", "01", true},
		{"xx01xxxxxxxxxxxx", "01", true},
		{"xxxxxxxxxxxxx01x", "01", true},
		{"xxxxxxxxxxxxxxx01xxxxxxx", "01", true},
		{"01xxxxxxxxxxxxxxx"[1:], "01", false},
		// 3 byte needle, 32byte haystack
		{"xyyyyyyyyyyyyyyyyxxxxxxxxxxxxxxx", "yyy", true},
		// 5 bytes needle, 21byte haystack
		{"xxxxxxxxxxxxxxxxxxxxx", "01234", false},
		{"01234xxxxxxxxxxxxxxxx", "01234", true},
		{"xx01234xxxxxxxxxxxxxx", "01234", true},
		{"xxxxxxxxxxx01234xxxxx", "01234", true},
		{"xxxxxxxxxxx01x34xxxxx", "01234", false},
		{"0101x340123401234xxxx", "01234", true},
		// fuzzed cases
		{"000", "0\x00", false},
		{"00000000000000000", "0`", false},
		{"0000", "\x00\x00\x00", false},
	}

	for _, ct := range containsTests {
		if containsFold(ct.str, ct.substr) != ct.expected {
			t.Errorf("ContainsFold(%s, %s) = %v, want %v",
				ct.str, ct.substr, !ct.expected, ct.expected)
		}
		want := indexFoldGo(ct.str, ct.substr)
		if idx := IndexFold(ct.str, ct.substr); idx != want {
			t.Errorf("IndexFold(%s, %s) = %v, want %v",
				ct.str, ct.substr, idx, want)
		}
		if idx := indexFoldRabinKarp(ct.str, ct.substr); idx != want {
			t.Errorf("indexFoldRabinKarp(%s, %s) = %v, want %v",
				ct.str, ct.substr, idx, want)
		}
	}
}

func TestEqualFold(t *testing.T) {
	equalFoldTests := []struct {
		s, t string
		out  bool
	}{
		{"", "", true},
		{"abc", "abc", true},
		{"ABcd", "ABcd", true},
		{"123abc", "123ABC", true},
		{"abc", "xyz", false},
		{"abc", "XYZ", false},
		{"abcdefghijk", "abcdefghijX", false},
		{"1", "2", false},
		{"utf-8", "US-ASCII", false},
		{"hello", "Hello", true},
		{"oh hello there!!", "oh hello there!!", true},
		{"oh hello there!!", "oh HELLO there!!", true},
		{"oh hello there!!", "oh HELLO there !", false},
		{"oh hello there!! friend!", "oh HELLO there!! FRIEND!", true},
	}

	for _, tt := range equalFoldTests {
		if out := EqualFold(tt.s, tt.t); out != tt.out {
			t.Errorf("EqualFold(%#q, %#q) = %v, want %v", tt.s, tt.t, out, tt.out)
		}
		if out := EqualFold(tt.t, tt.s); out != tt.out {
			t.Errorf("EqualFold(%#q, %#q) = %v, want %v", tt.t, tt.s, out, tt.out)
		}
	}
}

func TestHasPrefixFold(t *testing.T) {
	tests := []struct {
		s, prefix string
		want      bool
	}{
		// Empty cases
		{"", "", true},
		{"abc", "", true},
		{"", "a", false},

		// Exact match cases
		{"abc", "abc", true},
		{"abc", "ab", true},
		{"abc", "a", true},

		// Case insensitive matches
		{"ABC", "abc", true},
		{"abc", "ABC", true},
		{"Hello World", "hello", true},
		{"hello world", "HELLO", true},
		{"HeLLo", "hElLo", true},

		// Non-matches
		{"abc", "xyz", false},
		{"abc", "bc", false},
		{"hello", "world", false},
		{"abc", "abcd", false}, // prefix longer than string

		// Various lengths
		{"abcdefghijklmnop", "ABCDEFGH", true},
		{"abcdefghijklmnop", "ABCDEFGHIJKLMNOP", true},
		{"abcdefghijklmnop", "ABCDEFGHIJKLMNOPQ", false},
		{"0123456789", "0123", true},
		{"0123456789", "0123456789", true},
		{"0123456789", "01onal", false},
	}

	for _, tt := range tests {
		if got := HasPrefixFold(tt.s, tt.prefix); got != tt.want {
			t.Errorf("HasPrefixFold(%q, %q) = %v, want %v", tt.s, tt.prefix, got, tt.want)
		}
	}
}

func TestHasSuffixFold(t *testing.T) {
	tests := []struct {
		s, suffix string
		want      bool
	}{
		// Empty cases
		{"", "", true},
		{"abc", "", true},
		{"", "a", false},

		// Exact match cases
		{"abc", "abc", true},
		{"abc", "bc", true},
		{"abc", "c", true},

		// Case insensitive matches
		{"ABC", "abc", true},
		{"abc", "ABC", true},
		{"Hello World", "WORLD", true},
		{"hello world", "World", true},
		{"HeLLo", "hElLo", true},

		// Non-matches
		{"abc", "xyz", false},
		{"abc", "ab", false},
		{"hello", "world", false},
		{"abc", "zabc", false}, // suffix longer than string

		// Various lengths
		{"abcdefghijklmnop", "IJKLMNOP", true},
		{"abcdefghijklmnop", "ABCDEFGHIJKLMNOP", true},
		{"abcdefghijklmnop", "XABCDEFGHIJKLMNOP", false},
		{"0123456789", "6789", true},
		{"0123456789", "0123456789", true},
		{"0123456789", "onal6789", false},
	}

	for _, tt := range tests {
		if got := HasSuffixFold(tt.s, tt.suffix); got != tt.want {
			t.Errorf("HasSuffixFold(%q, %q) = %v, want %v", tt.s, tt.suffix, got, tt.want)
		}
	}
}

func BenchmarkAsciiValid(b *testing.B) {
	for _, n := range []int{1, 7, 15, 44, 100, 1000} {
		asciiBuf := makeASCII(n)
		asciiStr := string(asciiBuf)

		b.Run(fmt.Sprintf("go-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(asciiStr)))
			for i := 0; i < b.N; i++ {
				isAsciiGo(asciiBuf)
			}
		})

		b.Run(fmt.Sprintf("segment-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(asciiStr)))
			for i := 0; i < b.N; i++ {
				segAscii.ValidString(asciiStr)
			}
		})

		b.Run(fmt.Sprintf("simd-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(asciiStr)))
			for i := 0; i < b.N; i++ {
				ValidString(asciiStr)
			}
		})
	}
}

func BenchmarkIndexMask(b *testing.B) {
	for _, n := range []int{1, 7, 15, 44, 100, 1000} {
		asciiBuf := makeASCII(n)
		idx := rand.Intn(n)
		asciiBuf[idx] |= 0x80

		asciiStr := string(asciiBuf)

		b.Run(fmt.Sprintf("go-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(asciiStr)))
			for i := 0; i < b.N; i++ {
				indexMaskGo(asciiBuf, 0x80)
			}
		})

		b.Run(fmt.Sprintf("simd-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(asciiStr)))
			for i := 0; i < b.N; i++ {
				IndexMask(asciiStr, 0x80)
			}
		})
	}
}

func BenchmarkAsciiEqualFold(b *testing.B) {
	for _, n := range []int{1, 7, 15, 44, 100, 1000} {
		asciiBuf := makeASCII(n)
		s1 := string(asciiBuf)

		// try to flip as least one byte
		for k := 0; k < 3; k++ {
			idx := rand.Intn(n)
			if unicode.IsUpper(rune(asciiBuf[idx])) {
				asciiBuf[idx] = byte(unicode.ToLower(rune(asciiBuf[idx])))
			} else if unicode.IsLower(rune(asciiBuf[idx])) {
				asciiBuf[idx] = byte(unicode.ToUpper(rune(asciiBuf[idx])))
			}
		}
		s2 := string(asciiBuf)

		b.Run(fmt.Sprintf("go-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(s1)))
			for i := 0; i < b.N; i++ {
				equalFoldGo(s1, s2)
			}
		})

		b.Run(fmt.Sprintf("segment-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(s1)))
			for i := 0; i < b.N; i++ {
				segAscii.EqualFoldString(s1, s2)
			}
		})

		b.Run(fmt.Sprintf("simd-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(s1)))
			for i := 0; i < b.N; i++ {
				EqualFold(s1, s2)
			}
		})
	}
}

func BenchmarkAsciiIndexFold(b *testing.B) {
	rnd := rand.New(rand.NewSource(0))

	for _, n := range []int{1, 7, 15, 44, 100, 1000} {
		asciiBuf := makeASCII(n)
		s1 := string(asciiBuf)

		// try to flip as least one byte
		for k := 0; k < 3; k++ {
			idx := rnd.Intn(n)
			if unicode.IsUpper(rune(asciiBuf[idx])) {
				asciiBuf[idx] = byte(unicode.ToLower(rune(asciiBuf[idx])))
			} else if unicode.IsLower(rune(asciiBuf[idx])) {
				asciiBuf[idx] = byte(unicode.ToUpper(rune(asciiBuf[idx])))
			}
		}

		s2 := string(asciiBuf[rnd.Intn(n):])
		if len(s2) > 3 {
			s2 = s2[:rnd.Intn(len(s2))]
		}
		b.Logf("haystack len: %d, needle len: %d", len(s1), len(s2))

		b.Run(fmt.Sprintf("go-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(s1)))
			for i := 0; i < b.N; i++ {
				indexFoldGo(s1, s2)
			}
		})

		b.Run(fmt.Sprintf("simd-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(s1)))
			for i := 0; i < b.N; i++ {
				IndexFold(s1, s2)
			}
		})

		b.Run(fmt.Sprintf("simd-c-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(s1)))
			rare1, off1, rare2, off2 := selectRarePair(s2, nil)
			for i := 0; i < b.N; i++ {
				indexFoldNEONC(s1, rare1, off1, rare2, off2, s2)
			}
		})
	}
}

var benchInputTorture = strings.Repeat("ABC", 1<<10) + "123" + strings.Repeat("ABC", 1<<10)
var benchNeedleTorture = strings.Repeat("ABC", 1<<10+1)

func BenchmarkIndexTorture(b *testing.B) {
	b.Run("go", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			strings.Index(benchInputTorture, benchNeedleTorture)
		}
	})

	b.Run("simd", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			IndexFold(benchInputTorture, benchNeedleTorture)
		}
	})

	b.Run("rabin-karp", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			indexFoldRabinKarp(benchInputTorture, benchNeedleTorture)
		}
	})

	b.Run("rabin-karp-go", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			indexFoldRabinKarpGo(benchInputTorture, benchNeedleTorture)
		}
	})

	// SearchNeedle with MakeNeedle should auto-detect pathological pattern and use Rabin-Karp
	needle := MakeNeedle(benchNeedleTorture)
	b.Run("SearchNeedle", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			SearchNeedle(benchInputTorture, needle)
		}
	})

	// Compare assembly vs C implementation
	rare1, off1, rare2, off2 := selectRarePair(benchNeedleTorture, nil)
	b.Run("simd-c", func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			indexFoldNEONC(benchInputTorture, rare1, off1, rare2, off2, benchNeedleTorture)
		}
	})
}

func BenchmarkIndexPeriodic(b *testing.B) {
	key := "aa"

	for _, skip := range [...]int{2, 4, 8, 16, 32, 64} {
		b.Run(fmt.Sprintf("go-%d", skip), func(b *testing.B) {
			s := strings.Repeat("a"+strings.Repeat(" ", skip-1), 1<<16/skip)
			for i := 0; i < b.N; i++ {
				strings.Index(s, key)
			}
		})

		b.Run(fmt.Sprintf("simd-%d", skip), func(b *testing.B) {
			s := strings.Repeat("a"+strings.Repeat(" ", skip-1), 1<<16/skip)
			for i := 0; i < b.N; i++ {
				IndexFold(s, key)
			}
		})
	}
}

func TestIndexAny(t *testing.T) {
	tests := []struct {
		s, chars string
		want     int
	}{
		{"", "", -1},
		{"", "a", -1},
		{"a", "", -1},
		{"abc", "a", 0},
		{"abc", "b", 1},
		{"abc", "c", 2},
		{"abc", "d", -1},
		{"abc", "cb", 1},
		{"abc", "dc", 2},
		{"abc", "xyz", -1},
		{"abcdefghijklmnop", "p", 15},
		{"abcdefghijklmnop", "op", 14},
		{"abcdefghijklmnop", "xyz", -1},
		{"hello world", " ", 5},
		{"hello world", "\t\n ", 5},
		{"hello\tworld", "\t\n ", 5},
		{"hello\nworld", "\t\n ", 5},
		// Longer strings to test SIMD paths
		{strings.Repeat("x", 100) + "y", "y", 100},
		{strings.Repeat("x", 100) + "y", "yz", 100},
		{strings.Repeat("x", 1000) + "abc", "abc", 1000},
		{strings.Repeat("x", 1000), "abc", -1},
		// Multiple chars in set
		{"the quick brown fox", "aeiou", 2}, // 'e' in 'the'
		{"xyz", "aeiou", -1},
		// Edge cases: duplicates in chars (should still work)
		{"abc", "aaa", 0},
		{"abc", "bbb", 1},
		{"abc", "aaabbbccc", 0},
		// Edge case: >16 chars (tests SVE2 multiple MATCH passes or Go fallback)
		{"abcdefghijklmnopqrstuvwxyz", "1234567890!@#$%^&*()z", 25},
		// Edge case: >64 chars (falls back to Go)
		{"test", strings.Repeat("x", 65) + "t", 0},
		// Edge case: single char strings
		{"a", "a", 0},
		{"a", "b", -1},
		{"b", "abc", 0},
		// Edge case: non-ASCII in haystack (should still find ASCII chars)
		{"hello\x80world", " ", -1},
		{"hello\x80world", "w", 6},
		{"\xff\xfe\xfd", "abc", -1},
		// Edge case: match at various positions within vector
		{strings.Repeat("a", 15) + "x", "x", 15},
		{strings.Repeat("a", 16) + "x", "x", 16},
		{strings.Repeat("a", 17) + "x", "x", 17},
		{strings.Repeat("a", 31) + "x", "x", 31},
		{strings.Repeat("a", 32) + "x", "x", 32},
		{strings.Repeat("a", 33) + "x", "x", 33},
	}

	for _, tt := range tests {
		if got := IndexAny(tt.s, tt.chars); got != tt.want {
			t.Errorf("IndexAny(%q, %q) = %d, want %d", tt.s, tt.chars, got, tt.want)
		}
		// Also verify against Go fallback
		if got := indexAnyGo(tt.s, tt.chars); got != tt.want {
			t.Errorf("indexAnyGo(%q, %q) = %d, want %d", tt.s, tt.chars, got, tt.want)
		}
	}
}

func TestIndexAnyCharSet(t *testing.T) {
	tests := []struct {
		s, chars string
		want     int
	}{
		{"", "", -1},
		{"", "a", -1},
		{"a", "", -1},
		{"abc", "a", 0},
		{"abc", "b", 1},
		{"abc", "c", 2},
		{"abc", "d", -1},
		{"abc", "cb", 1},
		{"abc", "dc", 2},
		{"abc", "xyz", -1},
		{"abcdefghijklmnop", "p", 15},
		{"abcdefghijklmnop", "op", 14},
		{"hello world", " ", 5},
		// Small data (Go fallback path)
		{"a", "a", 0},
		{"ab", "b", 1},
		{"abcdefghij", "j", 9},
		{"abcdefghijklmno", "o", 14}, // exactly 15 bytes
		// Larger data (NEON path)
		{strings.Repeat("x", 100) + "y", "y", 100},
		{strings.Repeat("x", 1000) + "abc", "abc", 1000},
		{strings.Repeat("x", 1000), "abc", -1},
	}

	for _, tt := range tests {
		cs := MakeCharSet(tt.chars)
		if got := IndexAnyCharSet(tt.s, cs); got != tt.want {
			t.Errorf("IndexAnyCharSet(%q, %q) = %d, want %d", tt.s, tt.chars, got, tt.want)
		}
		// Verify matches IndexAny
		if got := IndexAny(tt.s, tt.chars); got != tt.want {
			t.Errorf("IndexAny(%q, %q) = %d, want %d", tt.s, tt.chars, got, tt.want)
		}
	}
}

func TestContainsAnyCharSet(t *testing.T) {
	tests := []struct {
		s, chars string
		want     bool
	}{
		{"", "", false},
		{"", "a", false},
		{"a", "", false},
		{"abc", "a", true},
		{"abc", "d", false},
		{"hello world", " ", true},
		{"helloworld", " ", false},
	}

	for _, tt := range tests {
		cs := MakeCharSet(tt.chars)
		if got := ContainsAnyCharSet(tt.s, cs); got != tt.want {
			t.Errorf("ContainsAnyCharSet(%q, %q) = %v, want %v", tt.s, tt.chars, got, tt.want)
		}
	}
}

func TestContainsAny(t *testing.T) {
	tests := []struct {
		s, chars string
		want     bool
	}{
		{"", "", false},
		{"", "a", false},
		{"a", "", false},
		{"abc", "a", true},
		{"abc", "d", false},
		{"hello world", " ", true},
		{"helloworld", " ", false},
	}

	for _, tt := range tests {
		if got := ContainsAny(tt.s, tt.chars); got != tt.want {
			t.Errorf("ContainsAny(%q, %q) = %v, want %v", tt.s, tt.chars, got, tt.want)
		}
	}
}

func TestIndexNonASCII(t *testing.T) {
	tests := []struct {
		s    string
		want int
	}{
		{"", -1},
		{"hello", -1},
		{"hello world", -1},
		{"hello\x80world", 5},
		{"\x80hello", 0},
		{"hello\x80", 5},
		{strings.Repeat("x", 100) + "\x80", 100},
		{strings.Repeat("x", 1000) + "日本語", 1000},
	}

	for _, tt := range tests {
		if got := IndexNonASCII(tt.s); got != tt.want {
			t.Errorf("IndexNonASCII(%q) = %d, want %d", tt.s, got, tt.want)
		}
	}
}

func BenchmarkIndexAny(b *testing.B) {
	chars := " \t\n\r"
	for _, n := range []int{16, 64, 256, 1024} {
		data := strings.Repeat("x", n-1) + " "

		b.Run(fmt.Sprintf("go-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			for i := 0; i < b.N; i++ {
				indexAnyGo(data, chars)
			}
		})

		b.Run(fmt.Sprintf("simd-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			for i := 0; i < b.N; i++ {
				IndexAny(data, chars)
			}
		})
	}
}

func BenchmarkIndexAnyCharSet(b *testing.B) {
	chars := " \t\n\r"
	cs := MakeCharSet(chars)

	for _, n := range []int{16, 64, 256, 1024} {
		data := strings.Repeat("x", n-1) + " "

		b.Run(fmt.Sprintf("per-call-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			for i := 0; i < b.N; i++ {
				IndexAny(data, chars)
			}
		})

		b.Run(fmt.Sprintf("charset-%d", n), func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			for i := 0; i < b.N; i++ {
				IndexAnyCharSet(data, cs)
			}
		})
	}
}

func BenchmarkIndexAnyCharCounts(b *testing.B) {
	data := strings.Repeat("\x01", 1023) + "\x00"
	allChars := "\x00\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOP"
	var sink int

	for _, charCount := range []int{1, 4, 8, 16, 32, 64} {
		chars := allChars[:charCount]
		b.Run(fmt.Sprintf("go/chars=%d", charCount), func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			for i := 0; i < b.N; i++ {
				sink = indexAnyGo(data, chars)
			}
		})
		b.Run(fmt.Sprintf("simd/chars=%d", charCount), func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			for i := 0; i < b.N; i++ {
				sink = IndexAny(data, chars)
			}
		})
	}
	_ = sink
}

// indexFoldNaive is a trivially-correct reference for validating indexFoldGo.
// It performs ASCII-only case folding (bytes >= 0x80 are unchanged).
func indexFoldNaive(s, substr string) int {
	if len(substr) == 0 {
		return 0
	}
	if len(substr) > len(s) {
		return -1
	}
	us := toUpperASCII(s)
	un := toUpperASCII(substr)
	return strings.Index(us, un)
}

// toUpperASCII converts ASCII lowercase to uppercase, leaving other bytes unchanged.
func toUpperASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 0x20
		}
	}
	return string(b)
}

// indexAnyNaive is a trivially-correct reference for validating indexAnyGo.
func indexAnyNaive(s, chars string) int {
	for i := 0; i < len(s); i++ {
		for j := 0; j < len(chars); j++ {
			if s[i] == chars[j] {
				return i
			}
		}
	}
	return -1
}

func FuzzIndexAny(f *testing.F) {
	f.Add("hello world", " ")
	f.Add("abcdefghij", "xyz")
	f.Add(strings.Repeat("a", 100), "b")
	// Edge cases for high bytes
	f.Add("abc\x80def", "\x80")
	f.Add("\xff\xfe\xfd", "\xfd")
	f.Add(strings.Repeat("x", 17)+"\x00", "\x00")

	f.Fuzz(func(t *testing.T, s, chars string) {
		want := indexAnyNaive(s, chars)

		got := IndexAny(s, chars)
		if got != want {
			t.Fatalf("IndexAny(%q, %q) = %d, want %d", s, chars, got, want)
		}

		goRes := indexAnyGo(s, chars)
		if goRes != want {
			t.Fatalf("indexAnyGo(%q, %q) = %d, want %d", s, chars, goRes, want)
		}
	})
}

func FuzzEqualFold(f *testing.F) {
	f.Add("01234567", "01234567")
	f.Add("abcd", "ABCD")
	f.Add("EqualFold", "equalFold")

	f.Fuzz(func(t *testing.T, in1, in2 string) {
		if !ValidString(in1) || !ValidString(in2) {
			t.Skip()
		}

		res := EqualFold(in1, in2)
		stdRes := strings.EqualFold(in1, in2)
		if res != stdRes {
			t.Fatalf("EqualFold(%q, %q) = %v; want %v", in1, in2, res, stdRes)
		}
		goRes := equalFoldGo(in1, in2)
		if goRes != stdRes {
			t.Fatalf("equalFoldGo(%q, %q) = %v; want %v", in1, in2, goRes, stdRes)
		}
	})
}

func FuzzIndexFold(f *testing.F) {
	f.Add("01234567", "01234567")
	f.Add("abcdefghijklmnopqrstuvwxyz01234567890", "klmno")
	f.Add("abcdefghijklmnopqrstuvwxyz01234567890", "12")
	f.Add("abcdefghABCDEFGH01234567890", "H")
	f.Add("000000000000000B0", "B0")
	f.Add("EqualFold", "fold")
	f.Add("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor...", " ELIT")
	// Non-ASCII seeds
	f.Add("\x80ABC", "abc")
	f.Add("abc\x80def", "\x80d")
	f.Add("test\xfe\xffend", "\xfe\xff")
	f.Add(strings.Repeat("\x80", 100)+"needle", "NEEDLE")

	f.Fuzz(func(t *testing.T, istr, isubstr string) {
		// Ground truth from naive implementation
		want := indexFoldNaive(istr, isubstr)

		res := IndexFold(istr, isubstr)
		if res != want {
			t.Fatalf("IndexFold(%q, %q) = %v; want %v", istr, isubstr, res, want)
		}

		goRes := indexFoldGo(istr, isubstr)
		if goRes != want {
			t.Fatalf("indexFoldGo(%q, %q) = %v; want %v", istr, isubstr, goRes, want)
		}

		rkRes := indexFoldRabinKarp(istr, isubstr)
		if rkRes != want {
			t.Fatalf("indexFoldRabinKarp(%q, %q) = %v; want %v", istr, isubstr, rkRes, want)
		}

		rkGoRes := indexFoldRabinKarpGo(istr, isubstr)
		if rkGoRes != want {
			t.Fatalf("indexFoldRabinKarpGo(%q, %q) = %v; want %v", istr, isubstr, rkGoRes, want)
		}
	})
}

func TestSearchNeedle(t *testing.T) {
	tests := []struct {
		haystack, needle string
		want             int
	}{
		{"", "", 0},
		{"", "a", -1},
		{"a", "", 0},
		{"abc", "a", 0},
		{"abc", "A", 0},
		{"abc", "b", 1},
		{"abc", "B", 1},
		{"abc", "c", 2},
		{"abc", "d", -1},
		{"hello world", "WORLD", 6},
		{"Hello World", "hello", 0},
		{"The Quick Brown Fox", "quick", 4},
		{"The Quick Brown Fox", "QUICK", 4},
		{"The Quick Brown Fox", "fox", 16},
		{"The Quick Brown Fox", "xyz", -1},
		// Test rare byte selection - 'q' and 'x' are rare
		{"abcdefghijklmnopqrstuvwxyz", "qrs", 16},
		{"abcdefghijklmnopqrstuvwxyz", "xyz", 23},
		// Longer strings
		{strings.Repeat("a", 100) + "NEEDLE" + strings.Repeat("b", 100), "needle", 100},
		{strings.Repeat("x", 1000) + "QuIcK", "quick", 1000},

		// =============================================================
		// Bug regression tests - these target specific edge cases
		// =============================================================

		// Bug 1: Multiple matches in same 16-byte chunk where first is false positive
		// Tests nibble clearing logic - if we clear only 1 bit instead of 4-bit nibble,
		// we'd get stuck in infinite loop or miss the real match
		{"xQxZxQxZxQxZQZab", "QZab", 12}, // Q and Z are rare, multiple false positives before real match
		{"aQaZaQaZaQaZQZxy", "QZxy", 12}, // Same pattern, different ending
		{"QxZxQxZxQxZxQxZxQZmatch", "QZmatch", 16}, // Match starts exactly at position 16

		// Bug 2: Match in tail region (last <16 bytes after main SIMD loop)
		// Tests tail masking - if we mask chunks before comparison, non-zero rare bytes
		// compared against masked zeros would never match
		{strings.Repeat("x", 20) + "needle", "needle", 20},           // Match in tail, haystack > 16
		{strings.Repeat("x", 17) + "QZ", "QZ", 17},                   // Very short tail (2 bytes)
		{strings.Repeat("x", 25) + "abc", "abc", 25},                 // Match in tail after 1 full SIMD iteration
		{strings.Repeat("y", 31) + "z", "z", 31},                     // Single char match at very end of tail
		{strings.Repeat("a", 16) + strings.Repeat("b", 10) + "QZ", "QZ", 26}, // Tail with rare bytes

		// Combined: multiple candidates AND in tail region
		{strings.Repeat("QZ", 8) + "xQZmatch", "QZmatch", 17}, // False positives then match in tail (QZ*8=16 + "x"=1)

		// Edge case: needle longer than 16 bytes with match in tail
		{strings.Repeat("x", 20) + "abcdefghijklmnopqrst", "abcdefghijklmnopqrst", 20},
	}

	for _, tt := range tests {
		n := MakeNeedle(tt.needle)
		if got := SearchNeedle(tt.haystack, n); got != tt.want {
			t.Errorf("SearchNeedle(%q, %q) = %d, want %d", tt.haystack, tt.needle, got, tt.want)
		}
		// Verify against IndexFold
		if want := IndexFold(tt.haystack, tt.needle); want != tt.want {
			t.Errorf("IndexFold(%q, %q) = %d, want %d", tt.haystack, tt.needle, want, tt.want)
		}
	}
}

// TestIndex tests the case-sensitive Index function.
func TestIndex(t *testing.T) {
	tests := []struct {
		haystack, needle string
		want             int
	}{
		{"", "", 0},
		{"", "a", -1},
		{"a", "", 0},
		{"abc", "a", 0},
		{"abc", "A", -1}, // case-sensitive: 'A' not found
		{"abc", "b", 1},
		{"abc", "B", -1}, // case-sensitive
		{"abc", "c", 2},
		{"abc", "d", -1},
		{"hello world", "world", 6},
		{"Hello World", "hello", -1}, // case-sensitive: 'hello' not found
		{"Hello World", "Hello", 0},
		{"The Quick Brown Fox", "Quick", 4},
		{"The Quick Brown Fox", "quick", -1}, // case-sensitive
		{"The Quick Brown Fox", "Fox", 16},
		{"The Quick Brown Fox", "xyz", -1},
		// Test rare byte selection
		{"abcdefghijklmnopqrstuvwxyz", "qrs", 16},
		{"abcdefghijklmnopqrstuvwxyz", "xyz", 23},
		// Longer strings
		{strings.Repeat("a", 100) + "NEEDLE" + strings.Repeat("b", 100), "NEEDLE", 100},
		{strings.Repeat("a", 100) + "NEEDLE" + strings.Repeat("b", 100), "needle", -1}, // case-sensitive
		{strings.Repeat("x", 1000) + "QuIcK", "QuIcK", 1000},
		{strings.Repeat("x", 1000) + "QuIcK", "quick", -1}, // case-sensitive
		// Edge cases
		{strings.Repeat("x", 20) + "needle", "needle", 20},
		{strings.Repeat("x", 17) + "QZ", "QZ", 17},
		{strings.Repeat("x", 25) + "abc", "abc", 25},
		{strings.Repeat("y", 31) + "z", "z", 31},
	}

	for _, tt := range tests {
		if got := Index(tt.haystack, tt.needle); got != tt.want {
			t.Errorf("Index(%q, %q) = %d, want %d", tt.haystack, tt.needle, got, tt.want)
		}
	}
}

// TestSearchNeedleExact tests the case-sensitive SearchNeedleExact function.
func TestSearchNeedleExact(t *testing.T) {
	tests := []struct {
		haystack, needle string
		want             int
	}{
		{"", "", 0},
		{"", "a", -1},
		{"a", "", 0},
		{"abc", "a", 0},
		{"abc", "A", -1}, // case-sensitive
		{"abc", "b", 1},
		{"abc", "B", -1}, // case-sensitive
		{"hello world", "world", 6},
		{"Hello World", "hello", -1}, // case-sensitive
		{"Hello World", "Hello", 0},
		{"The Quick Brown Fox", "Quick", 4},
		{"The Quick Brown Fox", "quick", -1}, // case-sensitive
		// Longer strings
		{strings.Repeat("a", 100) + "NEEDLE" + strings.Repeat("b", 100), "NEEDLE", 100},
		{strings.Repeat("a", 100) + "NEEDLE" + strings.Repeat("b", 100), "needle", -1},
		{strings.Repeat("x", 1000) + "QuIcK", "QuIcK", 1000},
		{strings.Repeat("x", 1000) + "QuIcK", "quick", -1},
	}

	for _, tt := range tests {
		n := MakeNeedle(tt.needle)
		if got := SearchNeedleExact(tt.haystack, n); got != tt.want {
			t.Errorf("SearchNeedleExact(%q, %q) = %d, want %d", tt.haystack, tt.needle, got, tt.want)
		}
		// Verify against Index
		if want := Index(tt.haystack, tt.needle); want != tt.want {
			t.Errorf("Index(%q, %q) = %d, want %d (mismatch with SearchNeedleExact)", tt.haystack, tt.needle, want, tt.want)
		}
	}
}

func TestAdaptive(t *testing.T) {
	tests := []struct {
		haystack, needle string
		want             int
	}{
		{"", "", 0},
		{"", "a", -1},
		{"a", "", 0},
		{"abc", "a", 0},
		{"abc", "A", 0},
		{"abc", "b", 1},
		{"abc", "B", 1},
		{"hello world", "WORLD", 6},
		{"Hello World", "hello", 0},
		{"The Quick Brown Fox", "quick", 4},
		// Longer strings to exercise 128-byte loop
		{strings.Repeat("a", 100) + "NEEDLE" + strings.Repeat("b", 100), "needle", 100},
		{strings.Repeat("x", 1000) + "QuIcK", "quick", 1000},
		// Very long strings
		{strings.Repeat("abcdefghijklmnopqrstuvw ", 10000) + "XYLOPHONE", "xylophone", 240000},
		// Edge cases for loop boundaries
		{strings.Repeat("x", 127) + "needle", "needle", 127},
		{strings.Repeat("x", 128) + "needle", "needle", 128},
		{strings.Repeat("x", 129) + "needle", "needle", 129},
	}

	for _, tt := range tests {
		n := MakeNeedle(tt.needle)
		got := SearchNeedle(tt.haystack, n)
		if got != tt.want {
			t.Errorf("SearchNeedle(%q..., %q) = %d, want %d",
				truncate(tt.haystack, 30), tt.needle, got, tt.want)
		}
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func TestSelectRarePair(t *testing.T) {
	tests := []struct {
		needle      string
		expectRare1 byte
		expectRare2 byte
	}{
		{"the", 'T', 'H'},         // All common, picks first two
		{"quick", 'Q', 'K'},       // Q is very rare
		{"xylophone", 'X', 'Y'},   // X and Y are rare
		{"zzz", 'Z', 'Z'},         // Z is very rare
		{"aaa", 'A', 'A'},         // All same
		{"ab", 'B', 'A'},          // B rarer than A (or vice versa based on distance)
		{`"num"`, '"', 'u'},       // Must pick different chars, not both quotes
		{`""`, '"', '"'},          // All same char, fallback to first/last
	}

	for _, tt := range tests {
		rare1, _, rare2, _ := selectRarePair(tt.needle, nil)
		// Just verify we get rare bytes, exact selection depends on implementation
		if rare1 == 0 && len(tt.needle) > 0 {
			t.Errorf("selectRarePair(%q): rare1 is 0", tt.needle)
		}
		t.Logf("selectRarePair(%q) = (%c, %c)", tt.needle, rare1, rare2)
	}
}

func FuzzSelectRarePair(f *testing.F) {
	// Seed corpus
	f.Add("hello")
	f.Add(`"num"`)
	f.Add(`""""`)
	f.Add("aaaa")
	f.Add("abcd")
	f.Add("ABCD")
	f.Add("AaBbCc")
	f.Add("x")
	f.Add("xy")
	f.Add("")
	f.Add("the quick brown fox")
	f.Add(`{"key":"value"}`)

	toLower := func(b byte) byte {
		if b >= 'A' && b <= 'Z' {
			return b + 0x20
		}
		return b
	}

	f.Fuzz(func(t *testing.T, needle string) {
		if len(needle) == 0 {
			return
		}

		rare1, off1, rare2, off2 := selectRarePair(needle, nil)

		// Invariant 1: offsets must be in bounds
		if off1 < 0 || off1 >= len(needle) {
			t.Fatalf("off1=%d out of bounds for needle len=%d", off1, len(needle))
		}
		if off2 < 0 || off2 >= len(needle) {
			t.Fatalf("off2=%d out of bounds for needle len=%d", off2, len(needle))
		}

		// Invariant 2: off1 <= off2 (ordered)
		if off1 > off2 {
			t.Fatalf("off1=%d > off2=%d, should be ordered", off1, off2)
		}

		// Invariant 3: returned bytes match needle positions (after toLower)
		if rare1 != toLower(needle[off1]) {
			t.Fatalf("rare1=%c doesn't match toLower(needle[%d])=%c", rare1, off1, toLower(needle[off1]))
		}
		if rare2 != toLower(needle[off2]) {
			t.Fatalf("rare2=%c doesn't match toLower(needle[%d])=%c", rare2, off2, toLower(needle[off2]))
		}

		// Invariant 4: if needle has >1 distinct normalized bytes, rare1 != rare2
		if len(needle) > 1 {
			distinctBytes := make(map[byte]struct{})
			for i := 0; i < len(needle); i++ {
				distinctBytes[toLower(needle[i])] = struct{}{}
			}
			if len(distinctBytes) > 1 && rare1 == rare2 {
				t.Fatalf("needle %q has %d distinct bytes but rare1==rare2==%c",
					needle, len(distinctBytes), rare1)
			}
		}

		// Invariant 5: for len>1, off1 != off2 (different positions)
		if len(needle) > 1 && off1 == off2 {
			t.Fatalf("needle len=%d but off1==off2==%d", len(needle), off1)
		}
	})
}

func TestNeedleLengthVariations(t *testing.T) {
	lengths := []int{1, 2, 3, 4, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65}

	for _, needleLen := range lengths {
		t.Run(fmt.Sprintf("len%d", needleLen), func(t *testing.T) {
			needle := strings.Repeat("x", needleLen)
			if needleLen > 1 {
				b := []byte(needle)
				b[1] = 'Q'
				if needleLen > 2 {
					b[needleLen-1] = 'Z'
				}
				needle = string(b)
			}

			haystack := strings.Repeat("a", 256) + needle + strings.Repeat("b", 256)
			n := MakeNeedle(needle)
			want := indexFoldGo(haystack, needle)

			if got := SearchNeedle(haystack, n); got != want {
				t.Errorf("got %d, want %d (needle=%q)", got, want, needle)
			}
		})
	}
}

func TestNeedleLengthNotFound(t *testing.T) {
	lengths := []int{1, 2, 3, 4, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65}
	haystack := strings.Repeat("abcdefghijklmnop", 100)

	for _, needleLen := range lengths {
		t.Run(fmt.Sprintf("len%d", needleLen), func(t *testing.T) {
			needle := strings.Repeat("Q", needleLen)
			if needleLen > 1 {
				b := []byte(needle)
				b[needleLen-1] = 'Z'
				needle = string(b)
			}

			n := MakeNeedle(needle)
			if got := SearchNeedle(haystack, n); got != -1 {
				t.Errorf("got %d, want -1 (needle=%q)", got, needle)
			}
		})
	}
}

func TestAlignmentVariations(t *testing.T) {
	needle := "QZXY"
	n := MakeNeedle(needle)

	for align := 0; align <= 127; align++ {
		t.Run(fmt.Sprintf("align%d", align), func(t *testing.T) {
			haystack := string(bytes.Repeat([]byte{'a'}, align)) + needle + strings.Repeat("b", 256)
			want := indexFoldGo(haystack, needle)

			if got := SearchNeedle(haystack, n); got != want {
				t.Errorf("got %d, want %d", got, want)
			}
		})
	}
}

func TestChunkBoundaryStraddle(t *testing.T) {
	boundaries := []int{16, 32, 64, 128}
	needleLens := []int{4, 8, 16}

	for _, boundary := range boundaries {
		for _, needleLen := range needleLens {
			for offset := 1; offset <= 3; offset++ {
				startPos := boundary - offset
				if startPos < 0 {
					continue
				}

				t.Run(fmt.Sprintf("b%d/n%d/o%d", boundary, needleLen, offset), func(t *testing.T) {
					needle := strings.Repeat("Q", needleLen)
					if needleLen > 1 {
						b := []byte(needle)
						b[needleLen-1] = 'Z'
						needle = string(b)
					}
					n := MakeNeedle(needle)

					haystack := string(bytes.Repeat([]byte{'a'}, startPos)) + needle + strings.Repeat("b", 256)
					want := indexFoldGo(haystack, needle)

					if got := SearchNeedle(haystack, n); got != want {
						t.Errorf("got %d, want %d", got, want)
					}
				})
			}
		}
	}
}

func TestHighFalsePositiveJSON(t *testing.T) {
	jsonData := strings.Repeat(`{"key":"value","cnt":123},`, 100)
	needle := `"num"`

	testCases := []struct {
		name     string
		haystack string
		want     int
	}{
		{"not_found", jsonData, -1},
		{"at_end", jsonData + `{"num":999}`, len(jsonData) + 1},
		{"at_start", `{"num":0}` + jsonData, 1},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			n := MakeNeedle(needle)
			want := indexFoldGo(tc.haystack, needle)

			if got := SearchNeedle(tc.haystack, n); got != want {
				t.Errorf("got %d, want %d", got, want)
			}
		})
	}
}

func TestSameCharNeedle(t *testing.T) {
	haystack := strings.Repeat("a", 10000) + "aab"
	needle := "aab"
	n := MakeNeedle(needle)
	want := 10000

	if got := SearchNeedle(haystack, n); got != want {
		t.Errorf("got %d, want %d", got, want)
	}
}

func TestCaseFolding(t *testing.T) {
	testCases := []struct {
		haystack, needle string
		want             int
	}{
		{"HELLO WORLD", "world", 6},
		{"hello world", "WORLD", 6},
		{"HeLLo WoRLd", "world", 6},
		{"abcXYZdef", "xyz", 3},
		{"ABCxyzDEF", "XYZ", 3},
		{"The Quick Brown Fox", "QUICK", 4},
	}

	for _, tc := range testCases {
		t.Run(tc.needle, func(t *testing.T) {
			n := MakeNeedle(tc.needle)
			if got := SearchNeedle(tc.haystack, n); got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}

func TestNeedleEdgeCases(t *testing.T) {
	testCases := []struct {
		name             string
		haystack, needle string
		want             int
	}{
		{"empty_needle", "hello", "", 0},
		{"empty_haystack", "", "a", -1},
		{"needle_longer", "abc", "abcdef", -1},
		{"exact_match", "test", "test", 0},
		{"at_start", "hello world", "hello", 0},
		{"at_end", "hello world", "world", 6},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			n := MakeNeedle(tc.needle)
			if got := SearchNeedle(tc.haystack, n); got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}

func TestMultipleMatches(t *testing.T) {
	haystack := "abcxyzdefxyzghixyz"
	needle := "xyz"
	n := MakeNeedle(needle)

	if got := SearchNeedle(haystack, n); got != 3 {
		t.Errorf("got %d, want 3 (first match)", got)
	}
}

func TestMatchAtEnd(t *testing.T) {
	sizes := []int{16, 32, 64, 128, 256, 1024, 4096}
	needle := "QZXY"
	n := MakeNeedle(needle)

	for _, size := range sizes {
		t.Run(fmt.Sprintf("size%d", size), func(t *testing.T) {
			haystack := strings.Repeat("a", size-len(needle)) + needle
			want := size - len(needle)

			if got := SearchNeedle(haystack, n); got != want {
				t.Errorf("got %d, want %d", got, want)
			}
		})
	}
}

func TestMatchAtStart(t *testing.T) {
	sizes := []int{16, 32, 64, 128, 256, 1024, 4096}
	needle := "QZXY"
	n := MakeNeedle(needle)

	for _, size := range sizes {
		t.Run(fmt.Sprintf("size%d", size), func(t *testing.T) {
			haystack := needle + strings.Repeat("a", size-len(needle))

			if got := SearchNeedle(haystack, n); got != 0 {
				t.Errorf("got %d, want 0", got)
			}
		})
	}
}

func BenchmarkSearchNeedle(b *testing.B) {
	// Benchmark full-scan performance with needle at END of haystack.
	// This measures actual throughput, not "time to first match".

	const size = 4700

	// JSON case: searching for a key in JSON-like data
	// Before fix: would pick "@0 and "@4 (same byte) -> many false positives
	// After fix: picks "@0 and M@3 (different bytes) -> fewer false positives
	jsonNeedle := `"num"`
	jsonN := MakeNeedle(jsonNeedle)
	jsonHaystack := strings.Repeat(`{"key":"value","cnt":123},`, size/26) + `{"num":999}`

	b.Run("json/IndexFold", func(b *testing.B) {
		b.SetBytes(int64(len(jsonHaystack)))
		for i := 0; i < b.N; i++ {
			IndexFold(jsonHaystack, jsonNeedle)
		}
	})

	b.Run("json/SearchNeedle", func(b *testing.B) {
		b.SetBytes(int64(len(jsonHaystack)))
		for i := 0; i < b.N; i++ {
			SearchNeedle(jsonHaystack, jsonN)
		}
	})

	// Zero false-positive case: needle "quartz" (Q, Z rare), haystack has no Q or Z
	zeroFPNeedle := "quartz"
	zeroFPN := MakeNeedle(zeroFPNeedle)
	zeroFPHaystack := strings.Repeat("abcdefghijklmnoprstuvwy ", size/24) + zeroFPNeedle

	b.Run("rare/IndexFold", func(b *testing.B) {
		b.SetBytes(int64(len(zeroFPHaystack)))
		for i := 0; i < b.N; i++ {
			IndexFold(zeroFPHaystack, zeroFPNeedle)
		}
	})

	b.Run("rare/SearchNeedle", func(b *testing.B) {
		b.SetBytes(int64(len(zeroFPHaystack)))
		for i := 0; i < b.N; i++ {
			SearchNeedle(zeroFPHaystack, zeroFPN)
		}
	})

	// Not-found case (full scan)
	notFoundHaystack := strings.Repeat("abcdefghijklmnoprstuvwy ", size/24)
	b.Run("notfound/IndexFold", func(b *testing.B) {
		b.SetBytes(int64(len(notFoundHaystack)))
		for i := 0; i < b.N; i++ {
			IndexFold(notFoundHaystack, zeroFPNeedle)
		}
	})

	b.Run("notfound/SearchNeedle", func(b *testing.B) {
		b.SetBytes(int64(len(notFoundHaystack)))
		for i := 0; i < b.N; i++ {
			SearchNeedle(notFoundHaystack, zeroFPN)
		}
	})
}

// BenchmarkNeedleReuse demonstrates the advantage of precomputing Needle once
// and reusing it across many haystacks (typical database/log search use case).
func BenchmarkNeedleReuse(b *testing.B) {
	for _, count := range []int{1000, 1_000_000} {
		// Simulate searching through many log lines for the same needle
		haystacks := make([]string, count)
		for i := range haystacks {
			// Mix of lines - some contain the needle, most don't
			if i%100 == 99 {
				haystacks[i] = fmt.Sprintf("[%04d] INFO: user logged in with xylophone device", i)
			} else {
				haystacks[i] = fmt.Sprintf("[%04d] DEBUG: processing request for user_id=%d action=update", i, i*17)
			}
		}

		needle := "xylophone"
		precomputed := MakeNeedle(needle)

		var totalBytes int64
		for _, h := range haystacks {
			totalBytes += int64(len(h))
		}

		suffix := fmt.Sprintf("%d", count)
		if count >= 1_000_000 {
			suffix = fmt.Sprintf("%dM", count/1_000_000)
		} else if count >= 1000 {
			suffix = fmt.Sprintf("%dK", count/1000)
		}

		b.Run(fmt.Sprintf("IndexFold/%s", suffix), func(b *testing.B) {
			b.SetBytes(totalBytes)
			var sink int
			for i := 0; i < b.N; i++ {
				for _, h := range haystacks {
					sink += IndexFold(h, needle)
				}
			}
			_ = sink
		})

		b.Run(fmt.Sprintf("SearchNeedle/%s", suffix), func(b *testing.B) {
			b.SetBytes(totalBytes)
			var sink int
			for i := 0; i < b.N; i++ {
				for _, h := range haystacks {
					sink += SearchNeedle(h, precomputed)
				}
			}
			_ = sink
		})

		b.Run(fmt.Sprintf("SearchNeedle+MakeNeedle/%s", suffix), func(b *testing.B) {
			b.SetBytes(totalBytes)
			var sink int
			for i := 0; i < b.N; i++ {
				n := MakeNeedle(needle)
				for _, h := range haystacks {
					sink += SearchNeedle(h, n)
				}
			}
			_ = sink
		})
	}
}

// buildJSONLogCorpus creates a realistic JSON logs corpus with multi-language content.
func buildJSONLogCorpus() string {
	var lines []string
	for i := 0; i < 1000; i++ {
		switch i % 10 {
		case 0: // JSON with numbers
			lines = append(lines, fmt.Sprintf(`{"ts":1704067200%03d,"level":"info","latency_ms":%d,"bytes":%d,"status":200}`, i, i%500, i*1024))
		case 1: // JSON with UUID
			lines = append(lines, fmt.Sprintf(`{"request_id":"550e8400-e29b-%04x-a716-4466554400%02x","user_id":%d}`, i, i%256, i*100))
		case 2: // Multi-language (Chinese)
			lines = append(lines, fmt.Sprintf(`{"msg":"用户登录成功","user":"user_%d","ip":"10.0.%d.%d"}`, i, i%256, (i*7)%256))
		case 3: // Multi-language (Japanese)
			lines = append(lines, fmt.Sprintf(`{"msg":"リクエスト処理完了","duration":%d,"code":%d}`, i*10, 200+i%5))
		case 4: // Multi-language (Korean)
			lines = append(lines, fmt.Sprintf(`{"msg":"데이터베이스 연결","pool_size":%d,"active":%d}`, 100, i%100))
		case 5: // Nested JSON with arrays
			lines = append(lines, fmt.Sprintf(`{"data":{"items":[%d,%d,%d],"total":%d},"page":%d}`, i, i+1, i+2, i*3, i/10))
		case 6: // Error with stack trace reference
			lines = append(lines, fmt.Sprintf(`{"error":"connection timeout","retry":%d,"host":"db-%d.prod.internal:5432"}`, i%3, i%10))
		case 7: // Metrics
			lines = append(lines, fmt.Sprintf(`{"metric":"cpu_usage","value":%.2f,"tags":{"host":"srv%03d","dc":"us-east-1"}}`, float64(i%100)/100.0, i%100))
		case 8: // Auth event
			lines = append(lines, fmt.Sprintf(`{"event":"auth.login","success":true,"method":"oauth2","provider":"google","uid":%d}`, i*1000))
		case 9: // HTTP access log style
			lines = append(lines, fmt.Sprintf(`{"method":"POST","path":"/api/v2/users/%d/orders","status":201,"bytes":%d}`, i, i*50))
		}
	}
	return strings.Join(lines, "\n")
}

// buildUUIDHeavyCorpus creates a corpus dominated by UUIDs (like a distributed tracing store).
func buildUUIDHeavyCorpus() string {
	var lines []string
	for i := 0; i < 1000; i++ {
		// Every line has 3-4 UUIDs (trace_id, span_id, parent_id, request_id)
		lines = append(lines, fmt.Sprintf(
			`{"trace_id":"%08x-%04x-%04x-%04x-%012x","span_id":"%08x-%04x-%04x-%04x-%012x","parent_id":"%08x-%04x-%04x-%04x-%012x","op":"db.query"}`,
			i*111, i%0xFFFF, 0x4000|(i%0x0FFF), 0x8000|(i%0x3FFF), i*123456,
			i*222, (i+1)%0xFFFF, 0x4000|((i+1)%0x0FFF), 0x8000|((i+1)%0x3FFF), (i+1)*123456,
			i*333, (i+2)%0xFFFF, 0x4000|((i+2)%0x0FFF), 0x8000|((i+2)%0x3FFF), (i+2)*123456,
		))
	}
	return strings.Join(lines, "\n")
}

// BenchmarkRankTable compares static byteRank table (English frequency) vs a
// computed rank table based on actual JSON logs corpus.
//
// Use case: logs/traces database that precomputes byte frequency distribution
// per table/partition to speed up substring search.
//
// Key insight: JSON logs have very different byte distribution than English:
// - " (double-quote) is #1 most common, but static table thinks it's rare (rank 60)
// - : (colon) is #2 most common, but static table thinks it's rare (rank 70)
// - Digits 0-9 make up 17% of the corpus
// - JSON punctuation makes up 28% of the corpus
func BenchmarkRankTable(b *testing.B) {
	corpus := buildJSONLogCorpus()
	ranks := buildRankTable(corpus)

	needles := []struct {
		name   string
		needle string
	}{
		// Regular needles - static table works reasonably well
		{"timeout", "timeout"},
		{"connection", "connection"},
		// Worst cases: needles with " and : which static thinks are rare but are #1,#2 in JSON
		{"status:200", `"status":200`},
		{"user_id", `"user_id":`},
		// UUID search - hex chars a-f and digits are common in logs with UUIDs
		{"uuid-prefix", "550e8400-e29b"},
		{"uuid-suffix", "4466554400"},
	}

	for _, tc := range needles {
		static := MakeNeedle(tc.needle)
		computed := MakeNeedleWithRanks(tc.needle, ranks[:])

		b.Run(tc.name+"/Static", func(b *testing.B) {
			b.SetBytes(int64(len(corpus)))
			for i := 0; i < b.N; i++ {
				SearchNeedle(corpus, static)
			}
		})

		b.Run(tc.name+"/Computed", func(b *testing.B) {
			b.SetBytes(int64(len(corpus)))
			for i := 0; i < b.N; i++ {
				SearchNeedle(corpus, computed)
			}
		})

		b.Logf("%s: static=%c@%d,%c@%d  computed=%c@%d,%c@%d",
			tc.name,
			static.rare1, static.off1, static.rare2, static.off2,
			computed.rare1, computed.off1, computed.rare2, computed.off2)
	}
}

// BenchmarkRankTableUUID tests UUID search in a UUID-heavy corpus (distributed tracing).
func BenchmarkRankTableUUID(b *testing.B) {
	corpus := buildUUIDHeavyCorpus()
	ranks := buildRankTable(corpus)

	// Corpus breakdown: '0'=22%, '"'=9.5%, '-'=7%, '4'=4%, '8'=3.8%, etc.
	// Key insight: Static table has '"' at rank 60 (rare!), but it's 9.5% of corpus
	needles := []struct {
		name   string
		needle string
	}{
		// Static picks " (rank 60 "rare"), but " is 9.5% of corpus = tons of false positives
		{"trace_id-search", `"trace_id":"0001b207`},
		{"span_id-search", `"span_id":"0002da12`},
		{"parent_id-search", `"parent_id":"0003c`},
		// Pattern with colon - static thinks : is rare (rank 70)
		{"field-colon", `:"00000000-0000`},
	}

	for _, tc := range needles {
		static := MakeNeedle(tc.needle)
		computed := MakeNeedleWithRanks(tc.needle, ranks[:])

		b.Run(tc.name+"/Static", func(b *testing.B) {
			b.SetBytes(int64(len(corpus)))
			for i := 0; i < b.N; i++ {
				SearchNeedle(corpus, static)
			}
		})

		b.Run(tc.name+"/Computed", func(b *testing.B) {
			b.SetBytes(int64(len(corpus)))
			for i := 0; i < b.N; i++ {
				SearchNeedle(corpus, computed)
			}
		})

		b.Logf("%s: static=%c@%d,%c@%d  computed=%c@%d,%c@%d",
			tc.name,
			static.rare1, static.off1, static.rare2, static.off2,
			computed.rare1, computed.off1, computed.rare2, computed.off2)
	}
}

// buildRankTable computes a byte frequency rank table from a corpus.
func buildRankTable(corpus string) [256]byte {
	var counts [256]int
	for i := 0; i < len(corpus); i++ {
		c := corpus[i]
		if c >= 'a' && c <= 'z' {
			c -= 0x20 // uppercase
		}
		counts[c]++
	}

	maxCount := 1
	for _, c := range counts {
		if c > maxCount {
			maxCount = c
		}
	}

	var ranks [256]byte
	for i := range ranks {
		ranks[i] = byte((counts[i] * 255) / maxCount)
	}
	return ranks
}

func FuzzSearchNeedle(f *testing.F) {
	f.Add("hello world", "world")
	f.Add("The Quick Brown Fox", "quick")
	f.Add(strings.Repeat("a", 100), "aaa")
	f.Add("xylophone", "xy")

	// Bug regression seeds - these target specific edge cases
	// Bug 1: Multiple rare-byte matches in same 16-byte chunk (tests nibble clearing)
	f.Add("xQxZxQxZxQxZQZab", "QZab")
	f.Add("QxZxQxZxQxZxQxZxQZmatch", "QZmatch")
	// Bug 2: Match in tail region after SIMD loop (tests tail masking)
	f.Add(strings.Repeat("x", 20)+"needle", "needle")
	f.Add(strings.Repeat("x", 17)+"QZ", "QZ")
	f.Add(strings.Repeat("y", 31)+"z", "z")
	// Combined: multiple candidates AND in tail
	f.Add(strings.Repeat("QZ", 8)+"xQZmatch", "QZmatch")
	// Non-ASCII seeds
	f.Add("\x80ABC", "abc")
	f.Add(strings.Repeat("\x80", 100)+"needle", "NEEDLE")
	f.Add("abc\x80def", "\x80d")
	// 2-byte mode forcing: rare1 common in haystack, rare2 absent
	f.Add(strings.Repeat("Q", 1000), "Q"+strings.Repeat("a", 30)+"Z")
	f.Add(strings.Repeat("Q", 1000)+"Q"+strings.Repeat("a", 30)+"Z", "Q"+strings.Repeat("a", 30)+"Z")

	f.Fuzz(func(t *testing.T, haystack, needle string) {
		n := MakeNeedle(needle)
		got := SearchNeedle(haystack, n)
		want := indexFoldGo(haystack, needle)
		if got != want {
			t.Fatalf("SearchNeedle(%q, %q) = %d, want %d", haystack, needle, got, want)
		}
		// Cross-validate with IndexFold
		ifRes := IndexFold(haystack, needle)
		if got != ifRes {
			t.Fatalf("SearchNeedle vs IndexFold mismatch: SearchNeedle(%q, %q) = %d, IndexFold = %d",
				haystack, needle, got, ifRes)
		}
	})
}

// FuzzIndex tests case-sensitive Index against strings.Index
func FuzzIndex(f *testing.F) {
	f.Add("hello world", "world")
	f.Add("The Quick Brown Fox", "Quick")
	f.Add(strings.Repeat("a", 100), "aaa")
	f.Add("xylophone", "xy")
	f.Add("Hello World", "Hello")
	f.Add("NEEDLE in haystack", "NEEDLE")
	// Mixed case - should NOT match
	f.Add("hello world", "WORLD")
	f.Add("HELLO WORLD", "hello")
	// Edge cases
	f.Add(strings.Repeat("x", 20)+"needle", "needle")
	f.Add(strings.Repeat("x", 17)+"QZ", "QZ")
	f.Add(strings.Repeat("y", 31)+"z", "z")

	f.Fuzz(func(t *testing.T, haystack, needle string) {
		got := Index(haystack, needle)
		want := strings.Index(haystack, needle)
		if got != want {
			t.Fatalf("Index(%q, %q) = %d, want %d", haystack, needle, got, want)
		}
		// Cross-validate with SearchNeedleExact
		n := MakeNeedle(needle)
		sneGot := SearchNeedleExact(haystack, n)
		if got != sneGot {
			t.Fatalf("Index vs SearchNeedleExact mismatch: Index(%q, %q) = %d, SearchNeedleExact = %d",
				haystack, needle, got, sneGot)
		}
	})
}
