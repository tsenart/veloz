package utf8

import "github.com/mhr3/veloz/ascii"

func ValidString(s string) bool {
	// speed up the common case
	idx := ascii.IndexMask(s, 0x80)
	if idx == -1 {
		return true
	}

	return utf8_valid_range(s[idx:])
}
