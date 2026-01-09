package ascii

func HasPrefixFold(s, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	return EqualFold(s[:len(prefix)], prefix)
}

func HasSuffixFold(s, suffix string) bool {
	if len(s) < len(suffix) {
		return false
	}
	return EqualFold(s[len(s)-len(suffix):], suffix)
}

// ContainsAny reports whether any byte from chars is in data.
func ContainsAny(data, chars string) bool {
	return IndexAny(data, chars) >= 0
}

// ContainsAnyCharSet reports whether any byte from cs is in data.
func ContainsAnyCharSet(data string, cs CharSet) bool {
	return IndexAnyCharSet(data, cs) >= 0
}

// IndexNonASCII finds the first non-ASCII byte (>= 0x80) in the string.
// Returns -1 if all bytes are ASCII.
func IndexNonASCII(data string) int {
	return IndexMask(data, 0x80)
}
