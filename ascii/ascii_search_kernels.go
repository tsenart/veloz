//go:build !noasm && arm64

// Hand-optimized ARM64 NEON assembly kernels for staged substring search.

package ascii

//go:noescape
func indexFold1Byte(haystack string, needle string, off1 int) uint64

//go:noescape
func indexExact1Byte(haystack string, needle string, off1 int) uint64

//go:noescape
func indexFold2Byte(haystack string, needle string, off1 int, off2Delta int) uint64

//go:noescape
func indexExact2Byte(haystack string, needle string, off1 int, off2Delta int) uint64

//go:noescape
func indexFold1ByteRaw(haystack string, needle string, off1 int) uint64

//go:noescape
func indexFold2ByteRaw(haystack string, needle string, off1 int, off2Delta int) uint64
