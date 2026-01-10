# Multi-Needle Boolean Substring Search: Design Document

This document describes the design for a SIMD-accelerated multi-needle boolean substring search algorithm for ARM NEON. The algorithm supports arbitrary boolean expressions (AND, OR, NOT) over multiple patterns with mixed case sensitivity, processed in a single pass over the haystack.

---

## Table of Contents

1. [Goals and Requirements](#1-goals-and-requirements)
2. [Algorithm Overview](#2-algorithm-overview)
3. [Data Structures](#3-data-structures)
4. [Preprocessing Phase](#4-preprocessing-phase)
5. [Runtime Search Algorithm](#5-runtime-search-algorithm)
6. [Expression Evaluation Model](#6-expression-evaluation-model)
7. [NEON Implementation Details](#7-neon-implementation-details)
8. [Performance Characteristics](#8-performance-characteristics)
9. [Edge Cases and Guards](#9-edge-cases-and-guards)
10. [References](#10-references)

---

## 1. Goals and Requirements

### Primary Goals

- **One-pass search**: Process the haystack exactly once, regardless of expression complexity
- **Boolean expressions**: Support AND, OR, NOT, and arbitrary nesting
- **Mixed case sensitivity**: Some patterns case-sensitive, others case-insensitive
- **Early termination**: Exit as soon as the expression result is determined
- **High throughput**: Target 20-35 GB/s on ARM, comparable to single-needle search

### Requirements

- Support up to 64 patterns (limited by uint64 bitmask)
- Pattern lengths from 1 byte to 255 bytes
- Handle case-insensitive matching without runtime case folding
- Leverage ARM NEON for vectorized processing

### Non-Goals (v1)

- Patterns longer than 255 bytes
- More than 64 patterns
- Match position reporting (only need existence for boolean evaluation)

---

## 2. Algorithm Overview

### Engine Selection

The design uses two engines based on pattern count:

| Patterns | Engine | Rationale |
|----------|--------|-----------|
| 1-8 | **Direct TBL** | 8-bit pattern mask fits in single TBL byte result |
| 9-64 | **FDR** | 64-bit pattern mask from hash table, O(1) lookup |

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    BOOLEAN MULTI-NEEDLE SEARCH PIPELINE                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PREPROCESSING (MakeBooleanSearch)                                          │
│  ─────────────────────────────────                                          │
│  1. Parse expression → extract patterns, assign IDs 0..N-1                  │
│  2. Select engine: Direct TBL (≤8) or FDR (9-64)                           │
│  3. Build pattern tables with don't-care expansion:                         │
│     • Case-insensitive: set don't-care on bit 5 for alpha chars            │
│     • Short patterns: set don't-care on missing positions                   │
│  4. Compute stride based on minimum pattern length                          │
│  5. Build flood table for adversarial input protection                      │
│  6. Compute immediateTrueMask, immediateFalseMask for early termination     │
│                                                                             │
│  RUNTIME SEARCH                                                             │
│  ──────────────                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         FLOOD DETECTION                             │   │
│  │  Quick 3-region sampling for repetitive sequences ("AAAA...")       │   │
│  │  If detected: process flood patterns, update foundMask              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         MAIN SCAN LOOP                              │   │
│  │                                                                      │   │
│  │  Direct TBL (1-8 patterns):                                         │   │
│  │    For each 16-byte chunk:                                          │   │
│  │      TBL(lo_nibble) & TBL(hi_nibble) → 8-bit pattern candidates     │   │
│  │      For each candidate bit: verify pattern, update foundMask       │   │
│  │                                                                      │   │
│  │  FDR (9-64 patterns):                                               │   │
│  │    For each position (with stride):                                 │   │
│  │      hash = load_u32(ptr) & domainMask                              │   │
│  │      candidates = stateTable[hash]  (64-bit pattern mask)           │   │
│  │      For each candidate bit: verify pattern, update foundMask       │   │
│  │                                                                      │   │
│  │  After each pattern found:                                          │   │
│  │    Check immediateTrueMask → early exit TRUE                        │   │
│  │    Check immediateFalseMask → early exit FALSE                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      EXPRESSION EVALUATION                          │   │
│  │  expr.Evaluate(foundMask, final=true) → TRUE / FALSE                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Two-engine design | TBL limited to 8-bit results; FDR scales to 64 patterns |
| Don't-care table expansion | Handles case-insensitivity and short patterns at compile time, not runtime |
| Single table pass | Case handled via don't-care bits, not separate CI/CS tables |
| Stride optimization | Skip positions when min_pattern_length > 1, reduces work 2-4x |
| Flood detection | Protects against adversarial inputs like "AAAA..." |
| `foundMask` monotone increasing | Simplifies three-valued boolean logic |

---

## 3. Data Structures

### BooleanSearch (Go struct)

```go
type BooleanSearch struct {
    // === Expression ===
    expr               BoolExpr  // The boolean expression tree
    immediateTrueMask  uint64    // Finding any of these → TRUE
    immediateFalseMask uint64    // Finding any of these → FALSE
    
    // === Patterns ===
    patterns      []Pattern   // Pattern metadata
    numPatterns   int
    minPatternLen int         // For stride calculation
    
    // === Engine Selection ===
    useFDR        bool        // true for 9-64 patterns
    
    // === Direct TBL Engine (1-8 patterns) ===
    tbl struct {
        // TBL masks: nibble → 8-bit pattern mask
        // Don't-care bits already expanded for CI and short patterns
        masksLo  [16]uint8    // masksLo[lo_nibble] = pattern bits
        masksHi  [16]uint8    // masksHi[hi_nibble] = pattern bits
    }
    
    // === FDR Engine (9-64 patterns) ===
    fdr struct {
        domain      int       // 9-15 bits
        domainMask  uint32    // (1 << domain) - 1
        stride      int       // 1, 2, or 4
        stateTable  []uint64  // 2^domain entries, each is 64-bit pattern mask
    }
    
    // === Verification ===
    verify struct {
        // For each pattern: value and mask for quick 8-byte comparison
        // Mask has 0 bits where don't-care (case-insensitive alpha)
        values  [64]uint64
        masks   [64]uint64
        lengths [64]uint8
        ptrs    [64]string    // Full pattern for long verification
    }
    
    // === Flood Detection ===
    flood FloodTable
    
    // === Runtime State (reset per search) ===
    foundMask     uint64
}

type Pattern struct {
    ID            uint8
    Text          string
    Length        int
    CaseSensitive bool
}

type FloodTable struct {
    // For each byte value, which patterns could match a flood of that byte
    // and what's the minimum flood length needed
    patterns   [256][]uint8   // patterns[c] = pattern IDs that match flood of c
    minLengths [256]uint8     // minimum flood length to match
}
```

### Expression Tree

```go
type Result int8
const (
    UNKNOWN Result = iota
    TRUE
    FALSE
)

type BoolExpr interface {
    Evaluate(foundMask uint64, final bool) Result
}

type ContainsExpr struct { patternID uint8 }
type AndExpr struct { left, right BoolExpr }
type OrExpr  struct { left, right BoolExpr }
type NotExpr struct { child BoolExpr }
```

---

## 4. Preprocessing Phase

### 4.1 Expression Parsing and Pattern Extraction

```go
func MakeBooleanSearch(expr BoolExpr) *BooleanSearch {
    bs := &BooleanSearch{}
    
    // Extract patterns from expression tree
    bs.patterns = extractPatterns(expr)
    bs.numPatterns = len(bs.patterns)
    bs.minPatternLen = minLength(bs.patterns)
    bs.expr = expr
    
    // Select engine
    bs.useFDR = bs.numPatterns > 8
    
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
```

### 4.2 Don't-Care Expansion for Case-Insensitivity

Case-insensitive matching is handled at table construction time by setting "don't-care" on bit 5 (the ASCII case bit, 0x20) for alphabetic characters:

```go
func (bs *BooleanSearch) expandDontCare(c byte, caseSensitive bool) (value, dontCare byte) {
    if !caseSensitive && isAlpha(c) {
        // Clear bit 5 in value, set bit 5 in don't-care
        return c & 0xDF, 0x20
    }
    return c, 0x00
}
```

When building tables, for each don't-care bit pattern, we generate entries for ALL combinations:

```go
// For a byte with dontCare mask, generate all matching values
func expandDontCareCombinations(value, dontCare byte) []byte {
    if dontCare == 0 {
        return []byte{value}
    }
    
    var result []byte
    // Iterate through all combinations of don't-care bits
    dc := dontCare
    v := ^dc
    for {
        combo := (value & ^dontCare) | (v & dontCare)
        result = append(result, combo)
        if v == ^dc { break }
        v = (v + (dc & -dc)) | ^dc
    }
    return result
}
```

### 4.3 Don't-Care Expansion for Short Patterns

Patterns shorter than the hash/mask width use don't-care for missing positions:

```go
// For FDR with 2-byte hash, 1-byte pattern "A" sets don't-care on byte 1
func (bs *BooleanSearch) getHashEntry(pattern Pattern, pos int) (value, dontCare uint32) {
    // Load up to 4 bytes from pattern end
    for i := 0; i < 4; i++ {
        patternPos := pattern.Length - 1 - pos - i
        if patternPos < 0 {
            // Position beyond pattern start - don't care
            dontCare |= 0xFF << (i * 8)
        } else {
            c := pattern.Text[patternPos]
            v, dc := bs.expandDontCare(c, pattern.CaseSensitive)
            value |= uint32(v) << (i * 8)
            dontCare |= uint32(dc) << (i * 8)
        }
    }
    // Mask to domain
    value &= bs.fdr.domainMask
    dontCare &= bs.fdr.domainMask
    return
}
```

### 4.4 Direct TBL Table Construction (1-8 patterns)

```go
func (bs *BooleanSearch) buildTBLMasks() {
    // Initialize to "no patterns match"
    for i := range bs.tbl.masksLo {
        bs.tbl.masksLo[i] = 0xFF  // All bits set = no match
        bs.tbl.masksHi[i] = 0xFF
    }
    
    for _, p := range bs.patterns {
        // Use first byte for filtering (position 0)
        c := p.Text[0]
        value, dontCare := bs.expandDontCare(c, p.CaseSensitive)
        
        // Expand don't-care to all matching nibble combinations
        for _, expanded := range expandDontCareCombinations(value, dontCare) {
            lo := expanded & 0x0F
            hi := expanded >> 4
            
            // Clear this pattern's bit (0 = might match)
            bs.tbl.masksLo[lo] &^= (1 << p.ID)
            bs.tbl.masksHi[hi] &^= (1 << p.ID)
        }
    }
}
```

### 4.5 FDR Table Construction (9-64 patterns)

```go
func (bs *BooleanSearch) buildFDRTables() {
    // Select domain based on pattern count
    bs.fdr.domain = selectDomain(bs.numPatterns)  // 9-15 bits
    bs.fdr.domainMask = (1 << bs.fdr.domain) - 1
    bs.fdr.stride = selectStride(bs.minPatternLen)
    
    tableSize := 1 << bs.fdr.domain
    bs.fdr.stateTable = make([]uint64, tableSize)
    
    // Initialize to "no patterns match" (all bits set)
    for i := range bs.fdr.stateTable {
        bs.fdr.stateTable[i] = ^uint64(0)
    }
    
    // For each pattern, set its bit in all matching hash entries
    for _, p := range bs.patterns {
        value, dontCare := bs.getHashEntry(p, 0)
        
        // Generate all combinations of don't-care bits
        for _, hashVal := range expandDontCareCombinations32(value, dontCare) {
            // Clear this pattern's bit (0 = might match)
            bs.fdr.stateTable[hashVal] &^= (1 << p.ID)
        }
    }
}

func selectDomain(numPatterns int) int {
    // More patterns → larger domain for fewer false positives
    switch {
    case numPatterns <= 16:  return 10  // 1K entries
    case numPatterns <= 32:  return 11  // 2K entries
    case numPatterns <= 48:  return 12  // 4K entries
    default:                 return 13  // 8K entries
    }
}

func selectStride(minLen int) int {
    // Stride must be ≤ minimum pattern length
    switch {
    case minLen >= 4: return 4
    case minLen >= 2: return 2
    default:          return 1
    }
}
```

### 4.6 Verification Table Construction

For quick pattern verification using masked 8-byte comparison:

```go
func (bs *BooleanSearch) buildVerifyTables() {
    for _, p := range bs.patterns {
        // Build 8-byte value and mask for first 8 bytes
        var value, mask uint64
        for i := 0; i < 8 && i < p.Length; i++ {
            c := p.Text[i]
            v, dc := bs.expandDontCare(c, p.CaseSensitive)
            value |= uint64(v) << (i * 8)
            mask |= uint64(^dc) << (i * 8)  // Mask is inverse of don't-care
        }
        
        bs.verify.values[p.ID] = value
        bs.verify.masks[p.ID] = mask
        bs.verify.lengths[p.ID] = uint8(p.Length)
        bs.verify.ptrs[p.ID] = p.Text
    }
}
```

### 4.7 Flood Table Construction

```go
func (bs *BooleanSearch) buildFloodTable() {
    for _, p := range bs.patterns {
        // Check if pattern is a repeated single character
        c := p.Text[p.Length-1]
        isFlood := true
        for i := 0; i < p.Length; i++ {
            pc := p.Text[i]
            if p.CaseSensitive {
                if pc != c { isFlood = false; break }
            } else {
                if toUpper(pc) != toUpper(c) { isFlood = false; break }
            }
        }
        
        if isFlood {
            fc := c
            if !p.CaseSensitive { fc = toUpper(c) }
            bs.flood.patterns[fc] = append(bs.flood.patterns[fc], p.ID)
            if bs.flood.minLengths[fc] == 0 || uint8(p.Length) < bs.flood.minLengths[fc] {
                bs.flood.minLengths[fc] = uint8(p.Length)
            }
            // For case-insensitive, also add lowercase
            if !p.CaseSensitive && isAlpha(c) {
                lc := toLower(c)
                bs.flood.patterns[lc] = append(bs.flood.patterns[lc], p.ID)
                if bs.flood.minLengths[lc] == 0 || uint8(p.Length) < bs.flood.minLengths[lc] {
                    bs.flood.minLengths[lc] = uint8(p.Length)
                }
            }
        }
    }
}
```

### 4.8 Immediate Mask Computation

```go
func (bs *BooleanSearch) computeImmediateMasks() {
    // immediateTrueMask: patterns where finding ONE → expression TRUE
    // immediateFalseMask: patterns where finding ONE → expression FALSE
    
    for i := 0; i < bs.numPatterns; i++ {
        testMask := uint64(1) << i
        
        // Test with only this pattern found
        result := bs.expr.Evaluate(testMask, false)
        
        if result == TRUE {
            bs.immediateTrueMask |= testMask
        } else if result == FALSE {
            bs.immediateFalseMask |= testMask
        }
    }
}
```

---

## 5. Runtime Search Algorithm

### 5.1 Main Entry Point

```go
func (bs *BooleanSearch) Search(haystack string) bool {
    if len(haystack) == 0 {
        return bs.expr.Evaluate(0, true) == TRUE
    }
    
    // Reset state
    bs.foundMask = 0
    
    // Phase 1: Flood detection
    if floodChar, start, end, ok := bs.detectFlood(haystack); ok {
        if bs.processFlood(floodChar, end-start) {
            return true  // Early exit
        }
    }
    
    // Phase 2: Main scan
    var result int
    if bs.useFDR {
        result = bs.scanFDR(haystack)
    } else {
        result = bs.scanTBL(haystack)
    }
    
    if result == 1 { return true }
    if result == 0 { return false }
    
    // Phase 3: Final evaluation
    return bs.expr.Evaluate(bs.foundMask, true) == TRUE
}
```

### 5.2 Flood Detection

```go
func (bs *BooleanSearch) detectFlood(haystack string) (byte, int, int, bool) {
    if len(haystack) < 256 {
        return 0, 0, 0, false
    }
    
    // Check 3 regions: start, middle, end
    regions := []int{0, len(haystack)/2, len(haystack)-24}
    
    for _, pos := range regions {
        if pos+16 > len(haystack) { continue }
        
        // Compare 8-byte chunks
        a := *(*uint64)(unsafe.Pointer(&haystack[pos]))
        b := *(*uint64)(unsafe.Pointer(&haystack[pos+8]))
        
        if a == b {
            c := haystack[pos]
            start := bs.findFloodStart(haystack, pos, c)
            end := bs.findFloodEnd(haystack, pos+16, c)
            return c, start, end, true
        }
    }
    
    return 0, 0, 0, false
}

func (bs *BooleanSearch) processFlood(c byte, length int) bool {
    patterns := bs.flood.patterns[c]
    if len(patterns) == 0 {
        return false
    }
    
    for _, pid := range patterns {
        if int(bs.verify.lengths[pid]) <= length {
            bs.foundMask |= (1 << pid)
            
            if bs.foundMask & bs.immediateTrueMask != 0 {
                return true
            }
        }
    }
    
    return false
}
```

### 5.3 Direct TBL Scan (1-8 patterns)

```go
//go:noescape
func scanTBLNEON(
    haystack string,
    masksLo, masksHi *[16]uint8,
    verifyValues, verifyMasks *[64]uint64,
    verifyLengths *[64]uint8,
    verifyPtrs *[64]string,
    foundMask *uint64,
    immTrue, immFalse uint64,
) int  // 1=TRUE, 0=FALSE, -1=continue

func (bs *BooleanSearch) scanTBL(haystack string) int {
    return scanTBLNEON(
        haystack,
        &bs.tbl.masksLo, &bs.tbl.masksHi,
        &bs.verify.values, &bs.verify.masks,
        &bs.verify.lengths, &bs.verify.ptrs,
        &bs.foundMask,
        bs.immediateTrueMask, bs.immediateFalseMask,
    )
}
```

**NEON pseudocode for Direct TBL:**

```
scanTBL_NEON:
    V0 = load masksLo (16 bytes)
    V1 = load masksHi (16 bytes)
    
    for each 16-byte chunk:
        V2 = load haystack[i:i+16]
        
        // Extract nibbles
        V3 = V2 & 0x0F           // lo nibbles
        V4 = V2 >> 4             // hi nibbles
        
        // TBL lookup
        V5 = TBL(V0, V3)         // masksLo[lo_nibble]
        V6 = TBL(V1, V4)         // masksHi[hi_nibble]
        
        // Combine: candidates where BOTH nibbles match
        V7 = V5 | V6             // 0 bits = candidate
        V7 = NOT V7              // 1 bits = candidate
        
        // Check if any candidates
        if any_nonzero(V7):
            for each set bit position p:
                patternMask = extract_byte(V7, p)
                for each set bit b in patternMask:
                    if verify(haystack, i+p, b):
                        foundMask |= (1 << b)
                        if foundMask & immTrue: return 1
                        if foundMask & immFalse: return 0
    
    return -1
```

### 5.4 FDR Scan (9-64 patterns)

```go
//go:noescape
func scanFDRNEON(
    haystack string,
    stateTable []uint64,
    domainMask uint32,
    stride int,
    verifyValues, verifyMasks *[64]uint64,
    verifyLengths *[64]uint8,
    verifyPtrs *[64]string,
    foundMask *uint64,
    immTrue, immFalse uint64,
) int

func (bs *BooleanSearch) scanFDR(haystack string) int {
    return scanFDRNEON(
        haystack,
        bs.fdr.stateTable,
        bs.fdr.domainMask,
        bs.fdr.stride,
        &bs.verify.values, &bs.verify.masks,
        &bs.verify.lengths, &bs.verify.ptrs,
        &bs.foundMask,
        bs.immediateTrueMask, bs.immediateFalseMask,
    )
}
```

**NEON pseudocode for FDR:**

```
scanFDR_NEON:
    for i := 0; i < len(haystack)-3; i += stride:
        // Hash: load 4 bytes, mask to domain
        hash = load_u32(haystack[i:]) & domainMask
        
        // Lookup: 64-bit pattern mask
        candidates = stateTable[hash]
        candidates = NOT candidates  // 1 bits = candidate
        
        // Skip if no candidates
        if candidates == 0:
            continue
        
        // Filter out already-found patterns
        candidates &= NOT foundMask
        
        // Verify each candidate
        for each set bit b in candidates:
            if verify(haystack, i, b):
                foundMask |= (1 << b)
                if foundMask & immTrue: return 1
                if foundMask & immFalse: return 0
    
    return -1
```

### 5.5 Pattern Verification

```go
func verify(haystack string, pos int, patternID uint8, 
            values, masks *[64]uint64, lengths *[64]uint8, ptrs *[64]string) bool {
    
    length := int(lengths[patternID])
    if pos + length > len(haystack) {
        return false
    }
    
    // Quick 8-byte masked comparison
    if length <= 8 {
        hay := *(*uint64)(unsafe.Pointer(&haystack[pos]))
        return (hay & masks[patternID]) == values[patternID]
    }
    
    // First 8 bytes
    hay := *(*uint64)(unsafe.Pointer(&haystack[pos]))
    if (hay & masks[patternID]) != values[patternID] {
        return false
    }
    
    // Remaining bytes (full pattern comparison)
    pattern := ptrs[patternID]
    for i := 8; i < length; i++ {
        h := haystack[pos+i]
        p := pattern[i]
        // Case-insensitive comparison encoded in pattern (uppercase)
        if h != p && toUpper(h) != p {
            return false
        }
    }
    
    return true
}
```

---

## 6. Expression Evaluation Model

### 6.1 Three-Valued Logic

| foundMask state | final | Contains(P) result |
|-----------------|-------|-------------------|
| Bit P set | any | TRUE |
| Bit P clear | false | UNKNOWN |
| Bit P clear | true | FALSE |

### 6.2 Evaluation Rules

```go
func (e *ContainsExpr) Evaluate(found uint64, final bool) Result {
    if found & (1 << e.patternID) != 0 {
        return TRUE
    }
    if final {
        return FALSE
    }
    return UNKNOWN
}

func (e *AndExpr) Evaluate(found uint64, final bool) Result {
    l := e.left.Evaluate(found, final)
    r := e.right.Evaluate(found, final)
    
    if l == FALSE || r == FALSE { return FALSE }
    if l == TRUE && r == TRUE { return TRUE }
    return UNKNOWN
}

func (e *OrExpr) Evaluate(found uint64, final bool) Result {
    l := e.left.Evaluate(found, final)
    r := e.right.Evaluate(found, final)
    
    if l == TRUE || r == TRUE { return TRUE }
    if l == FALSE && r == FALSE { return FALSE }
    return UNKNOWN
}

func (e *NotExpr) Evaluate(found uint64, final bool) Result {
    c := e.child.Evaluate(found, final)
    
    if c == TRUE { return FALSE }
    if c == FALSE { return TRUE }
    return UNKNOWN
}
```

### 6.3 Immediate Mask Semantics

- **immediateTrueMask**: Patterns where finding that ONE pattern alone makes expression TRUE
  - Example: `A OR B OR C` → immediateTrueMask = 0b111

- **immediateFalseMask**: Patterns where finding that ONE pattern makes expression FALSE regardless of others
  - Example: `NOT(A) AND NOT(B)` → immediateFalseMask = 0b11
  - Example: `A OR NOT(B)` → immediateFalseMask = 0 (finding B doesn't make it FALSE, A might be found)

---

## 7. NEON Implementation Details

### 7.1 Direct TBL Register Layout

```asm
// Constants
V0.B16  = masksLo table (16 bytes)
V1.B16  = masksHi table (16 bytes)
V2.B16  = 0x0F broadcast (nibble mask)

// Per-chunk processing
V16.B16 = haystack chunk
V17.B16 = lo nibbles (V16 AND V2)
V18.B16 = hi nibbles (V16 >> 4)
V19.B16 = TBL(V0, V17)   // lo lookup
V20.B16 = TBL(V1, V18)   // hi lookup
V21.B16 = V19 OR V20     // combined (0 = candidate)
V22.B16 = NOT V21        // inverted (1 = candidate)
```

### 7.2 FDR Hash and Lookup

```asm
// FDR hash at position i
LDR     W10, [R_HAY, R_POS]      // Load 4 bytes
AND     W10, W10, W_DOMAIN_MASK  // Mask to domain
LSL     X10, X10, #3             // Multiply by 8 (sizeof uint64)
LDR     X11, [R_STATE_TABLE, X10] // Load 64-bit pattern mask
MVN     X11, X11                 // Invert (1 = candidate)
BIC     X11, X11, X_FOUND_MASK   // Clear already-found
CBZ     X11, next_position       // Skip if no candidates
```

### 7.3 Verification (8-byte masked comparison)

```asm
verify_8byte:
    LDR     X12, [R_HAY, R_POS]         // Load 8 haystack bytes
    LDR     X13, [R_VERIFY_VALUES, X_PID_OFFSET]  // Load pattern value
    LDR     X14, [R_VERIFY_MASKS, X_PID_OFFSET]   // Load mask
    AND     X12, X12, X14               // Apply mask
    CMP     X12, X13                    // Compare
    BNE     no_match
    // Match! Update foundMask...
```

---

## 8. Performance Characteristics

### Expected Throughput

| Scenario | Engine | Throughput | Notes |
|----------|--------|------------|-------|
| 1-4 patterns, early match | Direct TBL | 35-40 GB/s | Single TBL pass |
| 5-8 patterns | Direct TBL | 30-35 GB/s | More verification |
| 9-16 patterns | FDR | 25-30 GB/s | Hash + lookup |
| 17-64 patterns | FDR | 20-28 GB/s | More candidates |
| Adversarial ("AAAA...") | Any | 25-35 GB/s | Flood detection |

### Memory Footprint

| Engine | Pattern Count | Table Size |
|--------|---------------|------------|
| Direct TBL | 1-8 | 32 bytes |
| FDR | 9-16 | 8 KB (10-bit domain) |
| FDR | 17-32 | 16 KB (11-bit domain) |
| FDR | 33-64 | 32-64 KB (12-13 bit domain) |

---

## 9. Edge Cases and Guards

### 9.1 Empty Patterns

```go
if len(pattern) == 0 {
    return errors.New("empty pattern not allowed")
}
```

### 9.2 Single-Byte Patterns

Single-byte patterns work correctly:
- Direct TBL: nibble lookup still works
- FDR: don't-care on bytes 1-3 of hash, all matching entries set

### 9.3 Pattern Longer Than Haystack

```go
if pos + patternLen > len(haystack) {
    return false  // Can't match
}
```

### 9.4 All-Don't-Care Hash

If a pattern is so short that the entire hash is don't-care, every position is a candidate. The verification phase handles correctness.

### 9.5 NOT Semantics

```
NOT(Contains(P)):
  - Found P → FALSE (immediate)
  - Not found, scanning → UNKNOWN
  - Not found, final → TRUE
```

---

## 10. References

1. **Hyperscan FDR**: intel/hyperscan src/fdr/fdr.c, fdr_compile.cpp
2. **Hyperscan Teddy**: intel/hyperscan src/fdr/teddy.c, teddy_compile.cpp
3. **Hyperscan Confirmation**: intel/hyperscan src/fdr/fdr_confirm.h
4. **Hyperscan Flood Detection**: intel/hyperscan src/fdr/flood_runtime.h
5. **ARM NEON TBL**: ARM NEON Programmer's Guide
6. **Single-Needle Reference**: veloz ascii/ascii_neon_needle.s
