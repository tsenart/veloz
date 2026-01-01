package ascii

import (
	"golang.org/x/sys/cpu"
)

var (
	hasSSE41 = cpu.X86.HasSSE41
	hasAVX2  = cpu.X86.HasAVX
)

func ValidString(s string) bool {
	if hasAVX2 {
		return isAsciiAvx(s)
	}

	if hasSSE41 {
		return isAsciiSse(s)
	}

	return isAsciiGo(s)
}

func IndexMask(s string, mask byte) int {
	// TODO: implement acceleration for this
	return indexMaskGo(s, mask)
}

func EqualFold(a, b string) bool {
	// TODO: implement acceleration for this
	return equalFoldGo(a, b)
}

func IndexFold(a, b string) int {
	// TODO: implement acceleration for this
	return indexFoldGo(a, b)
}

func IndexFoldRabinKarp(a, b string) int {
	// FIXME: definitely not Rabin-Karp
	return indexFoldGo(a, b)
}
