# Adaptive Case-Insensitive Substring Search: Design Document

## Executive Summary

This document specifies an adaptive 4-state finite state machine (FSM) for case-insensitive substring search that eliminates the 80% setup cost penalty for one-shot `IndexFold` calls while maintaining high throughput for repeated `SearchNeedle` calls.

**Problem**: `selectRarePair` (O(n) rare byte selection in Go) takes 80% of benchmark time for 1KB needles, making one-shot `IndexFold` 8x slower than pure Go.

**Solution**: Start in Linear mode (origin-style SIMD compare, zero setup), adaptively transition to prefilter modes only when beneficial, compute rare bytes in assembly when needed.

---

## Table of Contents

1. [Current Implementation Analysis](#1-current-implementation-analysis)
2. [Proposed 4-State FSM](#2-proposed-4-state-fsm)
3. [Algorithm Specification](#3-algorithm-specification)
4. [Threshold Justification](#4-threshold-justification)
5. [Register Allocation Plan](#5-register-allocation-plan)
6. [Assembly Pseudocode](#6-assembly-pseudocode)
7. [API Design](#7-api-design)
8. [Bug Fixes to Incorporate](#8-bug-fixes-to-incorporate)
9. [Test Plan](#9-test-plan)
10. [Benchmark Suite Design](#10-benchmark-suite-design)
11. [Risk Analysis](#11-risk-analysis)
12. [Implementation Phases](#12-implementation-phases)

---

## 1. Current Implementation Analysis

### 1.1 Current Flow (`indexFoldNeedleNEON`)

```
┌─────────────────────────────────────────────────────────────┐
│ Go: IndexFold(haystack, needle)                              │
│   ├─ selectRarePair(needle) → rare1, off1, rare2, off2      │  ← 80% of time!
│   ├─ normalizeASCII(needle) → norm                          │
│   └─ indexFoldNeedleNEON(haystack, rare1, off1, rare2,      │
│                          off2, norm)                         │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ Assembly: 1-Byte Mode                                        │
│   • Scan haystack+off1 for rare1 matches                    │
│   • On candidate: verify full needle (first/last, then all) │
│   • On verify fail: R25++                                    │
│   • If R25 > 4 + (bytes_scanned >> 8): → 2-Byte Mode        │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│ Assembly: 2-Byte Mode                                        │
│   • BUG: Restarts from beginning (should continue)          │
│   • Load rare1 AND rare2 positions                          │
│   • AND results: position must match BOTH                   │
│   • Vectorized verification (16 bytes/iter)                 │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Current Register Usage

| Register | 1-Byte Mode | 2-Byte Mode | Notes |
|----------|-------------|-------------|-------|
| R0 | haystack ptr | haystack ptr | Preserved |
| R1 | haystack len | (clobbered) | |
| R2 | rare1 byte | (clobbered) | Reloaded from stack in 2-byte |
| R3 | off1 | off1 | Preserved |
| R4 | rare2 byte | rare2 byte | Reloaded from stack |
| R5 | off2 | off2 | Reloaded from stack |
| R6 | needle ptr | needle ptr | Preserved |
| R7 | needle len | needle len | Preserved |
| R8 | candidate ptr | candidate ptr | Temp |
| R9 | searchLen | searchLen | Preserved |
| R10 | searchPtr | searchPtr | Current position |
| R11 | searchPtr start | searchPtr start | For bytes_scanned calc |
| R12 | remaining | remaining | Bytes left to scan |
| R13 | syndrome | syndrome | Match bitmap |
| R14 | chunk offset | chunk offset | 0/16/32/48 |
| R15 | bit position | bit position | From CLZ |
| R16-R23 | temps | temps | Various |
| R25 | failure count | (unused) | Cutover threshold |
| R26 | rare1 mask | rare1 mask | 0x20 or 0x00 |
| R27 | rare1 target | rare1 target | Lowercase byte |
| V0 | rare1 mask×16 | rare1 mask×16 | |
| V1 | rare1 target×16 | rare1 target×16 | |
| V2 | (unused) | rare2 mask×16 | |
| V3 | (unused) | rare2 target×16 | |
| V4-V5 | constants | constants | |
| V6-V9 | temps | temps | OR-reduction |
| V16-V19 | haystack data | rare1 data | |
| V20-V23 | compare results | rare1 results | |
| V24-V27 | (128-byte mode) | rare2 data | |
| V28-V31 | (128-byte mode) | rare2 results | |

### 1.3 Origin/main Approach (TBL Case-Folding)

Origin uses a completely different algorithm:
- **Zero setup cost**: No rare byte selection
- **Linear scan**: Compare haystack and needle at every position
- **TBL case-folding**: 32-byte `uppercasingTable` loaded into V0-V1

```asm
// Origin's case-folding pattern:
VADD  V2.B16, V3.B16, V3.B16           // Add 0xA0 (=-96) to shift range
VTBL  V3.B16, [V0.B16, V1.B16], V5.B16 // Table lookup for case adjustment
VSUB  V5.B16, V3.B16, V3.B16           // Apply adjustment
VCMEQ V4.B16, V3.B16, V3.B16           // Compare
```

The `uppercasingTable` contains adjustment values:
```asm
DATA uppercasingTable<>+0x00(SB)/8, $0x2020202020202000  // 0x00-0x07
DATA uppercasingTable<>+0x08(SB)/8, $0x2020202020202020  // 0x08-0x0F
DATA uppercasingTable<>+0x10(SB)/8, $0x2020202020202020  // 0x10-0x17
DATA uppercasingTable<>+0x18(SB)/8, $0x0000000000202020  // 0x18-0x1F (a-z range)
```

After adding 0xA0 to bytes, lowercase letters (0x61-0x7A) become 0x01-0x1A. The table lookup returns 0x20 for these positions, which is subtracted to convert lowercase→uppercase.

### 1.4 Memchr Thresholds (Reference)

From memchr's `PrefilterState`:
```rust
const MIN_SKIPS: u32 = 50;      // Minimum attempts before evaluating
const MIN_SKIP_BYTES: u32 = 8;  // Must skip ≥8 bytes on average
const MAX_FALLBACK_RANK: usize = 250;  // Skip prefilter if rarest byte rank > 250

fn is_effective(&mut self) -> bool {
    if self.skips() < MIN_SKIPS { return true; }
    // effective if: skipped >= MIN_SKIP_BYTES * skips
    // i.e., avg_skip >= 8 bytes
    self.skipped >= MIN_SKIP_BYTES * self.skips()
}
```

---

## 2. Proposed 4-State FSM

```
┌─────────────┐
│ Linear Mode │ ← Start (origin-style, zero setup)
└──────┬──────┘
       │ partial_matches > threshold AND bytes_scanned > MIN_LINEAR_BYTES
       ▼
┌─────────────┐
│ 1-Byte Mode │ ← Compute rare1 (rarest of 3 samples: 0, n/2, n-1)
└──────┬──────┘
       │ failures > threshold AND bytes_scanned > MIN_1BYTE_BYTES
       ▼
┌─────────────┐
│ 2-Byte Mode │ ← Compute rare2 in assembly (find byte ≠ rare1)
└──────┬──────┘
       │ failures > threshold (prefilter not helping)
       ▼
┌─────────────┐
│ Inert Mode  │ ← Prefilter permanently disabled, pure linear
└─────────────┘
```

### 2.1 Key Design Decisions

1. **Monotonic forward-only transitions** (no back-transitions in v1)
2. **Minimum bytes_scanned floor** before mode transitions
3. **Needle length guards**: skip 2-byte if len(needle) < 2
4. **Fast-path for tiny haystacks**: if len < 256B, pure Linear only
5. **Shared verification routine** across all modes
6. **In-assembly rare byte selection** via O(n) scan
7. **Sentinel signaling**: `off2 == -1` signals "start in Linear mode"
8. **Continue, don't restart**: On mode transition, continue from current position

---

## 3. Algorithm Specification

### 3.1 Linear Mode

**Entry conditions**: 
- `IndexFold` one-shot call (signaled by `off2 == -1`)
- Or transition from previous mode

**Algorithm**:
```
for each position i in [0, searchLen]:
    load 16 bytes from haystack[i]
    load 16 bytes from needle
    case-fold both (using OR 0x20 trick or TBL)
    XOR and check for any non-zero byte
    if all zero:
        partial_match_count++
        verify full needle
        if match: return i
    advance by 1
    
    if partial_match_count > LINEAR_THRESHOLD and bytes_scanned > MIN_LINEAR_BYTES:
        compute rare1 = rarest of needle[0], needle[n/2], needle[n-1]
        transition to 1-Byte Mode (continue from current position)
```

**Linear mode case-folding options**:

Option A: OR 0x20 trick (current approach)
```asm
VORR  V_0x20.B16, V_hay.B16, V_hay_folded.B16   // Force lowercase
VORR  V_0x20.B16, V_needle.B16, V_ndl_folded.B16
VEOR  V_hay_folded.B16, V_ndl_folded.B16, V_diff.B16
```

Option B: TBL approach (origin)
```asm
VADD  V_0xA0.B16, V_hay.B16, V_shifted.B16
VTBL  V_shifted.B16, [V0.B16, V1.B16], V_adj.B16
VSUB  V_adj.B16, V_shifted.B16, V_folded.B16
```

**Recommendation**: Use Option A (OR 0x20) - simpler, no table load, works for ASCII.

### 3.2 1-Byte Mode

**Entry conditions**:
- `SearchNeedle` with precomputed rare bytes (signaled by `off2 >= 0`)
- Or transition from Linear mode

**Algorithm**:
```
rare1, off1 = (computed in Go or in-assembly)
searchPtr = haystack + off1

for each 64-128 byte block:
    load block from searchPtr
    case-fold and compare against rare1
    if any match:
        for each match position:
            candidate = searchPtr + match_offset - off1
            if candidate in bounds:
                verify first and last byte
                if pass: verify full needle
                if match: return candidate
                else: failure_count++
    
    if failure_count > 4 + (bytes_scanned >> 8):
        if needle_len >= 2:
            compute rare2 in assembly
            transition to 2-Byte Mode (continue from current position)
        else:
            transition to Inert Mode
```

### 3.3 2-Byte Mode

**Entry conditions**:
- Transition from 1-Byte mode with needle_len >= 2

**Algorithm**:
```
rare2, off2 = (computed in assembly: find rarest byte ≠ rare1)

for each 64 byte block:
    load rare1 positions (searchPtr)
    load rare2 positions (searchPtr - off1 + off2)
    case-fold and compare both
    AND results: position must match BOTH
    
    if any match:
        for each match position:
            vectorized verification (16 bytes at a time)
            if match: return position
            else: failure_count_2byte++
    
    if failure_count_2byte > INERT_THRESHOLD:
        transition to Inert Mode
```

### 3.4 Inert Mode

**Entry conditions**:
- 2-Byte mode prefilter still not helping
- Or needle_len == 1 and 1-Byte mode not helping

**Algorithm**:
```
// Pure linear scan, no prefilter
for each position i in [current_pos, searchLen]:
    verify full needle at position i
    if match: return i
return -1
```

### 3.5 In-Assembly Rare Byte Selection

For Linear → 1-Byte transition, we need to compute rare1 quickly:

**Simple approach (3 samples)**:
```asm
// Sample needle[0], needle[n/2], needle[n-1]
MOVBU (R6), R20              // needle[0]
LSR   $1, R7, R21
ADD   R6, R21, R21
MOVBU (R21), R21             // needle[n/2]
ADD   R6, R7, R22
SUB   $1, R22
MOVBU (R22), R22             // needle[n-1]

// Normalize to lowercase
ORR   $0x20, R20, R20
ORR   $0x20, R21, R21  
ORR   $0x20, R22, R22

// Look up ranks (need rank table in RODATA)
MOVD  $caseFoldRank<>(SB), R23
MOVHU (R23)(R20<<1), R20     // rank of byte 0
MOVHU (R23)(R21<<1), R21     // rank of byte n/2
MOVHU (R23)(R22<<1), R22     // rank of byte n-1

// Find minimum
CMP   R21, R20
CSEL  LO, R20, R21, R24      // min(r0, r_mid)
CMP   R22, R24
CSEL  LO, R24, R22, R_rare1  // rare1 = min of all three
```

For 1-Byte → 2-Byte transition, compute rare2:

**O(n) scan for different byte**:
```asm
// Find any byte in needle that differs from rare1 (normalized)
MOVD  R6, R20                // needle ptr
MOVD  R7, R21                // needle len
rare2_loop:
    CBZ   R21, rare2_fallback
    MOVBU (R20), R22
    // Normalize
    SUBW  $65, R22, R23
    CMPW  $26, R23
    BCS   not_upper
    ORRW  $0x20, R22, R22
not_upper:
    CMP   R_rare1_norm, R22
    BNE   found_rare2
    ADD   $1, R20
    SUB   $1, R21
    B     rare2_loop

found_rare2:
    // R22 = rare2, R20 - R6 = off2
    SUB   R6, R20, R_off2
    B     setup_2byte_vectors

rare2_fallback:
    // All bytes same - use position 0 and n-1
    MOVD  ZR, R_off2
    // rare2 = rare1 (will still filter somewhat)
```

---

## 4. Threshold Justification

### 4.1 Linear → 1-Byte Threshold

**Goal**: Transition when linear scan is encountering too many partial matches.

**Proposed**: `partial_matches > 8 AND bytes_scanned > 512`

**Rationale**:
- 8 partial matches means ~8 full verifications attempted
- 512 bytes minimum ensures we've amortized any transition overhead
- Partial match = first 16 bytes of needle matched (very selective)

### 4.2 1-Byte → 2-Byte Threshold

**Current**: `failures > 4 + (bytes_scanned >> 8)` (1 extra failure per 256 bytes)

**Keep current threshold** - empirically tuned, comment says:
> "The >> 8 threshold (1 failure per 256 bytes) was empirically determined to be optimal - more conservative (>>10) hurts pure scan, more aggressive (>>7) triggers unnecessary cutovers."

### 4.3 2-Byte → Inert Threshold

**Proposed**: `failures_2byte > 16 AND bytes_scanned_2byte > 1024`

**Rationale**:
- 2-byte mode should be very selective
- If we're still getting 16+ failures after 1KB, prefilter isn't helping
- Matches memchr's MIN_SKIPS=50 philosophy (need enough samples)

### 4.4 Minimum Bytes Floor

| Transition | Minimum Bytes | Rationale |
|------------|---------------|-----------|
| Linear → 1-Byte | 512 | Amortize rare1 computation |
| 1-Byte → 2-Byte | 256 | Current implicit minimum |
| 2-Byte → Inert | 1024 | Need statistical significance |

### 4.5 Small Input Fast Path

If `haystack_len < 256`: Stay in Linear mode only (no transitions).

**Rationale**: For small inputs, transition overhead > benefit.

---

## 5. Register Allocation Plan

### 5.1 Mode State Encoding

Use R24 for mode state:
```
R24 = 0: Linear mode
R24 = 1: 1-Byte mode  
R24 = 2: 2-Byte mode
R24 = 3: Inert mode
```

### 5.2 Statistics Registers

| Register | Purpose | Preserved Across |
|----------|---------|------------------|
| R25 | failure_count | Mode transitions |
| R24 | mode_state | All |
| R28 | partial_match_count (Linear) | Linear only |
| R29 | bytes_scanned_checkpoint | Mode transitions |

### 5.3 Unified Register Layout

| Register | All Modes | Notes |
|----------|-----------|-------|
| R0 | haystack_ptr | Immutable |
| R1 | (temp) | Clobbered |
| R2-R5 | (temps / rare bytes) | Mode-specific |
| R6 | needle_ptr | Immutable |
| R7 | needle_len | Immutable |
| R8 | candidate_ptr | Temp |
| R9 | searchLen | Immutable |
| R10 | current_ptr | Scan position |
| R11 | scan_start | For bytes_scanned |
| R12 | remaining | Bytes left |
| R13-R23 | temps | Various |
| R24 | mode_state | FSM state |
| R25 | failure_count | Threshold check |
| R26 | rare1_mask | 0x20 or 0x00 |
| R27 | rare1_target | Lowercase byte |
| R28 | partial_matches | Linear mode only |
| R29 | (reserved) | Future use |
| R30 | LR | Link register |

### 5.4 Vector Register Layout

| Vector | Linear | 1-Byte | 2-Byte |
|--------|--------|--------|--------|
| V0 | 0x20×16 | rare1_mask×16 | rare1_mask×16 |
| V1 | needle chunk | rare1_target×16 | rare1_target×16 |
| V2 | (temp) | (temp) | rare2_mask×16 |
| V3 | (temp) | (temp) | rare2_target×16 |
| V4-V5 | constants | constants | constants |
| V6-V9 | temps | temps | temps |
| V10-V15 | (unused) | (unused) | verification |
| V16-V19 | haystack | haystack | rare1_data |
| V20-V23 | results | results | rare1_results |
| V24-V27 | (unused) | (128B mode) | rare2_data |
| V28-V31 | (unused) | (128B mode) | rare2_results |

---

## 6. Assembly Pseudocode

### 6.1 Entry Point

```asm
// func indexFoldAdaptiveNEON(haystack string, needle string, 
//                            rare1 byte, off1 int, rare2 byte, off2 int) int
TEXT ·indexFoldAdaptiveNEON(SB), NOSPLIT, $0-64
    // Load arguments
    MOVD  haystack+0(FP), R0
    MOVD  haystack_len+8(FP), R1
    MOVD  needle+16(FP), R6
    MOVD  needle_len+24(FP), R7
    MOVBU rare1+32(FP), R2
    MOVD  off1+40(FP), R3
    MOVBU rare2+48(FP), R4
    MOVD  off2+56(FP), R5
    
    // Early exits
    SUBS  R7, R1, R9              // R9 = searchLen
    BLT   not_found
    CBZ   R7, found_zero
    
    // Check mode signal
    CMP   $0, R5                  // off2 < 0 means Linear mode
    BLT   linear_mode_entry
    
    // Precomputed rare bytes - start in 1-byte mode
    B     onebyte_mode_entry
```

### 6.2 Linear Mode

```asm
linear_mode_entry:
    // Setup for linear scan
    MOVD  R0, R10                 // R10 = current position
    MOVD  R0, R11                 // R11 = start (for bytes_scanned)
    ADD   $1, R9, R12             // R12 = remaining positions
    MOVD  ZR, R28                 // R28 = partial_match_count
    MOVD  ZR, R24                 // R24 = mode (0 = Linear)
    
    // Broadcast 0x20 for case-folding
    MOVW  $0x20, R13
    VDUP  R13, V0.B16
    
    // Small input fast path
    CMP   $256, R12
    BLT   linear_small_loop
    
linear_loop:
    // Load 16 bytes from haystack and needle
    VLD1  (R10), [V16.B16]
    VLD1  (R6), [V17.B16]
    
    // Case-fold both: OR with 0x20
    VORR  V0.B16, V16.B16, V18.B16
    VORR  V0.B16, V17.B16, V19.B16
    
    // XOR to find differences
    VEOR  V18.B16, V19.B16, V20.B16
    
    // Check if any non-zero (mismatch)
    WORD  $0x6e30a94a               // UMAXV V10.B16 → V10
    FMOVS F10, R13
    CBNZ  R13, linear_no_match
    
    // Potential match - verify full needle
    ADD   $1, R28, R28             // partial_match_count++
    // ... full verification ...
    
    // Check transition threshold
    CMP   $8, R28
    BLT   linear_continue
    SUB   R11, R10, R13            // bytes_scanned
    CMP   $512, R13
    BLT   linear_continue
    
    // Transition to 1-byte mode
    B     compute_rare1_and_transition

linear_no_match:
linear_continue:
    ADD   $1, R10
    SUB   $1, R12
    CBNZ  R12, linear_loop
    B     not_found
```

### 6.3 Mode Transitions

```asm
compute_rare1_and_transition:
    // Sample needle[0], needle[n/2], needle[n-1]
    // ... (see Section 3.5) ...
    
    // Setup 1-byte mode vectors
    // V0 = mask, V1 = target
    
    // IMPORTANT: Continue from current position, don't restart
    // R10 already at current position
    // Adjust R10 to account for off1
    ADD   R3, R0, R11             // R11 = haystack + off1
    // Compute how far ahead we are
    SUB   R0, R10, R13            // R13 = current offset in haystack
    SUB   R3, R13, R13            // R13 = offset relative to off1 position
    CMP   $0, R13
    BLT   start_from_off1         // Haven't reached off1 yet
    ADD   R11, R13, R10           // R10 = continue from current
    B     onebyte_mode_continue
    
start_from_off1:
    MOVD  R11, R10
    
onebyte_mode_continue:
    MOVD  $1, R24                 // mode = 1-Byte
    MOVD  ZR, R25                 // reset failure count
    // ... continue with 1-byte loop ...
```

### 6.4 2-Byte Mode Transition (Fixed)

```asm
transition_to_2byte:
    // IMPORTANT: Continue from current position, DON'T restart
    // R10 = current search pointer (already positioned)
    // R11 = original start (for bytes_scanned calculation)
    // R12 = remaining bytes
    
    // Compute rare2 in assembly
    // ... (see Section 3.5) ...
    
    // Setup 2-byte vectors (V2, V3)
    VDUP  R21, V2.B16             // rare2 mask
    VDUP  R22, V3.B16             // rare2 target
    
    // Setup verification constants
    WORD  $0x4f05e7e4             // VMOVI $191, V4.B16
    WORD  $0x4f00e747             // VMOVI $26, V7.B16
    WORD  $0x4f01e408             // VMOVI $32, V8.B16
    
    // Setup tail mask table
    MOVD  $tail_mask_table<>(SB), R16
    
    MOVD  $2, R24                 // mode = 2-Byte
    MOVD  ZR, R25                 // reset failure count for 2-byte mode
    
    B     loop64_2byte            // Continue from current R10/R12
```

---

## 7. API Design

### 7.1 Go Interface

```go
// IndexFold - one-shot case-insensitive search (zero setup)
// Starts in Linear mode, adaptively transitions to prefilter modes
func IndexFold(haystack, needle string) int {
    if len(needle) == 0 {
        return 0
    }
    if len(haystack) < len(needle) {
        return -1
    }
    if len(haystack) < 16 {
        return indexFoldGo(haystack, needle)
    }
    // Signal Linear mode with off2 = -1
    return indexFoldAdaptiveNEON(haystack, needle, 0, 0, 0, -1)
}

// SearchNeedle - repeated search with precomputed needle
// Starts in 1-byte mode with precomputed rare bytes
func SearchNeedle(haystack string, n Needle) int {
    if len(n.raw) == 0 {
        return 0
    }
    if len(haystack) < len(n.raw) {
        return -1
    }
    if len(haystack) < 16 {
        return indexFoldGo(haystack, n.raw)
    }
    // off2 >= 0 signals precomputed rare bytes
    return indexFoldAdaptiveNEON(haystack, n.norm, n.rare1, n.off1, n.rare2, n.off2)
}

// Assembly function signature
func indexFoldAdaptiveNEON(haystack, needle string, 
                           rare1 byte, off1 int, 
                           rare2 byte, off2 int) int
```

### 7.2 Sentinel Convention

| off2 Value | Meaning |
|------------|---------|
| -1 | Start in Linear mode (zero setup) |
| >= 0 | Start in 1-Byte mode with precomputed rare bytes |

---

## 8. Bug Fixes to Incorporate

### 8.1 Threshold Inconsistency (FIXED)

**Issue**: Header said `>> 8` but 16-byte and scalar paths used `>> 10`.

**Fix**: Changed lines 563 and 649 from `LSR $10` to `LSR $8`.

### 8.2 Unnecessary Restart on Mode Transition

**Issue**: `setup_2byte_mode` restarts from beginning instead of continuing.

**Current code** (lines 1091-1096):
```asm
// Restart search from beginning in 2-byte mode
// This is simpler and correct - we only cutover after many failures
// so re-scanning a small portion is acceptable
ADD   R3, R0, R10             // R10 = search at off1 (start over)
MOVD  R10, R11                // R11 = original searchPtr start
ADD   $1, R9, R12             // R12 = remaining = searchLen + 1
```

**Fix**: Continue from current position:
```asm
// Continue search from current position in 2-byte mode
// No need to restart - we've already verified all positions before R10
// R10 = current position (preserved from 1-byte mode)
// R12 = remaining (preserved from 1-byte mode)
// Just setup 2-byte vectors and continue
```

This fix will be incorporated in the new adaptive implementation.

---

## 9. Test Plan

### 9.1 Unit Tests

| Test Case | Description |
|-----------|-------------|
| `TestLinearModeBasic` | Short haystacks stay in Linear mode |
| `TestLinearToOneByte` | Verify transition after threshold |
| `TestOneByteToTwoByte` | Verify failure threshold triggers transition |
| `TestTwoByteToInert` | Verify prefilter disabling |
| `TestContinueNotRestart` | Verify position continuity on transition |
| `TestSentinelOff2` | Verify off2=-1 starts Linear, off2>=0 starts 1-byte |
| `TestAllSameChar` | "aaaa..." needle handling |
| `TestNeedleLen1` | Single-char needle fast path |
| `TestNeedleLen2` | Two-char needle handling |
| `TestNonLetterRare` | Digits, punctuation as rare bytes |

### 9.2 Fuzz Tests

```go
func FuzzIndexFoldAdaptive(f *testing.F) {
    f.Add("hello world", "WORLD")
    f.Add(strings.Repeat("a", 10000), "aab")
    f.Add(`{"key":"value"}`, `"num"`)
    
    f.Fuzz(func(t *testing.T, haystack, needle string) {
        // Reference implementation
        want := indexFoldGo(haystack, needle)
        
        // One-shot (Linear mode start)
        got1 := IndexFold(haystack, needle)
        if got1 != want {
            t.Errorf("IndexFold mismatch")
        }
        
        // Precomputed (1-byte mode start)
        n := MakeNeedle(needle)
        got2 := SearchNeedle(haystack, n)
        if got2 != want {
            t.Errorf("SearchNeedle mismatch")
        }
    })
}
```

### 9.3 Regression Tests

- All existing `TestContainsFold` cases
- All existing `TestSearchNeedle` cases
- High false-positive JSON patterns
- Boundary/alignment tests

---

## 10. Benchmark Suite Design

### 10.1 Benchmark Matrix

| Dimension | Values |
|-----------|--------|
| Haystack size | 64B, 256B, 1KB, 4KB, 16KB, 64KB, 1MB |
| Needle size | 4, 8, 16, 32, 64, 128, 1024 |
| Match position | start, middle, end, not_found |
| Rare byte type | letter, digit, punctuation |
| Pattern type | random, repeated, JSON, pathological |

### 10.2 Key Benchmarks

```go
// One-shot (measures Linear mode + adaptive behavior)
func BenchmarkIndexFold_OneShot(b *testing.B) {
    sizes := []int{64, 256, 1024, 4096, 16384}
    for _, size := range sizes {
        haystack := makeRandomASCII(size)
        needle := "needle"
        b.Run(fmt.Sprintf("size=%d", size), func(b *testing.B) {
            for i := 0; i < b.N; i++ {
                IndexFold(haystack, needle)
            }
        })
    }
}

// Repeated (measures precomputed path)
func BenchmarkSearchNeedle_Repeated(b *testing.B) {
    haystack := makeRandomASCII(10000)
    needle := MakeNeedle("needle")
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        SearchNeedle(haystack, needle)
    }
}

// High false-positive (measures adaptive cutover)
func BenchmarkIndexFold_HighFP(b *testing.B) {
    haystack := strings.Repeat(`{"key":"value"},`, 1000)
    needle := `"num"`
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        IndexFold(haystack, needle)
    }
}

// Pathological (all same char)
func BenchmarkIndexFold_Pathological(b *testing.B) {
    haystack := strings.Repeat("a", 10000) + "aab"
    needle := "aab"
    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        IndexFold(haystack, needle)
    }
}
```

### 10.3 Comparison Baselines

1. `indexFoldGo` - Pure Go implementation
2. `strings.Index` - Case-sensitive (theoretical max)
3. `strings.EqualFold` based search
4. Current `indexFoldNeedleNEON` (without Linear mode)

### 10.4 Performance Targets

| Scenario | Target vs strings.Index |
|----------|-------------------------|
| One-shot, found early | ≥ 80% |
| One-shot, not found | ≥ 70% |
| Repeated search | ≥ 85% |
| High false-positive | ≥ 5x faster |
| Pathological | No worse than 50% |

---

## 11. Risk Analysis

### 11.1 Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Linear mode slower than expected | Medium | High | Optimize TBL vs OR path; fallback to current |
| Threshold tuning incorrect | Medium | Medium | Extensive benchmarking; make thresholds configurable |
| In-assembly rare selection slow | Low | Medium | Keep simple (3 samples); precompute in Go if needed |
| Mode transition overhead | Low | Low | Amortized over many bytes; minimum floors |
| Register pressure | Medium | Medium | Careful allocation; use stack if needed |

### 11.2 Compatibility Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Break existing SearchNeedle users | Low | High | Maintain API compatibility; sentinel convention |
| Different behavior between modes | Low | High | Extensive fuzz testing; shared verification |
| Platform differences (Graviton vs M-series) | Medium | Medium | Benchmark on both; tune thresholds per platform |

### 11.3 Fallback Plan

If adaptive approach underperforms:
1. Keep current `indexFoldNeedleNEON` for `SearchNeedle`
2. Add separate `indexFoldLinearNEON` for `IndexFold` one-shot
3. Use Go's `indexFoldRabinKarp` for small haystacks

---

## 12. Implementation Phases

### Phase 1: Foundation (Week 1)
- [ ] Fix 2-byte restart bug (continue from current position)
- [ ] Add new assembly entry point `indexFoldAdaptiveNEON`
- [ ] Implement Linear mode loop
- [ ] Add sentinel detection (off2 == -1)
- [ ] Basic tests passing

### Phase 2: Mode Transitions (Week 2)
- [ ] Implement Linear → 1-Byte transition
- [ ] Add in-assembly rare1 computation (3 samples)
- [ ] Implement 1-Byte → 2-Byte transition (continue, not restart)
- [ ] Add in-assembly rare2 computation
- [ ] Implement 2-Byte → Inert transition
- [ ] Comprehensive tests passing

### Phase 3: Optimization (Week 3)
- [ ] Tune thresholds via benchmarks
- [ ] Optimize Linear mode loop (OR vs TBL)
- [ ] Add platform-specific thresholds if needed
- [ ] Profile and optimize hot paths
- [ ] Full benchmark suite passing targets

### Phase 4: Polish (Week 4)
- [ ] Update documentation
- [ ] Add AGENTS.md notes for future maintenance
- [ ] Fuzz testing campaign
- [ ] Performance regression CI
- [ ] Final code review

---

## Appendix A: Reference Implementations

### A.1 Memchr PrefilterState (Rust)
```rust
pub(crate) struct PrefilterState {
    skips: u32,   // 0 = inert, 1+ = active
    skipped: u32, // total bytes skipped
}

impl PrefilterState {
    const MIN_SKIPS: u32 = 50;
    const MIN_SKIP_BYTES: u32 = 8;
    
    pub(crate) fn is_effective(&mut self) -> bool {
        if self.is_inert() { return false; }
        if self.skips() < Self::MIN_SKIPS { return true; }
        if self.skipped >= Self::MIN_SKIP_BYTES * self.skips() {
            return true;
        }
        self.skips = 0; // become inert
        false
    }
}
```

### A.2 Origin uppercasingTable
```asm
DATA uppercasingTable<>+0x00(SB)/8, $0x2020202020202000
DATA uppercasingTable<>+0x08(SB)/8, $0x2020202020202020
DATA uppercasingTable<>+0x10(SB)/8, $0x2020202020202020
DATA uppercasingTable<>+0x18(SB)/8, $0x0000000000202020
GLOBL uppercasingTable<>(SB), (RODATA|NOPTR), $32
```

Usage: After adding 0xA0 to a byte, lowercase letters (0x61-0x7A) become indices 0x01-0x1A. Table lookup returns 0x20 for these, which when subtracted converts to uppercase.

---

## Appendix B: Instruction Quick Reference

| Instruction | Description |
|-------------|-------------|
| `VORR V0.B16, V1.B16, V2.B16` | V2 = V0 OR V1 (16 bytes) |
| `VEOR V0.B16, V1.B16, V2.B16` | V2 = V0 XOR V1 (16 bytes) |
| `VCMEQ V0.B16, V1.B16, V2.B16` | V2 = (V0 == V1) ? 0xFF : 0x00 |
| `VTBL V0.B16, [V1.B16, V2.B16], V3.B16` | Table lookup |
| `VDUP R0, V0.B16` | Broadcast R0 to all 16 lanes |
| `WORD $0x6e30a8c6` | UMAXV V6.B16, V6 (horizontal max) |
| `WORD $0x0f0c8694` | SHRN V20.8B, V20.8H, #4 (narrow) |
| `RBIT R0, R1` | Reverse bits |
| `CLZ R0, R1` | Count leading zeros |
| `LSR $N, R0, R1` | Logical shift right by N |
