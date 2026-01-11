//go:build !noasm && arm64

package ascii

// searchTBL_NEON is the NEON-accelerated TBL engine for 1-8 patterns.
// Returns the final foundMask after scanning the haystack.
//
//go:noescape
func searchTBL_NEON(
	haystack string,
	masksLo *[16]uint8,
	masksHi *[16]uint8,
	verifyValues *[64]uint64,
	verifyMasks *[64]uint64,
	verifyLengths *[64]uint8,
	verifyPtrs *[64]string,
	numPatterns int,
	minPatternLen int,
	immediateTrueMask uint64,
	immediateFalseMask uint64,
	initialFoundMask uint64,
) uint64

// searchFDR_NEON is the NEON-accelerated FDR engine for 9-64 patterns.
// Uses TBL prefilter for fast path, then FDR hash confirmation.
// Returns the final foundMask after scanning the haystack.
//
//go:noescape
func searchFDR_NEON(
	haystack string,
	stateTable *uint64,
	domainMask uint32,
	stride int,
	coarseLo *[16]uint8,
	coarseHi *[16]uint8,
	groupLUT *[256]uint64,
	verifyValues *[64]uint64,
	verifyMasks *[64]uint64,
	verifyLengths *[64]uint8,
	verifyPtrs *[64]string,
	numPatterns int,
	minPatternLen int,
	immediateTrueMask uint64,
	immediateFalseMask uint64,
	initialFoundMask uint64,
) uint64
