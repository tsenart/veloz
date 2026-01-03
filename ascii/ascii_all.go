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
