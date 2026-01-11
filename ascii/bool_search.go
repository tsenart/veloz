package ascii

import (
	"math/bits"
	"unsafe"
)

// =============================================================================
// Expression Types - Three-Valued Boolean Logic
// =============================================================================

// Result represents the three-valued logic result: TRUE, FALSE, or UNKNOWN.
type Result int8

const (
	UNKNOWN Result = iota
	TRUE
	FALSE
)

// BoolExpr represents a boolean expression over substring patterns.
type BoolExpr interface {
	// Evaluate evaluates the expression given the set of found patterns.
	// If final is true, patterns not in foundMask are considered not found.
	// If final is false, patterns not in foundMask are UNKNOWN.
	Evaluate(foundMask uint64, final bool) Result

	// collectPatterns collects all patterns in this expression into the slice.
	collectPatterns(patterns *[]Pattern)
}

// ContainsExpr represents a case-insensitive substring containment check.
type ContainsExpr struct {
	Pattern       string
	CaseSensitive bool
	patternID     uint8 // assigned during compilation
}

// AndExpr represents logical AND of two expressions.
type AndExpr struct {
	Left, Right BoolExpr
}

// OrExpr represents logical OR of two expressions.
type OrExpr struct {
	Left, Right BoolExpr
}

// NotExpr represents logical NOT of an expression.
type NotExpr struct {
	Child BoolExpr
}

// =============================================================================
// Expression Constructors
// =============================================================================

// Contains creates a case-insensitive containment expression.
func Contains(pattern string) *ContainsExpr {
	return &ContainsExpr{Pattern: pattern, CaseSensitive: false}
}

// ContainsCI is an alias for Contains (case-insensitive).
func ContainsCI(pattern string) *ContainsExpr {
	return &ContainsExpr{Pattern: pattern, CaseSensitive: false}
}

// ContainsCS creates a case-sensitive containment expression.
func ContainsCS(pattern string) *ContainsExpr {
	return &ContainsExpr{Pattern: pattern, CaseSensitive: true}
}

// And creates an AND expression.
func And(left, right BoolExpr) *AndExpr {
	return &AndExpr{Left: left, Right: right}
}

// Or creates an OR expression.
func Or(left, right BoolExpr) *OrExpr {
	return &OrExpr{Left: left, Right: right}
}

// Not creates a NOT expression.
func Not(child BoolExpr) *NotExpr {
	return &NotExpr{Child: child}
}

// =============================================================================
// Expression Evaluation
// =============================================================================

func (e *ContainsExpr) Evaluate(foundMask uint64, final bool) Result {
	if foundMask&(1<<e.patternID) != 0 {
		return TRUE
	}
	if final {
		return FALSE
	}
	return UNKNOWN
}

func (e *AndExpr) Evaluate(foundMask uint64, final bool) Result {
	l := e.Left.Evaluate(foundMask, final)
	r := e.Right.Evaluate(foundMask, final)

	if l == FALSE || r == FALSE {
		return FALSE
	}
	if l == TRUE && r == TRUE {
		return TRUE
	}
	return UNKNOWN
}

func (e *OrExpr) Evaluate(foundMask uint64, final bool) Result {
	l := e.Left.Evaluate(foundMask, final)
	r := e.Right.Evaluate(foundMask, final)

	if l == TRUE || r == TRUE {
		return TRUE
	}
	if l == FALSE && r == FALSE {
		return FALSE
	}
	return UNKNOWN
}

func (e *NotExpr) Evaluate(foundMask uint64, final bool) Result {
	c := e.Child.Evaluate(foundMask, final)

	if c == TRUE {
		return FALSE
	}
	if c == FALSE {
		return TRUE
	}
	return UNKNOWN
}

// =============================================================================
// Pattern Collection
// =============================================================================

func (e *ContainsExpr) collectPatterns(patterns *[]Pattern) {
	*patterns = append(*patterns, Pattern{
		Text:          e.Pattern,
		CaseSensitive: e.CaseSensitive,
	})
}

func (e *AndExpr) collectPatterns(patterns *[]Pattern) {
	e.Left.collectPatterns(patterns)
	e.Right.collectPatterns(patterns)
}

func (e *OrExpr) collectPatterns(patterns *[]Pattern) {
	e.Left.collectPatterns(patterns)
	e.Right.collectPatterns(patterns)
}

func (e *NotExpr) collectPatterns(patterns *[]Pattern) {
	e.Child.collectPatterns(patterns)
}

// =============================================================================
// Data Structures
// =============================================================================

// Pattern represents a single search pattern with its metadata.
type Pattern struct {
	ID            uint8
	Text          string
	Length        int
	CaseSensitive bool
	normText      string // uppercase-normalized for case-insensitive
}

// FloodEntry stores flood detection info for a single byte value.
type FloodEntry struct {
	patternIDs []uint8
	minLength  uint8
}

// BooleanSearch is the compiled multi-needle boolean search engine.
type BooleanSearch struct {
	// === Expression ===
	expr               BoolExpr
	immediateTrueMask  uint64 // finding any of these → TRUE
	immediateFalseMask uint64 // finding any of these → FALSE

	// === Patterns ===
	patterns      []Pattern
	numPatterns   int
	minPatternLen int

	// === Engine Selection ===
	useFDR bool // true for 9-64 patterns

	// === Direct TBL Engine (1-8 patterns) ===
	tbl struct {
		masksLo [16]uint8 // TBL masks: lo_nibble → 8-bit pattern mask
		masksHi [16]uint8 // TBL masks: hi_nibble → 8-bit pattern mask
	}

	// === FDR Engine (9-64 patterns) ===
	fdr struct {
		domain     int      // 9-15 bits
		domainMask uint32   // (1 << domain) - 1
		stride     int      // 1, 2, or 4
		stateTable []uint64 // 2^domain entries, each is 64-bit pattern mask

		// TBL prefilter: coarse group-based filtering to skip most FDR lookups
		// Patterns are partitioned into 8 groups (0-7). The TBL lookup gives
		// an 8-bit mask where bit g=1 means group g might have a match.
		coarseLo   [16]uint8   // nibble → 8-bit group mask (inverted: 0=might match)
		coarseHi   [16]uint8   // nibble → 8-bit group mask (inverted: 0=might match)
		groupMasks [8]uint64   // for each group, which patterns (64-bit mask) belong to it
		groupLUT   [256]uint64 // 8-bit group mask → 64-bit pattern mask (precomputed)
	}

	// === Verification ===
	verify struct {
		values  [64]uint64 // first 8 bytes as uint64, with case-fold applied
		masks   [64]uint64 // mask: 0 bits where don't-care
		lengths [64]uint8
		ptrs    [64]string // full pattern for long verification
	}

	// === Flood Detection ===
	flood [256]FloodEntry
}

// =============================================================================
// Construction
// =============================================================================

// MakeBooleanSearch compiles a boolean expression into a search engine.
func MakeBooleanSearch(expr BoolExpr) *BooleanSearch {
	bs := &BooleanSearch{
		expr: expr,
	}

	// Extract patterns from expression tree
	bs.extractPatterns()

	// Select engine based on pattern count
	bs.useFDR = bs.numPatterns > 8

	// Build search tables
	if bs.useFDR {
		bs.buildFDRTables()
	} else {
		bs.buildTBLMasks()
	}

	bs.buildVerifyTables()
	bs.buildFloodTable()
	bs.computeImmediateMasks()

	return bs
}

// extractPatterns collects all patterns from the expression tree and assigns IDs.
func (bs *BooleanSearch) extractPatterns() {
	var patterns []Pattern
	bs.expr.collectPatterns(&patterns)

	// Deduplicate patterns by text (case-normalized)
	seen := make(map[string]uint8)
	unique := make([]Pattern, 0, len(patterns))

	for _, p := range patterns {
		norm := toUpperString(p.Text)
		if id, ok := seen[norm]; ok {
			// Pattern already exists, reuse ID
			p.ID = id
		} else {
			p.ID = uint8(len(unique))
			p.Length = len(p.Text)
			p.normText = norm
			seen[norm] = p.ID
			unique = append(unique, p)
		}
	}

	bs.patterns = unique
	bs.numPatterns = len(unique)

	// Calculate minimum pattern length
	bs.minPatternLen = 255
	for _, p := range unique {
		if p.Length < bs.minPatternLen {
			bs.minPatternLen = p.Length
		}
	}
	if bs.minPatternLen == 255 {
		bs.minPatternLen = 1
	}

	// Assign IDs back to expression nodes
	bs.assignPatternIDs(bs.expr, seen)
}

// assignPatternIDs assigns pattern IDs to ContainsExpr nodes.
func (bs *BooleanSearch) assignPatternIDs(expr BoolExpr, idMap map[string]uint8) {
	switch e := expr.(type) {
	case *ContainsExpr:
		norm := toUpperString(e.Pattern)
		e.patternID = idMap[norm]
	case *AndExpr:
		bs.assignPatternIDs(e.Left, idMap)
		bs.assignPatternIDs(e.Right, idMap)
	case *OrExpr:
		bs.assignPatternIDs(e.Left, idMap)
		bs.assignPatternIDs(e.Right, idMap)
	case *NotExpr:
		bs.assignPatternIDs(e.Child, idMap)
	}
}

// toUpperString converts a string to uppercase (ASCII only).
func toUpperString(s string) string {
	b := make([]byte, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' {
			c -= 0x20
		}
		b[i] = c
	}
	return string(b)
}

// =============================================================================
// Table Construction
// =============================================================================

// buildTBLMasks builds the Direct TBL lookup tables for 1-8 patterns.
// Uses inverted logic: 0 bit = pattern might match, 1 bit = definitely doesn't match.
func (bs *BooleanSearch) buildTBLMasks() {
	// Initialize all bits to 1 (no patterns can match)
	for i := range bs.tbl.masksLo {
		bs.tbl.masksLo[i] = 0xFF
		bs.tbl.masksHi[i] = 0xFF
	}

	// For each pattern, clear the bit for nibbles that could match
	for _, p := range bs.patterns {
		if len(p.Text) == 0 {
			continue
		}

		// Use first byte of pattern for filtering
		c := p.Text[0]
		patBit := uint8(1 << p.ID)

		if p.CaseSensitive {
			// Only exact match
			loNib := c & 0x0F
			hiNib := c >> 4
			bs.tbl.masksLo[loNib] &^= patBit
			bs.tbl.masksHi[hiNib] &^= patBit
		} else {
			// Case-insensitive: handle both cases for letters
			if isAlpha(c) {
				upper := c &^ 0x20
				lower := c | 0x20

				// Upper case nibbles
				bs.tbl.masksLo[upper&0x0F] &^= patBit
				bs.tbl.masksHi[upper>>4] &^= patBit

				// Lower case nibbles
				bs.tbl.masksLo[lower&0x0F] &^= patBit
				bs.tbl.masksHi[lower>>4] &^= patBit
			} else {
				// Non-letter: exact nibbles only
				loNib := c & 0x0F
				hiNib := c >> 4
				bs.tbl.masksLo[loNib] &^= patBit
				bs.tbl.masksHi[hiNib] &^= patBit
			}
		}
	}
}

// buildFDRTables builds the FDR hash table for 9-64 patterns.
func (bs *BooleanSearch) buildFDRTables() {
	// Determine domain size based on pattern count
	// More patterns → larger domain to reduce collisions
	switch {
	case bs.numPatterns <= 16:
		bs.fdr.domain = 10 // 1024 entries
	case bs.numPatterns <= 32:
		bs.fdr.domain = 11 // 2048 entries
	case bs.numPatterns <= 48:
		bs.fdr.domain = 12 // 4096 entries
	default:
		bs.fdr.domain = 13 // 8192 entries
	}

	bs.fdr.domainMask = (1 << bs.fdr.domain) - 1
	tableSize := 1 << bs.fdr.domain
	bs.fdr.stateTable = make([]uint64, tableSize)

	// Initialize all entries to "all patterns might match" (0 bits)
	// Inverted logic: 0 = might match, 1 = definitely doesn't match
	for i := range bs.fdr.stateTable {
		bs.fdr.stateTable[i] = ^uint64(0) // All 1s = no patterns match
	}

	// Calculate stride based on minimum pattern length
	switch {
	case bs.minPatternLen >= 4:
		bs.fdr.stride = 4
	case bs.minPatternLen >= 2:
		bs.fdr.stride = 2
	default:
		bs.fdr.stride = 1
	}

	// For each pattern, populate the hash table
	for _, p := range bs.patterns {
		if len(p.Text) == 0 {
			continue
		}

		patBit := uint64(1) << p.ID

		// Generate all hash values this pattern could match
		// For short patterns (< 4 bytes), we need to handle don't-care bytes
		bs.populateFDRPattern(p, patBit)
	}

	// Build coarse TBL prefilter tables for NEON fast path
	bs.buildFDRCoarseTables()
}

// buildFDRCoarseTables builds the TBL prefilter tables for FDR.
// Patterns are partitioned into 8 groups based on first byte characteristics.
// The TBL lookup gives a quick candidate filter before doing expensive hash lookups.
func (bs *BooleanSearch) buildFDRCoarseTables() {
	// Initialize coarse tables to all 1s (no groups can match)
	// Inverted logic: 0 bit = group might match, 1 bit = definitely doesn't match
	for i := range bs.fdr.coarseLo {
		bs.fdr.coarseLo[i] = 0xFF
		bs.fdr.coarseHi[i] = 0xFF
	}

	// Initialize group masks
	for i := range bs.fdr.groupMasks {
		bs.fdr.groupMasks[i] = 0
	}

	// Assign patterns to groups using round-robin based on pattern ID
	// This gives reasonable distribution. Alternative: group by first byte rarity.
	for _, p := range bs.patterns {
		if len(p.Text) == 0 {
			continue
		}

		groupID := p.ID % 8 // Simple round-robin assignment
		groupBit := uint8(1 << groupID)
		patBit := uint64(1) << p.ID

		// Add pattern to its group
		bs.fdr.groupMasks[groupID] |= patBit

		// Update coarse TBL tables based on first byte
		c := p.Text[0]

		if p.CaseSensitive {
			// Only exact match
			loNib := c & 0x0F
			hiNib := c >> 4
			bs.fdr.coarseLo[loNib] &^= groupBit
			bs.fdr.coarseHi[hiNib] &^= groupBit
		} else {
			// Case-insensitive: handle both cases for letters
			if isAlpha(c) {
				upper := c &^ 0x20
				lower := c | 0x20

				// Upper case nibbles
				bs.fdr.coarseLo[upper&0x0F] &^= groupBit
				bs.fdr.coarseHi[upper>>4] &^= groupBit

				// Lower case nibbles
				bs.fdr.coarseLo[lower&0x0F] &^= groupBit
				bs.fdr.coarseHi[lower>>4] &^= groupBit
			} else {
				// Non-letter: exact nibbles only
				loNib := c & 0x0F
				hiNib := c >> 4
				bs.fdr.coarseLo[loNib] &^= groupBit
				bs.fdr.coarseHi[hiNib] &^= groupBit
			}
		}
	}

	// Build groupLUT: 256-entry table mapping 8-bit group mask → 64-bit pattern mask
	// This replaces 8 conditional branches with a single table lookup
	for groupMask := 0; groupMask < 256; groupMask++ {
		var patternMask uint64
		for g := 0; g < 8; g++ {
			if groupMask&(1<<g) != 0 {
				patternMask |= bs.fdr.groupMasks[g]
			}
		}
		bs.fdr.groupLUT[groupMask] = patternMask
	}
}

// populateFDRPattern populates the FDR hash table for a single pattern.
func (bs *BooleanSearch) populateFDRPattern(p Pattern, patBit uint64) {
	text := p.Text
	length := len(text)

	// Get the first 4 bytes (or fewer for short patterns)
	var hashBytes [4]byte
	var dontCareMask [4]bool

	for i := 0; i < 4; i++ {
		if i < length {
			c := text[i]
			if !p.CaseSensitive && isAlpha(c) {
				// For case-insensitive alpha, we need to expand both cases
				hashBytes[i] = c &^ 0x20 // uppercase
				dontCareMask[i] = true   // has case variant
			} else {
				hashBytes[i] = c
				dontCareMask[i] = false
			}
		} else {
			// Pattern shorter than 4 bytes - this position is don't-care
			hashBytes[i] = 0
			dontCareMask[i] = true
		}
	}

	// Expand all combinations of don't-care positions
	bs.expandFDRHash(hashBytes, dontCareMask, 0, patBit)
}

// expandFDRHash recursively expands all hash combinations for don't-care positions.
func (bs *BooleanSearch) expandFDRHash(hashBytes [4]byte, dontCare [4]bool, pos int, patBit uint64) {
	if pos == 4 {
		// All positions processed, compute hash and clear the pattern bit
		hash := uint32(hashBytes[0]) |
			(uint32(hashBytes[1]) << 8) |
			(uint32(hashBytes[2]) << 16) |
			(uint32(hashBytes[3]) << 24)
		hash &= bs.fdr.domainMask
		bs.fdr.stateTable[hash] &^= patBit // Clear bit = pattern might match
		return
	}

	if !dontCare[pos] {
		// Not a don't-care position, recurse with current value
		bs.expandFDRHash(hashBytes, dontCare, pos+1, patBit)
	} else {
		// Don't-care position: try all 256 values
		// (For case-insensitive letters, we only need upper and lower)
		c := hashBytes[pos]
		if isAlpha(c) {
			// Try both cases
			hashBytes[pos] = c &^ 0x20 // uppercase
			bs.expandFDRHash(hashBytes, dontCare, pos+1, patBit)
			hashBytes[pos] = c | 0x20 // lowercase
			bs.expandFDRHash(hashBytes, dontCare, pos+1, patBit)
		} else if c == 0 && pos > 0 {
			// Short pattern don't-care: try all 256 values
			// This is expensive but necessary for correctness
			for v := 0; v < 256; v++ {
				hashBytes[pos] = byte(v)
				bs.expandFDRHash(hashBytes, dontCare, pos+1, patBit)
			}
		} else {
			bs.expandFDRHash(hashBytes, dontCare, pos+1, patBit)
		}
	}
}

// buildVerifyTables builds the verification lookup tables.
func (bs *BooleanSearch) buildVerifyTables() {
	for _, p := range bs.patterns {
		id := p.ID
		bs.verify.lengths[id] = uint8(len(p.Text))
		bs.verify.ptrs[id] = p.normText

		if len(p.Text) == 0 {
			continue
		}

		// Build the first 8 bytes as uint64 with case-fold applied
		var value, mask uint64
		for i := 0; i < 8 && i < len(p.Text); i++ {
			c := p.Text[i]
			var v, m byte

			if p.CaseSensitive {
				v = c
				m = 0xFF
			} else if isAlpha(c) {
				v = c &^ 0x20  // uppercase
				m = 0xFF ^ 0x20 // mask out bit 5
			} else {
				v = c
				m = 0xFF
			}

			value |= uint64(v) << (i * 8)
			mask |= uint64(m) << (i * 8)
		}

		bs.verify.values[id] = value
		bs.verify.masks[id] = mask
	}
}

// buildFloodTable builds the flood detection table.
func (bs *BooleanSearch) buildFloodTable() {
	// For each byte value, determine which patterns could match a flood
	for c := 0; c < 256; c++ {
		for _, p := range bs.patterns {
			if bs.patternMatchesFlood(p, byte(c)) {
				bs.flood[c].patternIDs = append(bs.flood[c].patternIDs, p.ID)
				if bs.flood[c].minLength == 0 || uint8(p.Length) < bs.flood[c].minLength {
					bs.flood[c].minLength = uint8(p.Length)
				}
			}
		}
	}
}

// patternMatchesFlood checks if a pattern would match a flood of the given byte.
func (bs *BooleanSearch) patternMatchesFlood(p Pattern, floodChar byte) bool {
	for i := 0; i < len(p.Text); i++ {
		c := p.Text[i]
		if p.CaseSensitive {
			if c != floodChar {
				return false
			}
		} else {
			// Case-insensitive comparison
			if !equalFoldByte(c, floodChar) {
				return false
			}
		}
	}
	return true
}

// equalFoldByte checks if two bytes are equal case-insensitively.
func equalFoldByte(a, b byte) bool {
	if a == b {
		return true
	}
	if isAlpha(a) && isAlpha(b) {
		return (a &^ 0x20) == (b &^ 0x20)
	}
	return false
}

// computeImmediateMasks computes the immediate true/false masks for early termination.
func (bs *BooleanSearch) computeImmediateMasks() {
	// For each pattern, test if finding it alone makes the expression definitively TRUE or FALSE
	// Key insight: we use final=false to check if the result is determined without knowing other patterns
	for _, p := range bs.patterns {
		mask := uint64(1) << p.ID

		// Test if this pattern alone makes expression TRUE (without assuming others are absent)
		// Example: A OR B → finding A alone gives TRUE
		if bs.expr.Evaluate(mask, false) == TRUE {
			bs.immediateTrueMask |= mask
		}

		// Test if this pattern alone makes expression FALSE (without assuming others are absent)
		// Example: NOT(A) → finding A alone gives FALSE
		// But for A AND B → finding A alone gives UNKNOWN (B might still be found)
		if bs.expr.Evaluate(mask, false) == FALSE {
			bs.immediateFalseMask |= mask
		}
	}
}

// isAlpha returns true if the byte is an ASCII letter.
func isAlpha(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}

// =============================================================================
// Runtime Search
// =============================================================================

// Match returns true if the haystack matches the boolean expression.
func (bs *BooleanSearch) Match(haystack string) bool {
	if bs.numPatterns == 0 {
		return false
	}

	var foundMask uint64

	// Check for flood first (adversarial input protection)
	if len(haystack) >= 64 {
		foundMask = bs.checkFlood(haystack)
		if bs.checkEarlyTermination(foundMask) {
			return bs.expr.Evaluate(foundMask, true) == TRUE
		}
	}

	// Run the appropriate engine
	if bs.useFDR {
		foundMask = bs.searchFDR(haystack, foundMask)
	} else {
		foundMask = bs.searchTBL(haystack, foundMask)
	}

	// Final evaluation
	return bs.expr.Evaluate(foundMask, true) == TRUE
}

// checkEarlyTermination returns true if we can terminate early.
func (bs *BooleanSearch) checkEarlyTermination(foundMask uint64) bool {
	if foundMask&bs.immediateTrueMask != 0 {
		return true
	}
	if foundMask&bs.immediateFalseMask != 0 {
		return true
	}
	return false
}

// checkFlood performs flood detection on the haystack.
func (bs *BooleanSearch) checkFlood(haystack string) uint64 {
	var foundMask uint64
	n := len(haystack)

	// Quick 3-region sampling
	samples := [3]int{0, n / 2, n - 1}
	for _, pos := range samples {
		if pos < 0 || pos >= n {
			continue
		}
		c := haystack[pos]

		// Check if this byte value could indicate a flood
		entry := &bs.flood[c]
		if len(entry.patternIDs) == 0 {
			continue
		}

		// Verify it's actually a flood by checking neighbors
		floodLen := 1
		for i := pos + 1; i < n && haystack[i] == c && floodLen < 256; i++ {
			floodLen++
		}
		for i := pos - 1; i >= 0 && haystack[i] == c && floodLen < 256; i-- {
			floodLen++
		}

		if floodLen >= int(entry.minLength) {
			// Mark all patterns that match this flood as found
			for _, pid := range entry.patternIDs {
				if int(bs.verify.lengths[pid]) <= floodLen {
					foundMask |= 1 << pid
				}
			}
		}
	}

	return foundMask
}

// searchTBL uses the Direct TBL engine for 1-8 patterns.
// On ARM64 with NEON, this calls the optimized assembly implementation.
func (bs *BooleanSearch) searchTBL(haystack string, foundMask uint64) uint64 {
	// NEON version handles all pattern lengths with long verification
	return bs.searchTBLNEON(haystack, foundMask)
}

// searchTBLNEON uses the NEON-accelerated TBL engine.
// This is called by searchTBL on ARM64 when NEON is available.
func (bs *BooleanSearch) searchTBLNEON(haystack string, foundMask uint64) uint64 {
	return searchTBL_NEON(
		haystack,
		&bs.tbl.masksLo,
		&bs.tbl.masksHi,
		&bs.verify.values,
		&bs.verify.masks,
		&bs.verify.lengths,
		&bs.verify.ptrs,
		bs.numPatterns,
		bs.minPatternLen,
		bs.immediateTrueMask,
		bs.immediateFalseMask,
		foundMask,
	)
}

// searchTBLGo is the pure Go implementation of the TBL engine.
func (bs *BooleanSearch) searchTBLGo(haystack string, foundMask uint64) uint64 {
	n := len(haystack)
	if n == 0 {
		return foundMask
	}

	// Need all patterns found mask for early termination check
	allPatterns := uint64((1 << bs.numPatterns) - 1)

	for pos := 0; pos <= n-bs.minPatternLen; pos++ {
		c := haystack[pos]
		loNib := c & 0x0F
		hiNib := c >> 4

		// Combined lookup: patterns that might match this position
		// Inverted logic: OR the masks, invert result
		candidates := ^(bs.tbl.masksLo[loNib] | bs.tbl.masksHi[hiNib])
		candidates &^= uint8(foundMask) // Remove already-found patterns

		if candidates == 0 {
			continue
		}

		// Verify each candidate
		for candidates != 0 {
			pid := uint8(bits.TrailingZeros8(candidates))
			candidates &^= 1 << pid

			if bs.verifyPattern(haystack, pos, pid) {
				foundMask |= 1 << pid

				// Check for early termination
				if foundMask&bs.immediateTrueMask != 0 {
					return foundMask
				}
				if foundMask&bs.immediateFalseMask != 0 {
					return foundMask
				}
			}
		}

		// Check if all patterns found
		if foundMask == allPatterns {
			return foundMask
		}
	}

	return foundMask
}

// searchFDR uses the FDR engine for 9-64 patterns.
func (bs *BooleanSearch) searchFDR(haystack string, foundMask uint64) uint64 {
	n := len(haystack)
	if n < 4 {
		// Fall back to Go for very short haystacks
		return bs.searchFDRGo(haystack, foundMask)
	}

	// Use NEON implementation with TBL prefilter + FDR confirmation
	return searchFDR_NEON(
		haystack,
		&bs.fdr.stateTable[0],
		bs.fdr.domainMask,
		bs.fdr.stride,
		&bs.fdr.coarseLo,
		&bs.fdr.coarseHi,
		&bs.fdr.groupLUT,
		&bs.verify.values,
		&bs.verify.masks,
		&bs.verify.lengths,
		&bs.verify.ptrs,
		bs.numPatterns,
		bs.minPatternLen,
		bs.immediateTrueMask,
		bs.immediateFalseMask,
		foundMask,
	)
}

// searchFDRGo is the pure Go implementation of the FDR engine.
func (bs *BooleanSearch) searchFDRGo(haystack string, foundMask uint64) uint64 {
	n := len(haystack)
	if n < 4 {
		// Very short haystack - scan each position
		for pos := 0; pos <= n-bs.minPatternLen; pos++ {
			for _, p := range bs.patterns {
				if foundMask&(1<<p.ID) != 0 {
					continue
				}
				if bs.verifyPattern(haystack, pos, p.ID) {
					foundMask |= 1 << p.ID
					if bs.checkEarlyTermination(foundMask) {
						return foundMask
					}
				}
			}
		}
		return foundMask
	}

	stride := bs.fdr.stride
	allPatterns := uint64((1 << bs.numPatterns) - 1)
	hayPtr := unsafe.Pointer(unsafe.StringData(haystack))

	for pos := 0; pos <= n-4; pos += stride {
		// Hash: load 4 bytes, mask to domain
		hash := *(*uint32)(unsafe.Pointer(uintptr(hayPtr) + uintptr(pos))) & bs.fdr.domainMask

		// Lookup: get 64-bit pattern mask
		// Inverted logic: invert to get candidates (1 = might match)
		candidates := ^bs.fdr.stateTable[hash]
		candidates &^= foundMask // Remove already-found patterns

		if candidates == 0 {
			continue
		}

		// Verify each candidate
		for candidates != 0 {
			pid := uint8(bits.TrailingZeros64(candidates))
			candidates &^= 1 << pid

			if bs.verifyPattern(haystack, pos, pid) {
				foundMask |= 1 << pid

				// Check for early termination
				if foundMask&bs.immediateTrueMask != 0 {
					return foundMask
				}
				if foundMask&bs.immediateFalseMask != 0 {
					return foundMask
				}
			}
		}

		// Check if all patterns found
		if foundMask == allPatterns {
			return foundMask
		}
	}

	// Handle tail (last 3 bytes that weren't covered by stride)
	for pos := ((n - 4) / stride) * stride; pos <= n-bs.minPatternLen; pos++ {
		for _, p := range bs.patterns {
			if foundMask&(1<<p.ID) != 0 {
				continue // Already found
			}
			if bs.verifyPattern(haystack, pos, p.ID) {
				foundMask |= 1 << p.ID
				if bs.checkEarlyTermination(foundMask) {
					return foundMask
				}
			}
		}
	}

	return foundMask
}

// verifyPattern verifies if pattern pid matches at position pos in haystack.
func (bs *BooleanSearch) verifyPattern(haystack string, pos int, pid uint8) bool {
	length := int(bs.verify.lengths[pid])
	if pos+length > len(haystack) {
		return false
	}

	hayPtr := unsafe.Pointer(unsafe.StringData(haystack))

	// Quick 8-byte masked comparison for short patterns
	if length <= 8 {
		hay := *(*uint64)(unsafe.Pointer(uintptr(hayPtr) + uintptr(pos)))
		return (hay & bs.verify.masks[pid]) == bs.verify.values[pid]
	}

	// First 8 bytes
	hay := *(*uint64)(unsafe.Pointer(uintptr(hayPtr) + uintptr(pos)))
	if (hay & bs.verify.masks[pid]) != bs.verify.values[pid] {
		return false
	}

	// Remaining bytes (full pattern comparison)
	pattern := bs.verify.ptrs[pid]
	for i := 8; i < length; i++ {
		h := haystack[pos+i]
		p := pattern[i]
		// Case-insensitive comparison (pattern is uppercase)
		if h != p {
			hu := h
			if hu >= 'a' && hu <= 'z' {
				hu -= 0x20
			}
			if hu != p {
				return false
			}
		}
	}

	return true
}
