package ascii

import "math/bits"

// byteRank is a frequency table for bytes based on corpus analysis.
// Lower rank = rarer byte = better candidate for rare-byte search.
// Derived from memchr's BYTE_FREQUENCIES table (corpus: CIA World Factbook,
// rustc source, Septuaginta). UTF-8 prefix bytes (0xC0-0xFF) forced to 255
// since continuation bytes are more discriminating.
var byteRank = [256]byte{
	// 0x00-0x0F: control characters (mostly rare)
	55, 52, 51, 50, 49, 48, 47, 46, 45, 103, 242, 66, 67, 229, 44, 43,
	// 0x10-0x1F: more control characters
	42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 56, 32, 31, 30, 29, 28,
	// 0x20-0x2F: space and punctuation
	255, // ' ' - most common
	148, // '!'
	164, // '"' - common in JSON
	149, // '#'
	136, // '$'
	160, // '%'
	155, // '&'
	173, // '\''
	221, // '('
	222, // ')'
	134, // '*'
	122, // '+'
	232, // ',' - common
	202, // '-'
	215, // '.'
	224, // '/'
	// 0x30-0x39: digits
	208, // '0'
	220, // '1'
	204, // '2'
	187, // '3'
	183, // '4'
	179, // '5'
	177, // '6'
	168, // '7'
	178, // '8'
	200, // '9'
	// 0x3A-0x40: more punctuation
	226, // ':' - common in JSON
	195, // ';'
	154, // '<'
	184, // '='
	174, // '>'
	126, // '?'
	120, // '@'
	// 0x41-0x5A: uppercase A-Z
	191, // 'A'
	157, // 'B'
	194, // 'C'
	170, // 'D'
	189, // 'E'
	162, // 'F'
	161, // 'G'
	150, // 'H'
	193, // 'I'
	142, // 'J'
	137, // 'K'
	171, // 'L'
	176, // 'M'
	185, // 'N'
	167, // 'O'
	186, // 'P'
	112, // 'Q' - rare
	175, // 'R'
	192, // 'S'
	188, // 'T'
	156, // 'U'
	140, // 'V'
	143, // 'W'
	123, // 'X' - rare
	133, // 'Y'
	128, // 'Z' - rare
	// 0x5B-0x60: brackets and punctuation
	147, // '['
	138, // '\\'
	146, // ']'
	114, // '^'
	223, // '_'
	151, // '`'
	// 0x61-0x7A: lowercase a-z
	249, // 'a'
	216, // 'b'
	238, // 'c'
	236, // 'd'
	253, // 'e' - most common letter
	227, // 'f'
	218, // 'g'
	230, // 'h'
	247, // 'i'
	135, // 'j' - rare
	180, // 'k'
	241, // 'l'
	233, // 'm'
	246, // 'n'
	244, // 'o'
	231, // 'p'
	139, // 'q' - rare
	245, // 'r'
	243, // 's'
	251, // 't'
	235, // 'u'
	201, // 'v'
	196, // 'w'
	240, // 'x'
	214, // 'y'
	152, // 'z' - rare
	// 0x7B-0x7F: braces and control
	182, // '{'
	205, // '|'
	181, // '}'
	127, // '~'
	27,  // DEL
	// 0x80-0xBF: UTF-8 continuation bytes (varied frequency in real UTF-8 text)
	212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80, 98, 96, 97, 81,
	207, 145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82, 108,
	118, 141, 113, 129, 119, 125, 165, 117, 92, 106, 83, 72, 99, 93, 65, 79,
	166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239,
	// 0xC0-0xFF: UTF-8 prefix bytes (force to 255 = most common, per memchr)
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
}

// toUpper converts ASCII lowercase to uppercase.
func toUpper(b byte) byte {
	if b >= 'a' && b <= 'z' {
		return b - 0x20
	}
	return b
}

// normalizeASCII converts a string to uppercase ASCII.
func normalizeASCII(s string) string {
	b := make([]byte, len(s))
	for i := 0; i < len(s); i++ {
		b[i] = toUpper(s[i])
	}
	return string(b)
}

// normalizeInto converts s to uppercase ASCII into dst.
// dst must be at least len(s) bytes.
func normalizeInto(dst []byte, s string) {
	_ = dst[len(s)-1] // bounds check hint
	for i := 0; i < len(s); i++ {
		dst[i] = toUpper(s[i])
	}
}

// selectRarePair finds two rare bytes in O(n) time.
// Returns the two rarest bytes and their offsets, with off1 < off2.
// If ranks is nil, uses the default byteRank table.
func selectRarePair(needle string, ranks []byte) (rare1 byte, off1 int, rare2 byte, off2 int) {
	n := len(needle)
	if n == 0 {
		return 0, 0, 0, 0
	}
	if n == 1 {
		return toUpper(needle[0]), 0, toUpper(needle[0]), 0
	}

	if ranks == nil {
		ranks = byteRank[:]
	}

	// Find the two rarest bytes in a single pass
	best1Rank, best2Rank := byte(255), byte(255)
	best1Idx, best2Idx := 0, n-1

	for i := 0; i < n; i++ {
		norm := toUpper(needle[i])
		rank := ranks[norm]
		if rank < best1Rank {
			// New rarest - demote current best1 to best2
			best2Rank, best2Idx = best1Rank, best1Idx
			best1Rank, best1Idx = rank, i
		} else if rank < best2Rank && i != best1Idx {
			best2Rank, best2Idx = rank, i
		}
	}

	// Ensure off1 < off2
	if best1Idx > best2Idx {
		best1Idx, best2Idx = best2Idx, best1Idx
	}

	return toUpper(needle[best1Idx]), best1Idx, toUpper(needle[best2Idx]), best2Idx
}

// Needle represents a precomputed needle for fast case-insensitive search.
// Build once with MakeNeedle, reuse with SearchNeedle.
type Needle struct {
	raw   string // original needle
	norm  string // uppercase needle (for verification)
	rare1 byte   // first rare byte (normalized)
	off1  int    // offset in needle
	rare2 byte   // second rare byte (normalized)
	off2  int    // offset in needle
}

// ByteRank exposes the default frequency table for ASCII bytes (read-only).
// Lower rank = rarer byte = better candidate for rare-byte search.
// This table is not consulted by MakeNeedle; to customize rare-byte selection,
// copy this table, modify it, and pass to MakeNeedleWithRanks.
var ByteRank = byteRank

// MakeNeedle precomputes a needle for repeated case-insensitive searches.
// Uses the default English frequency table for rare-byte selection.
func MakeNeedle(needle string) Needle {
	rare1, off1, rare2, off2 := selectRarePair(needle, nil)
	return Needle{
		raw:   needle,
		norm:  normalizeASCII(needle),
		rare1: rare1,
		off1:  off1,
		rare2: rare2,
		off2:  off2,
	}
}

// MakeNeedleWithRanks precomputes a needle using a custom byte frequency table.
// The ranks slice must have 256 entries where lower values indicate rarer bytes.
//
// Use this for specialized corpora where byte frequencies differ from English:
//   - DNA sequences (A, C, G, T equally common)
//   - Hex dumps (0-9, A-F equally common)
//   - Domain-specific logs with unusual patterns
//
// To build a rank table from a corpus:
//
//	var counts [256]int
//	for i := 0; i < len(corpus); i++ {
//	    c := corpus[i]
//	    if c >= 'a' && c <= 'z' { c -= 0x20 }  // uppercase
//	    counts[c]++
//	}
//	maxCount := slices.Max(counts[:])
//	ranks := make([]byte, 256)
//	for i, c := range counts {
//	    ranks[i] = byte(c * 255 / maxCount)
//	}
func MakeNeedleWithRanks(needle string, ranks []byte) Needle {
	if len(ranks) != 256 {
		panic("ranks must have exactly 256 entries")
	}
	rare1, off1, rare2, off2 := selectRarePair(needle, ranks)
	return Needle{
		raw:   needle,
		norm:  normalizeASCII(needle),
		rare1: rare1,
		off1:  off1,
		rare2: rare2,
		off2:  off2,
	}
}

func indexMaskGo[T string | []byte](s T, mask byte) int {
	mask32 := uint32(mask)
	mask32 |= mask32 << 8
	mask32 |= mask32 << 16

	pos := 0
	// use all go tricks to make this fast
	for ; len(s) >= 8; pos, s = pos+8, s[8:] {
		_ = s[7]
		first32 := uint32(s[0]) | uint32(s[1])<<8 | uint32(s[2])<<16 | uint32(s[3])<<24
		second32 := uint32(s[4]) | uint32(s[5])<<8 | uint32(s[6])<<16 | uint32(s[7])<<24
		if (first32|second32)&mask32 != 0 {
			first32 &= mask32
			if first32 != 0 {
				return pos + bits.TrailingZeros32(first32)/8
			}
			second32 &= mask32
			return pos + 4 + bits.TrailingZeros32(second32)/8
		}
	}

	for i := 0; i < len(s); i++ {
		b := s[i]
		if b&mask != 0 {
			return pos + i
		}
	}
	return -1
}

func isAsciiGo[T string | []byte](s T) bool {
	return indexMaskGo(s, 0x80) == -1
}

// based on https://graphics.stanford.edu/~seander/bithacks.html#HasBetweenInWord
func hasLowercaseAsciiByte(x uint64) uint64 {
	const mult = ^uint64(0) / 255
	const m, n = 'a' - 1, 'z' + 1

	A := mult * (127 + n)
	B := x & (mult * 127)
	C := ^x
	D := mult * (127 - m)
	return (A - B) & C & (B + D) & (mult * 128)
}

func asciiFoldWord(x uint64) uint64 {
	mask := hasLowercaseAsciiByte(x)
	mask >>= 2
	return x - mask
}

func equalFoldGo(a, b string) bool {
	if len(a) != len(b) {
		return false
	}

	for len(a) >= 8 {
		_ = a[7]
		_ = b[7]

		// the compiler should be able to optimize this to two 64-bit loads
		a64 := uint64(a[0]) | uint64(a[1])<<8 | uint64(a[2])<<16 | uint64(a[3])<<24 |
			uint64(a[4])<<32 | uint64(a[5])<<40 | uint64(a[6])<<48 | uint64(a[7])<<56
		b64 := uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 |
			uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56

		if a64 != b64 {
			a64 = asciiFoldWord(a64)
			b64 = asciiFoldWord(b64)
			if a64 != b64 {
				return false
			}
		}
		a = a[8:]
		b = b[8:]
	}

	var a0, a1, b0, b1 uint32
	switch len(a) {
	case 7:
		fallthrough
	case 6:
		fallthrough
	case 5:
		// get the data using four 32-bit loads
		_, _ = a[3], b[3]
		a0 = uint32(a[0]) | uint32(a[1])<<8 | uint32(a[2])<<16 | uint32(a[3])<<24
		b0 = uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24

		idx := len(a) - 4
		a, b = a[idx:], b[idx:]
		_, _ = a[3], b[3]
		a1 = uint32(a[0]) | uint32(a[1])<<8 | uint32(a[2])<<16 | uint32(a[3])<<24
		b1 = uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
	case 4:
		_ = b[3]
		a0 = uint32(a[0]) | uint32(a[1])<<8 | uint32(a[2])<<16 | uint32(a[3])<<24
		b0 = uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
	case 3:
		a0 = uint32(a[0]) | uint32(a[1])<<8 | uint32(a[2])<<16
		_ = b[2]
		b0 = uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16
	case 2:
		a0 = uint32(a[0]) | uint32(a[1])<<8
		_ = b[1]
		b0 = uint32(b[0]) | uint32(b[1])<<8
	case 1:
		a0 = uint32(a[0])
		b0 = uint32(b[0])
	case 0:
		return true
	}

	a64 := uint64(a0) | uint64(a1)<<32
	b64 := uint64(b0) | uint64(b1)<<32
	if a64 == b64 {
		return true
	}

	return asciiFoldWord(a64) == asciiFoldWord(b64)
}

func indexFoldGo[T string | []byte](s T, substr T) int {
	if len(substr) == 0 {
		return 0
	} else if len(substr) > len(s) {
		return -1
	}

	first := substr[0]
	complement := first
	if first >= 'A' && first <= 'Z' {
		complement += 0x20
	} else if first >= 'a' && first <= 'z' {
		complement -= 0x20
	}

	for i := 0; i <= len(s)-len(substr); i++ {
		b := byte(s[i])
		if b == first || b == complement {
			prefix := s[i:]
			if equalFoldGo(string(prefix[:len(substr)]), string(substr)) {
				return i
			}
		}
	}
	return -1
}

func indexAnyGo(s, chars string) int {
	if len(chars) == 0 {
		return -1
	}
	// Build 256-bit set (8 uint32s) for O(1) lookup per byte
	var set [8]uint32
	for i := 0; i < len(chars); i++ {
		c := chars[i]
		set[c>>5] |= 1 << (c & 31)
	}
	// O(n) scan
	for i := 0; i < len(s); i++ {
		c := s[i]
		if set[c>>5]&(1<<(c&31)) != 0 {
			return i
		}
	}
	return -1
}
