# Adaptive NEON String Search Implementation Plan

## Goal
Create an adaptive case-insensitive substring search that achieves:
- 36.5 GB/s on clean workloads (1-byte NEON fast path)
- 17 GB/s on high false-positive workloads (2-byte NEON fallback)
- Seamless inline cutover when false positives exceed threshold

## Current State
- NEON-128B (1-byte): 36.5 GB/s pure scan, 1.2 GB/s on JSON (high FP)
- Original NEON (2-byte): 17 GB/s consistent on all workloads
- Go stdlib strings.Index: 40 GB/s pure scan, 2.5 GB/s on JSON
- Bug fixes committed: syndrome S[0] extraction, R8/R24 register conflict

---

## Phase 1: Comprehensive Test Coverage

### 1.1 Needle Length Variations
Add systematic tests for needle lengths that stress different code paths:
- [ ] Length 1 (single byte)
- [ ] Length 2 (minimum for 2-byte filtering)
- [ ] Length 3 (odd, small)
- [ ] Length 4, 8 (power of 2, common)
- [ ] Length 15 (just under 16)
- [ ] Length 16 (exactly one SIMD chunk)
- [ ] Length 17 (just over 16, spans chunks)
- [ ] Length 31, 32, 33 (around 32-byte boundary)
- [ ] Length 63, 64, 65 (around 64-byte boundary)

### 1.2 Alignment Tests
Test matches at every position modulo chunk size:
- [ ] Match at positions 0-15 within first 16-byte chunk
- [ ] Match at positions 16-31 (second chunk)
- [ ] Match at positions 32-47, 48-63 (within 64-byte loop)
- [ ] Match at positions 64-79, 80-95, 96-111, 112-127 (within 128-byte loop)
- [ ] Parametric test: for each alignment 0-127, place needle there

### 1.3 Chunk Boundary Straddle Tests
Test matches that span chunk boundaries:
- [ ] Match starting at position 14, length 4 (spans 16-byte boundary)
- [ ] Match starting at position 30, length 4 (spans 32-byte boundary)
- [ ] Match starting at position 62, length 4 (spans 64-byte boundary)
- [ ] Match starting at position 126, length 4 (spans 128-byte boundary)
- [ ] Parametric: for each boundary, test match starting 1, 2, 3 bytes before

### 1.4 High False-Positive Density Tests
Test workloads with many candidates:
- [ ] JSON-like: `{"key":"value"}` repeated, needle `"num"`
- [ ] DNA-like: `ACGTACGT...` repeated, needle `GATTACA`
- [ ] Hex-like: `0123456789ABCDEF` repeated, needle `DEADBEEF`
- [ ] All same character: `aaaaaaa...a`, needle `aaa`
- [ ] Alternating: `ababab...`, needle `aba`
- [ ] Quote-heavy: many `"` characters, needle with `"`

### 1.5 Cutover-Specific Tests
Test scenarios that should trigger cutover:
- [ ] Haystack where every position matches rare1 but fails verification
- [ ] Haystack with failures at positions 0, 16, 32, 48... (one per chunk)
- [ ] Haystack with failures clustered in first 1KB then clean
- [ ] Haystack clean for 10KB then high false positives
- [ ] Edge: exactly threshold failures, then match
- [ ] Edge: threshold+1 failures, verify cutover happened

### 1.6 Rare Byte Selection Edge Cases
- [ ] Needle with all common letters: `"letter"`, `"between"`, `"state"`
- [ ] Needle with rare punctuation: `"foo::bar"`, `"a.b.c"`
- [ ] Needle where rare1 == rare2: `"::foo::"`, `"ababa"`
- [ ] Needle with only one distinct character: `"aaa"`
- [ ] Needle with high-bit bytes: `"café"`, `"\x7f\x7f"`
- [ ] Short needle (len 2-3) with common chars

### 1.7 Benchmark Coverage
- [ ] Benchmark pure scan (no matches) at 1KB, 64KB, 1MB, 16MB
- [ ] Benchmark with match at end (full scan + verify)
- [ ] Benchmark with match at start (early exit)
- [ ] Benchmark high false-positive at 2KB, 64KB, 1MB
- [ ] Benchmark cutover scenarios (measure transition overhead)
- [ ] Compare all variants: NEON, NEON-128B, NEON-Adaptive, SVE2, Go stdlib

---

## Phase 2: Frequency-Based Heuristic

### 2.1 Create Frequency Table
- [ ] Create `foldedFreq [256]uint8` table in `ascii_freq.go`
- [ ] Populate with English text frequencies (case-folded)
  - Common: e(12%), t(9%), a(8%), o(7%), i(7%), n(7%), s(6%), h(6%), r(6%)
  - Rare: z(<0.1%), q(0.1%), x(0.2%), j(0.2%)
  - Punctuation: estimate based on typical text/code
  - Non-ASCII: assume rare (1%)
- [ ] Add unit tests verifying frequency values are sensible

### 2.2 Update Algorithm Selection
- [ ] Modify `SearchNeedle` to check `foldedFreq[n.rare1]`
- [ ] If freq < threshold (e.g., 5): use adaptive function
- [ ] If freq >= threshold: use original 2-byte NEON directly
- [ ] Add tests verifying correct routing based on needle characteristics

### 2.3 Threshold Tuning
- [ ] Benchmark with thresholds 2%, 3%, 5%, 8%, 10%
- [ ] Find sweet spot that maximizes overall performance
- [ ] Document reasoning for chosen threshold

---

## Phase 3: Adaptive Assembly Implementation

### 3.1 Design Register Contract
Document exact register state at 2-byte entry point:

```
2-BYTE MODE ENTRY CONTRACT:
  R0  = haystack base pointer
  R1  = haystack length  
  R2  = rare1 byte (case-normalized)
  R3  = off1 (offset of rare1 in needle)
  R4  = rare2 byte (case-normalized)
  R5  = off2 (offset of rare2 in needle)
  R6  = needle base pointer
  R7  = needle length
  R9  = searchLen (haystack_len - needle_len)
  R10 = current search pointer
  R11 = original search pointer start
  R12 = remaining bytes to search
  R25 = failure counter (reset to 0)
  
  V0  = broadcast of rare1 mask
  V1  = broadcast of rare1 target
  V2  = broadcast of rare2 mask  
  V3  = broadcast of rare2 target
  V5  = magic constant for syndrome
```

### 3.2 Create ascii_neon_adaptive.s
- [ ] Create new file with function signature matching IndexFoldNeedle
- [ ] Implement 1-byte fast path (based on NEON-128B)
- [ ] Add failure counter increment on verification failure
- [ ] Add threshold check: `failures > 4 + (bytes_scanned >> 4)`
- [ ] On threshold exceeded: adjust registers, branch to 2-byte section
- [ ] Implement 2-byte section (based on original NEON logic)
- [ ] Single shared verification routine used by both paths
- [ ] Single return path

### 3.3 Implementation Details

#### 1-Byte Section (Fast Path)
```
loop128_1byte:
  - Load 128 bytes
  - Compare against rare1 only
  - Quick check: any matches? No → continue loop
  - For each match:
    - Verify full needle
    - If match: return position
    - If fail: increment R25 (failure counter)
    - Check: R25 > threshold? Yes → branch to setup_2byte
  - Continue to next chunk
```

#### Cutover Logic
```
setup_2byte:
  - R25 already has failure count (reset or keep?)
  - Ensure V2, V3 have rare2 mask/target (may need to compute)
  - Adjust R10, R12 to current position
  - Branch to loop_2byte
```

#### 2-Byte Section
```
loop_2byte:
  - Load chunk at off1 offset
  - Load chunk at off2 offset  
  - Compare against rare1, compare against rare2
  - AND results → candidates must match BOTH
  - For each candidate:
    - Verify full needle
    - If match: return position
  - Continue to next chunk
```

### 3.4 Testing the Adaptive Function
- [ ] Run all Phase 1 tests against adaptive function
- [ ] Add specific tests for cutover behavior
- [ ] Fuzz test comparing adaptive vs Go reference
- [ ] Verify no performance regression on clean workloads
- [ ] Verify improved performance on high-FP workloads

---

## Phase 4: Integration and Optimization

### 4.1 Wire Up Dispatcher
- [ ] Update `SearchNeedle` to use frequency heuristic + adaptive function
- [ ] Update `IndexFoldNeedle` export if needed
- [ ] Ensure SVE2 path still works for capable CPUs

### 4.2 Final Benchmarks
- [ ] Full benchmark suite on Graviton 4
- [ ] Compare against Go stdlib strings.Index
- [ ] Document performance characteristics
- [ ] Identify any remaining edge cases

### 4.3 Cleanup
- [ ] Remove unused experimental variants (NEON-64B, NEON-V2, etc.)
- [ ] Update comments and documentation
- [ ] Final code review

---

## Success Criteria
- [ ] Pure scan throughput ≥ 35 GB/s (within 15% of Go stdlib)
- [ ] High false-positive throughput ≥ 15 GB/s (6x better than Go stdlib on JSON)
- [ ] All tests passing including new edge case tests
- [ ] Fuzz tests run for 5+ minutes without failure
- [ ] No performance regressions on any existing benchmarks

---

## Notes

### Why This Approach?
1. **Frequency heuristic** catches obviously bad cases upfront (common letters like 'e', 't')
2. **Runtime cutover** catches cases where heuristic was wrong
3. **Inline cutover** avoids function call overhead and re-scanning
4. **Shared 2-byte loop** avoids code duplication

### Key Insight from Analysis
- Go stdlib achieves 40 GB/s with case-sensitive search but drops to 2.5 GB/s on high-FP
- Our 2-byte NEON achieves 17 GB/s consistently because better filtering reduces verification overhead
- The 2-byte approach is fundamentally better than Rabin-Karp for this workload

### References
- Go stdlib indexbyte_arm64.s: syndrome-based NEON with cutover to Rabin-Karp
- Go Cutover formula: `4 + n/16` failures triggers fallback
- ARM64 Go assembly register rules: R0-R15 caller-saved, R18/R28/R29 reserved
