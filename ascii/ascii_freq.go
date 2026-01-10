//go:build !noasm && arm64

package ascii

// foldedFreq contains approximate letter frequency scores for case-folded bytes.
// Values are 0-255 where higher = more common in English text.
// Used to decide whether 1-byte fast path is worth trying.
//
// Frequency data source: English text analysis (Wikipedia, literature)
// Common letters: e(12.7%), t(9.1%), a(8.2%), o(7.5%), i(7.0%), n(6.7%), s(6.3%)
// Rare letters: z(0.07%), q(0.10%), x(0.15%), j(0.15%)
// Punctuation: estimated from code/JSON mix
//
// Score mapping: freq% * 2 (capped at 255)
// - Score >= 10 (5%+ frequency): use 2-byte NEON directly
// - Score < 10 (rare): try 1-byte fast path with adaptive cutover
var foldedFreq = [256]uint8{
	// Control chars (0x00-0x1F): rare
	0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 0, 0, 2, 0, 0, // 0x00-0x0F (tab, lf, cr get 2)
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x10-0x1F

	// Punctuation/symbols (0x20-0x3F)
	20, // 0x20 ' ' - very common
	3,  // 0x21 '!' - rare
	8,  // 0x22 '"' - common in JSON/code
	2,  // 0x23 '#' - rare
	2,  // 0x24 '$' - rare
	1,  // 0x25 '%' - rare
	2,  // 0x26 '&' - rare
	4,  // 0x27 '\'' - moderately common
	4,  // 0x28 '(' - moderately common
	4,  // 0x29 ')' - moderately common
	2,  // 0x2A '*' - rare
	2,  // 0x2B '+' - rare
	6,  // 0x2C ',' - common
	4,  // 0x2D '-' - moderately common
	6,  // 0x2E '.' - common
	3,  // 0x2F '/' - rare
	6,  // 0x30 '0' - common
	5,  // 0x31 '1' - moderately common
	4,  // 0x32 '2' - moderately common
	3,  // 0x33 '3' - moderate
	3,  // 0x34 '4' - moderate
	3,  // 0x35 '5' - moderate
	3,  // 0x36 '6' - moderate
	3,  // 0x37 '7' - moderate
	3,  // 0x38 '8' - moderate
	3,  // 0x39 '9' - moderate
	5,  // 0x3A ':' - common in JSON/code
	3,  // 0x3B ';' - moderate
	2,  // 0x3C '<' - rare
	4,  // 0x3D '=' - moderate
	2,  // 0x3E '>' - rare
	1,  // 0x3F '?' - rare

	// Uppercase letters (0x40-0x5F) - mapped to lowercase frequencies
	2,  // 0x40 '@' - rare
	16, // 0x41 'A' - 8.2%
	3,  // 0x42 'B' - 1.5%
	6,  // 0x43 'C' - 2.8%
	9,  // 0x44 'D' - 4.3%
	25, // 0x45 'E' - 12.7% (most common!)
	4,  // 0x46 'F' - 2.2%
	4,  // 0x47 'G' - 2.0%
	12, // 0x48 'H' - 6.1%
	14, // 0x49 'I' - 7.0%
	1,  // 0x4A 'J' - 0.15% (rare!)
	2,  // 0x4B 'K' - 0.8%
	8,  // 0x4C 'L' - 4.0%
	5,  // 0x4D 'M' - 2.4%
	13, // 0x4E 'N' - 6.7%
	15, // 0x4F 'O' - 7.5%
	4,  // 0x50 'P' - 1.9%
	1,  // 0x51 'Q' - 0.10% (rare!)
	12, // 0x52 'R' - 6.0%
	13, // 0x53 'S' - 6.3%
	18, // 0x54 'T' - 9.1%
	6,  // 0x55 'U' - 2.8%
	2,  // 0x56 'V' - 1.0%
	5,  // 0x57 'W' - 2.4%
	1,  // 0x58 'X' - 0.15% (rare!)
	4,  // 0x59 'Y' - 2.0%
	1,  // 0x5A 'Z' - 0.07% (rarest!)
	3,  // 0x5B '[' - moderate
	2,  // 0x5C '\' - rare
	3,  // 0x5D ']' - moderate
	1,  // 0x5E '^' - rare
	4,  // 0x5F '_' - moderate

	// Lowercase letters (0x60-0x7F) - same as uppercase
	1,  // 0x60 '`' - rare
	16, // 0x61 'a' - 8.2%
	3,  // 0x62 'b' - 1.5%
	6,  // 0x63 'c' - 2.8%
	9,  // 0x64 'd' - 4.3%
	25, // 0x65 'e' - 12.7% (most common!)
	4,  // 0x66 'f' - 2.2%
	4,  // 0x67 'g' - 2.0%
	12, // 0x68 'h' - 6.1%
	14, // 0x69 'i' - 7.0%
	1,  // 0x6A 'j' - 0.15% (rare!)
	2,  // 0x6B 'k' - 0.8%
	8,  // 0x6C 'l' - 4.0%
	5,  // 0x6D 'm' - 2.4%
	13, // 0x6E 'n' - 6.7%
	15, // 0x6F 'o' - 7.5%
	4,  // 0x70 'p' - 1.9%
	1,  // 0x71 'q' - 0.10% (rare!)
	12, // 0x72 'r' - 6.0%
	13, // 0x73 's' - 6.3%
	18, // 0x74 't' - 9.1%
	6,  // 0x75 'u' - 2.8%
	2,  // 0x76 'v' - 1.0%
	5,  // 0x77 'w' - 2.4%
	1,  // 0x78 'x' - 0.15% (rare!)
	4,  // 0x79 'y' - 2.0%
	1,  // 0x7A 'z' - 0.07% (rarest!)
	3,  // 0x7B '{' - moderate (JSON)
	2,  // 0x7C '|' - rare
	3,  // 0x7D '}' - moderate (JSON)
	1,  // 0x7E '~' - rare
	0,  // 0x7F DEL - rare

	// High bytes (0x80-0xFF): assume rare in ASCII-centric workloads
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0x80-0x8F
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0x90-0x9F
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0xA0-0xAF
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0xB0-0xBF
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0xC0-0xCF
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0xD0-0xDF
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0xE0-0xEF
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0xF0-0xFF
}

// RareByteThreshold is the frequency score below which we try 1-byte fast path.
// Bytes with score < threshold are considered "rare" and worth fast-pathing.
// Score 8 means ~4% frequency - below this, false positives are manageable.
const RareByteThreshold = 8

// isRareByte returns true if the byte is rare enough for 1-byte fast path.
func isRareByte(b byte) bool {
	return foldedFreq[b] < RareByteThreshold
}
