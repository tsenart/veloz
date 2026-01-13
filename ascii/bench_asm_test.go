//go:build arm64

package ascii

import (
    "testing"
    "math/rand"
    "unicode"
    "fmt"
    "strings"
)

func BenchmarkAsmVsCgo(b *testing.B) {
    rnd := rand.New(rand.NewSource(0))

    for _, n := range []int{15, 44, 100} {
        asciiBuf := makeASCII(n)
        s1 := string(asciiBuf)

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
        
        rare1, off1, rare2, off2 := selectRarePairSample(s2, nil, false)
        norm := strings.ToLower(s2)

        b.Run(fmt.Sprintf("cgo-%d", n), func(b *testing.B) {
            b.SetBytes(int64(len(s1)))
            for i := 0; i < b.N; i++ {
                indexFoldNEONC(s1, rare1, off1, rare2, off2, s2)
            }
        })

        b.Run(fmt.Sprintf("asm-%d", n), func(b *testing.B) {
            b.SetBytes(int64(len(s1)))
            for i := 0; i < b.N; i++ {
                indexFoldNEON(s1, rare1, off1, rare2, off2, norm)
            }
        })

        b.Run(fmt.Sprintf("simple-%d", n), func(b *testing.B) {
            b.SetBytes(int64(len(s1)))
            for i := 0; i < b.N; i++ {
                SearchNeedleFoldSimple(s1, rare1, off1, rare2, off2, norm)
            }
        })
    }
}

func BenchmarkMemchrStyle(b *testing.B) {
    rnd := rand.New(rand.NewSource(0))

    for _, n := range []int{15, 44, 100, 1000} {
        asciiBuf := makeASCII(n)
        s1 := string(asciiBuf)

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
        
        rare1, off1, rare2, off2 := selectRarePairSample(s2, nil, false)
        norm := strings.ToLower(s2)

        b.Run(fmt.Sprintf("memchr-%d", n), func(b *testing.B) {
        	b.SetBytes(int64(len(s1)))
        	for i := 0; i < b.N; i++ {
        		IndexFoldMemchr(s1, rare1, off1, rare2, off2, s2)
        	}
        })

        b.Run(fmt.Sprintf("asm-%d", n), func(b *testing.B) {
        	b.SetBytes(int64(len(s1)))
        	for i := 0; i < b.N; i++ {
        		indexFoldNEON(s1, rare1, off1, rare2, off2, norm)
        	}
        })

        _ = norm // suppress unused warning
    }
}

func BenchmarkMemchrLarge(b *testing.B) {
    const size = 1 << 20 // 1MB

    needle := "quartz"
    norm := strings.ToLower(needle)
    rare1, off1, rare2, off2 := selectRarePairSample(needle, nil, false)
    haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", size/24) + needle

    b.Run("memchr-1MB", func(b *testing.B) {
        b.SetBytes(int64(len(haystack)))
        for i := 0; i < b.N; i++ {
            IndexFoldMemchr(haystack, rare1, off1, rare2, off2, needle)
        }
    })

    b.Run("asm-1MB", func(b *testing.B) {
        b.SetBytes(int64(len(haystack)))
        for i := 0; i < b.N; i++ {
            indexFoldNEON(haystack, rare1, off1, rare2, off2, norm)
        }
    })


}

func BenchmarkSimpleLargeInput(b *testing.B) {
    // Test large-input throughput for simplified implementation
    const size = 1 << 20 // 1MB

    // Zero false-positive case: needle "quartz" (Q, Z rare), haystack has no Q or Z
    needle := "quartz"
    norm := strings.ToLower(needle)
    rare1, off1, rare2, off2 := selectRarePairSample(needle, nil, false)
    haystack := strings.Repeat("abcdefghijklmnoprstuvwy ", size/24) + needle

    b.Run("simple-1MB", func(b *testing.B) {
        b.SetBytes(int64(len(haystack)))
        for i := 0; i < b.N; i++ {
            SearchNeedleFoldSimple(haystack, rare1, off1, rare2, off2, norm)
        }
    })

    b.Run("asm-1MB", func(b *testing.B) {
        b.SetBytes(int64(len(haystack)))
        for i := 0; i < b.N; i++ {
            indexFoldNEON(haystack, rare1, off1, rare2, off2, norm)
        }
    })

    b.Run("cgo-1MB", func(b *testing.B) {
        b.SetBytes(int64(len(haystack)))
        for i := 0; i < b.N; i++ {
            indexFoldNEONC(haystack, rare1, off1, rare2, off2, needle)
        }
    })
}
