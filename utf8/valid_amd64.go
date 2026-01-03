package utf8

import (
	stdlib "unicode/utf8"

	"github.com/mhr3/veloz/ascii"
	"golang.org/x/sys/cpu"
)

var hasAVX2 = cpu.X86.HasAVX

func ValidString(s string) bool {
	if !hasAVX2 {
		return stdlib.ValidString(s)
	}

	// speed up the common case
	idx := ascii.IndexMask(s, 0x80)
	if idx == -1 {
		return true
	}

	return utf8_valid_range_avx2(s)
}
