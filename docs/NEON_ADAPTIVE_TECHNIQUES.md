# Complete Guide to ARM64 NEON Adaptive Substring Search

This document explains every technique used in `ascii/ascii_neon_needle.s`, a high-performance case-insensitive substring search implementation.

---

## Table of Contents

1. [What Is This File?](#part-1-what-is-this-file)
2. [What Is SIMD?](#part-2-what-is-simd)
3. [Registers](#part-3-registers)
4. [The Algorithm's Goal](#part-4-the-algorithms-goal)
5. [Case-Insensitive Matching Trick](#part-5-case-insensitive-matching-trick)
6. [Broadcasting (VDUP)](#part-6-broadcasting-vdup)
7. [Loading Data (VLD1)](#part-7-loading-data-vld1)
8. [The Core Search Pattern (VAND + VCMEQ)](#part-8-the-core-search-pattern-vand--vcmeq)
9. [OR-Reduction (Quick "Any Match?" Check)](#part-9-or-reduction-quick-any-match-check)
10. [The Syndrome (Finding WHICH Byte Matched)](#part-10-the-syndrome-finding-which-byte-matched)
11. [Finding the First Match (RBIT + CLZ)](#part-11-finding-the-first-match-rbit--clz)
12. [Clearing Tried Bits (BIC)](#part-12-clearing-tried-bits-bic)
13. [Verification (Checking Full Match)](#part-13-verification-checking-full-match)
14. [The Adaptive Strategy](#part-14-the-adaptive-strategy)
15. [Raw Machine Code (WORD)](#part-15-raw-machine-code-word)
16. [The Tail Mask Table](#part-16-the-tail-mask-table)
17. [Tiered Loop Structure](#part-17-tiered-loop-structure)
18. [Summary Diagram](#part-18-summary-diagram)

---

## Part 1: What Is This File?

This is **ARM64 assembly code** — instructions that run directly on the CPU. It implements a **case-insensitive substring search** (like finding "hello" in "Say HELLO world", matching regardless of upper/lowercase).

The file uses **NEON**, which is ARM's **SIMD** technology.

---

## Part 2: What Is SIMD?

**SIMD = Single Instruction, Multiple Data**

Normal code processes one value at a time:
```
load byte 1, check if it equals 'X'
load byte 2, check if it equals 'X'
load byte 3, check if it equals 'X'
... (repeat 16 times)
```

SIMD processes **many values simultaneously**:
```
load 16 bytes at once into a "vector"
check all 16 bytes against 'X' in ONE instruction
```

This is why SIMD code can be 10-20x faster than scalar code.

---

## Part 3: Registers

A **register** is a tiny, ultra-fast storage location inside the CPU.

### General-Purpose Registers (R0-R30)

These hold integers, pointers, counters. Examples from the code:

```asm
MOVD  haystack+0(FP), R0      // R0 = pointer to the string we're searching in
MOVD  haystack_len+8(FP), R1  // R1 = length of that string
MOVBU rare1+16(FP), R2        // R2 = a byte value we're looking for
```

| Instruction | Meaning |
|-------------|---------|
| `MOVD` | "Move doubleword" — copies a 64-bit value |
| `MOVBU` | "Move byte unsigned" — copies an 8-bit value, zero-extended to 64 bits |
| `FP` | "Frame pointer" — where function arguments live on the stack |

### Vector Registers (V0-V31)

These hold **16 bytes** each (128 bits). They're the heart of SIMD.

```asm
VDUP  R26, V0.B16    // Broadcast R26 to all 16 bytes of V0
```

The `.B16` suffix means "interpret V0 as 16 Bytes". Other interpretations:

| Suffix | Meaning |
|--------|---------|
| `V0.B16` | 16 Bytes (8-bit values) |
| `V0.H8` | 8 Halfwords (16-bit values) |
| `V0.S4` | 4 Singles (32-bit values) |
| `V0.D2` | 2 Doublewords (64-bit values) |

---

## Part 4: The Algorithm's Goal

We want to find a **needle** (small string) inside a **haystack** (big string), ignoring case.

**Naive approach:** Check every position in the haystack. Very slow.

**Smart approach:** **Filter first**. Pick a "rare" byte from the needle (like 'Q' instead of 'E'), scan for that byte only. When found, verify the full needle matches.

This code goes further with **two rare bytes** for even better filtering.

---

## Part 5: Case-Insensitive Matching Trick

ASCII letters differ by exactly one bit:
```
'A' = 01000001 (65)
'a' = 01100001 (97)
      ↑ bit 5 is the only difference
```

To match case-insensitively, we **clear bit 5** using AND with `0xDF`:
```
'A' AND 0xDF = 01000001 (stays 'A')
'a' AND 0xDF = 01000001 (becomes 'A')
```

Now both cases produce the same value.

### Code (Lines 41-54)

```asm
// Is rare1 a letter?
ORRW  $0x20, R2, R10    // Set bit 5 (force lowercase)
SUBW  $97, R10, R10     // Subtract 'a' (97)
CMPW  $26, R10          // Is result < 26? Then it's a-z
BCS   not_letter1       // If >= 26 (carry set), not a letter
MOVW  $0xDF, R26        // Letter: mask = 0xDF (clears bit 5)
ANDW  R24, R2, R27      // target = uppercase version
B     setup_rare1
not_letter1:
MOVW  $0xFF, R26        // Non-letter: mask = 0xFF (no change)
MOVW  R2, R27           // target = exact byte
setup_rare1:
VDUP  R26, V0.B16       // Broadcast mask to all 16 lanes
VDUP  R27, V1.B16       // Broadcast target to all 16 lanes
```

| Instruction | Meaning |
|-------------|---------|
| `ORRW` | OR immediate with register (32-bit) |
| `SUBW` | Subtract (32-bit) |
| `CMPW` | Compare (32-bit), sets condition flags |
| `BCS` | Branch if Carry Set (unsigned >=) |

---

## Part 6: Broadcasting (VDUP)

```asm
VDUP  R26, V0.B16    // V0 = [R26, R26, R26, ... R26] (16 copies)
VDUP  R27, V1.B16    // V1 = [R27, R27, R27, ... R27] (16 copies)
```

**VDUP** = "Vector Duplicate". Copies one scalar value into all 16 lanes of a vector.

If R26 = 0xDF and R27 = 0x51 ('Q'), then:
```
V0 = [DF, DF, DF, DF, DF, DF, DF, DF, DF, DF, DF, DF, DF, DF, DF, DF]
V1 = [51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51]
```

Now we can compare 16 haystack bytes against 'Q' in one instruction.

---

## Part 7: Loading Data (VLD1)

```asm
VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
```

This loads **64 bytes** from memory into 4 vector registers:
- Bytes 0-15 → V16
- Bytes 16-31 → V17
- Bytes 32-47 → V18
- Bytes 48-63 → V19

The `.P` suffix means **post-increment**: after loading, R10 is increased by 64, ready for the next load.

---

## Part 8: The Core Search Pattern (VAND + VCMEQ)

```asm
VAND  V0.B16, V16.B16, V20.B16   // V20 = V16 AND V0
VCMEQ V1.B16, V20.B16, V20.B16   // V20 = (V20 == V1) ? 0xFF : 0x00
```

### Step 1: VAND (Vector AND)

Apply the case-folding mask to each byte:
```
V16 = [H, e, l, l, o, W, o, r, l, d, ...]  (haystack data)
V0  = [DF,DF,DF,DF,DF,DF,DF,DF,DF,DF,...]  (mask)
V20 = [H, E, L, L, O, W, O, R, L, D, ...]  (uppercase versions)
```

Each byte is ANDed with 0xDF, clearing bit 5 and converting lowercase to uppercase.

### Step 2: VCMEQ (Vector Compare Equal)

Compare each byte against the target:
```
V20 = [48, 45, 4C, 4C, 4F, 57, 4F, 52, 4C, 44, ...]  (hex: H,E,L,L,O,W,O,R,L,D)
V1  = [51, 51, 51, 51, 51, 51, 51, 51, 51, 51, ...]  (target 'Q' = 0x51)
V20 = [00, 00, 00, 00, 00, 00, 00, 00, 00, 00, ...]  (no matches)
```

If any byte matched, that position would contain `0xFF` instead of `0x00`.

---

## Part 9: OR-Reduction (Quick "Any Match?" Check)

After checking 8 vectors (128 bytes), we have 8 result vectors. We want to know: **did ANY byte match anywhere?**

```asm
// Combine pairs
VORR  V20.B16, V21.B16, V6.B16   // V6 = V20 OR V21
VORR  V22.B16, V23.B16, V7.B16   // V7 = V22 OR V23
VORR  V28.B16, V29.B16, V8.B16   // V8 = V28 OR V29
VORR  V30.B16, V31.B16, V9.B16   // V9 = V30 OR V31

// Combine again
VORR  V6.B16, V7.B16, V6.B16     // V6 = first 64 bytes combined
VORR  V8.B16, V9.B16, V8.B16     // V8 = second 64 bytes combined
VORR  V6.B16, V8.B16, V6.B16     // V6 = all 128 bytes combined
```

**VORR** (Vector OR) combines vectors. If ANY byte in ANY input is `0xFF`, the corresponding output byte is `0xFF`.

After ORing all 8 vectors into one, we need to check if that one vector is all zeros:

```asm
VADDP V6.D2, V6.D2, V6.D2   // Add the two 64-bit halves together
VMOV  V6.D[0], R13          // Move result to general register
CBZ   R13, loop128_1byte    // If zero, no matches, continue scanning
```

| Instruction | Meaning |
|-------------|---------|
| `VADDP` | "Vector Add Pairwise" — adds adjacent elements |
| `VMOV` | Moves data between vector and general-purpose registers |
| `CBZ` | "Compare and Branch if Zero" |

This is the **fast path**: most 128-byte blocks have no matches, so we skip them with minimal work.

---

## Part 10: The Syndrome (Finding WHICH Byte Matched)

When we find matches, we need to know **which byte positions** matched. A **syndrome** is a compact integer where bits encode match positions.

### Method 1: Magic Constant (1-Byte Mode)

Lines 56-59 set up a magic constant:
```asm
MOVD  $0x4010040140100401, R10
VMOV  R10, V5.D[0]
VMOV  R10, V5.D[1]
```

This number has bits at specific positions. When ANDed with the match vector:

```
Match vector:  [FF, 00, 00, FF, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00]
Magic const:   [01, 04, 10, 40, 01, 04, 10, 40, 01, 04, 10, 40, 01, 04, 10, 40]
After AND:     [01, 00, 00, 40, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00]
```

After horizontal addition (`VADDP`), we get an integer where **every 2 bits represent one byte position**. Matches at positions 0 and 3 produce bits at positions 0-1 and 6-7.

### Method 2: SHRN Narrowing (2-Byte Mode)

Line 953 uses a different approach:
```asm
WORD  $0x0f0c8694   // VSHRN $4, V20.H8, V20.B8
```

**SHRN** = "Shift Right Narrow". This:
1. Treats the 16-byte vector as 8 halfwords (16-bit values)
2. Shifts each right by 4 bits
3. Keeps only the low 8 bits of each, packing into 8 bytes

Result: Each **nibble (4 bits)** in the output represents one original byte position.

```
Input:  [FF, 00, 00, FF, 00, FF, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00]
Output: [0F, 00, 0F, 0F, 00, 00, 00, 00] (in low 8 bytes)
```

Then `FMOVD F20, R13` extracts this to a 64-bit integer.

---

## Part 11: Finding the First Match (RBIT + CLZ)

Once we have a syndrome integer with bits set for matches, we find the first one:

```asm
RBIT  R13, R15    // Reverse all bits
CLZ   R15, R15    // Count leading zeros
```

| Instruction | Meaning |
|-------------|---------|
| `RBIT` | "Reverse Bits" — flips bit order (bit 0 ↔ bit 63) |
| `CLZ` | "Count Leading Zeros" — counts 0 bits before first 1 |

**Why RBIT first?** We want the **rightmost** (lowest) set bit, but CLZ finds the **leftmost**. RBIT flips the order.

Example:
```
R13 = 0x0000000000000104  (bits 2 and 8 are set)
After RBIT: 0x2080000000000000  (bits are reversed)
After CLZ: 2  (two leading zeros before first 1, at bit 61)
```

Then we convert bit position to byte position:
```asm
LSR   $1, R15, R15    // Divide by 2 (magic constant uses 2 bits per byte)
// OR for SHRN method:
LSR   $2, R19, R19    // Divide by 4 (SHRN uses 4 bits per byte)
```

**LSR** = "Logical Shift Right" — equivalent to unsigned division by a power of 2.

---

## Part 12: Clearing Tried Bits (BIC)

When a candidate fails verification, we need to try the **next** match in the syndrome:

```asm
ADD   $1, R15, R17     // R17 = byte_position + 1
SUB   R14, R17, R17    // Adjust for chunk offset
LSL   $1, R17, R17     // Convert to bit position (×2 for magic constant)
MOVD  $1, R19          // R19 = 1
LSL   R17, R19, R17    // R17 = 1 << bit_position
SUB   $1, R17, R17     // R17 = mask with all bits below set
BIC   R17, R13, R13    // R13 = R13 AND NOT R17
```

| Instruction | Meaning |
|-------------|---------|
| `LSL` | "Logical Shift Left" — multiply by power of 2 |
| `BIC` | "Bit Clear" — `dest = src1 AND NOT src2` |

This clears the bit we just tried **and all lower bits**, so the next RBIT+CLZ finds the next match.

Example:
```
R13 = 0x00001010  (matches at byte positions 2 and 6)
                   (position 2 → bit 4, position 6 → bit 12)
We tried position 2, it failed.
byte_position + 1 = 3, ×2 = 6
Mask = (1 << 6) - 1 = 0x0000003F  (bits 0-5 set)
After BIC: R13 = 0x00001000  (only position 6 remains)
```

---

## Part 13: Verification (Checking Full Match)

Finding the rare byte is just filtering. We must verify the **entire needle** matches at that position.

### Quick Check: First and Last Bytes

```asm
MOVBU (R8), R17       // Load haystack[candidate]
// ... case-fold ...
MOVBU (R6), R19       // Load needle[0]
CMPW  R19, R17        // Compare
BNE   verify_fail     // If different, reject immediately

ADD   R7, R8, R17     // R17 = haystack + needle_len
SUB   $1, R17         // R17 = haystack + needle_len - 1 (last position)
MOVBU (R17), R17      // Load last byte of candidate
// ... compare with needle's last byte ...
```

Checking first and last bytes catches most false positives cheaply before expensive full comparison.

### Full Scalar Verification Loop (1-Byte Mode)

```asm
vloop_1byte:
    CBZ   R20, found       // If remaining length = 0, success!
    MOVBU (R17), R21       // Load haystack byte
    MOVBU (R19), R22       // Load needle byte
    SUBW  $97, R21, R23    // R23 = haystack_byte - 'a'
    CMPW  $26, R23         // Is it a letter?
    BCS   vnf1c            // If not, skip case-folding
    ANDW  R24, R21, R21    // Case-fold: clear bit 5
vnf1c:
    CMPW  R22, R21         // Compare
    BNE   verify_fail      // Mismatch → fail
    ADD   $1, R17          // Advance haystack ptr
    ADD   $1, R19          // Advance needle ptr
    SUB   $1, R20          // Decrement remaining
    B     vloop_1byte      // Loop
```

| Instruction | Meaning |
|-------------|---------|
| `CBZ` | "Compare and Branch if Zero" |
| `MOVBU` | Load unsigned byte from memory |
| `BNE` | "Branch if Not Equal" |

### Vectorized Verification (2-Byte Mode)

Lines 1011-1031 verify 16 bytes per iteration:

```asm
vloop64_2byte:
    SUBS  $16, R19, R23            // R23 = remaining - 16; set flags
    BLT   vtail64_2byte            // If < 16 remaining, handle tail

    VLD1.P 16(R21), [V10.B16]      // Load 16 haystack bytes
    VLD1.P 16(R22), [V11.B16]      // Load 16 needle bytes
    MOVD   R23, R19                // Update remaining

    // Vectorized case-insensitive compare:
    VADD  V4.B16, V10.B16, V12.B16  // V12 = haystack + 159 (= haystack - 97)
    VEOR  V10.B16, V11.B16, V10.B16 // V10 = haystack XOR needle
    WORD  $0x6e2c34ec               // CMHI V12.16B, V7.16B, V12.16B
    VAND  V8.B16, V12.B16, V12.B16  // V12 = is_letter ? 0x20 : 0x00
    VEOR  V12.B16, V10.B16, V10.B16 // V10 = diff with case masked out
    WORD  $0x6e30a94a               // UMAXV B10, V10.16B
    FMOVS F10, R23                  // Move max to scalar
    CBZW  R23, vloop64_2byte        // If max=0, all matched, continue
    B     clear64_2byte             // Mismatch
```

#### How the Vectorized Compare Works

**Step 1: XOR to find differences**
```asm
VEOR  V10.B16, V11.B16, V10.B16   // V10 = haystack XOR needle
```
If bytes are equal, XOR produces 0. Differences produce non-zero.

**Step 2: Detect lowercase letters in haystack**
```asm
VADD  V4.B16, V10.B16, V12.B16    // V12 = haystack + 159
```
V4 contains 159 in each byte. Adding 159 is the same as subtracting 97 in unsigned 8-bit arithmetic (wraps around). This computes `haystack_byte - 'a'`.

```asm
WORD  $0x6e2c34ec   // CMHI V12.16B, V7.16B, V12.16B
```
This is `CMHI` (Compare Higher, unsigned). V7 contains 26 in each byte. 
Result: `V12[i] = (26 > V12[i]) ? 0xFF : 0x00`

If `(haystack_byte - 'a') < 26`, the byte is a **lowercase** letter (a-z).

**Step 3: Mask out case differences**
```asm
VAND  V8.B16, V12.B16, V12.B16    // V12 = is_lowercase ? 0x20 : 0x00
VEOR  V12.B16, V10.B16, V10.B16   // XOR with differences
```
V8 contains 0x20 (32) in each byte.

**Key insight**: The needle is **pre-normalized to uppercase**. So:
- If haystack is uppercase 'A' and needle is 'A': XOR=0, mask=0, final=0 ✓
- If haystack is lowercase 'a' and needle is 'A': XOR=0x20, mask=0x20, final=0 ✓
- If haystack is 'a' and needle is 'B': XOR=0x23, mask=0x20, final=0x03 ✗

The 0x20 mask cancels out the case difference only when comparing the same letter.

**Step 4: Check for any mismatches**
```asm
WORD  $0x6e30a94a   // UMAXV B10, V10.16B
FMOVS F10, R23
CBZW  R23, vloop64_2byte
```
`UMAXV` takes the maximum of all 16 bytes. If ANY byte is non-zero (mismatch), the max is non-zero.

---

## Part 14: The Adaptive Strategy

The implementation has **two levels of adaptivity**:

1. **Loop Size Adaptivity** (compile-time threshold): Chooses between 32-byte and 128-byte loops based on input size
2. **Filter Mode Adaptivity** (runtime): Switches from 1-byte to 2-byte filtering based on observed failure rate

Additionally, a **non-letter fast path** skips unnecessary VAND instructions for digit/punctuation needles.

### Level 1: Loop Size Selection

At entry, the code checks the remaining bytes against a threshold:

```asm
CMP   $768, R12              // Threshold: 768 bytes
BGE   loop128_1byte          // Large input: use 128-byte loop
CMP   $32, R12
BLT   loop16_1byte_entry     // Small input: use 16-byte loop
                             // Otherwise: use 32-byte loop
```

- **128-byte loop**: Lower per-byte overhead, better for large inputs (amortizes loop setup cost)
- **32-byte loop**: Tighter speculation overlap during the VMOV stall, better for small inputs

See [Part 17](#part-17-tiered-loop-structure) for threshold tuning details.

### Level 2: 1-Byte vs 2-Byte Mode

#### 1-Byte Mode (Default)

- Searches for ONE rare byte
- Very fast filtering
- But: May have more false positives requiring verification

#### 2-Byte Mode (Fallback)

- Searches for TWO rare bytes simultaneously
- Slower filtering (loads from two positions)
- But: Far fewer false positives

#### The Cutover Decision

```asm
ADD   $1, R25, R25         // R25 = failure_count + 1
SUB   R11, R10, R17        // R17 = bytes_scanned (current - start)
LSR   $8, R17, R17         // R17 = bytes_scanned / 256
ADD   $4, R17, R17         // threshold = 4 + (bytes_scanned / 256)
CMP   R17, R25             // Compare failure_count to threshold
BGT   setup_2byte_mode     // If failures > threshold, switch modes
```

The threshold formula: `failures > 4 + (bytes_scanned / 256)`

This means:
- First 4 failures are always tolerated (startup noise)
- After that, allow ~1 failure per 256 bytes scanned
- If the failure rate exceeds this, switch to 2-byte mode

The threshold grows as we scan more data, preventing premature switches while catching sustained high failure rates.

### Non-Letter Fast Path

For non-letter rare bytes (digits, punctuation, symbols), the case-fold mask is 0xFF, which means VAND with 0xFF is a no-op. The code detects this at entry and skips the VAND instructions entirely:

```asm
// After computing R26 (mask): 0xDF for letters, 0xFF for non-letters
TSTW  $0x20, R26              // bit 5 differs: 0xDF vs 0xFF
BNE   dispatch_nonletter      // Skip to VAND-free loops
```

This reduces the inner loop from 7 ops to 5 ops:

**Letter loop (7 ops per 32 bytes):**
```
VLD1 → SUBS → VAND → VAND → VCMEQ → VCMEQ → VORR → VADDP → VMOV
```

**Non-letter loop (5 ops per 32 bytes):**
```
VLD1 → SUBS → VCMEQ → VCMEQ → VORR → VADDP → VMOV
```

Since Go's case-sensitive `strings.Index` uses ~5 ops per iteration, the non-letter path matches Go's theoretical throughput. In practice, non-letter needles achieve **95-118%** of Go's case-sensitive speed across platforms.

---

## Part 15: Raw Machine Code (WORD)

Some ARM64 instructions aren't supported by Go's assembler, so we encode them as raw bytes:

```asm
WORD  $0x6e30a94a   // UMAXV B10, V10.16B
```

The assembler emits these bytes directly into the output.

### Common Encodings in This File

| Hex Code | Instruction | Meaning |
|----------|-------------|---------|
| `0x6e30a94a` | `UMAXV B10, V10.16B` | Maximum of 16 bytes → scalar |
| `0x0f0c8694` | `SHRN V20.8B, V20.8H, #4` | Shift right and narrow |
| `0x6e2c34ec` | `CMHI V12.16B, V7.16B, V12.16B` | Unsigned compare greater-than |
| `0x4f04e7e4` | `MOVI V4.16B, #159` | Move immediate to all lanes |
| `0x4f00e747` | `MOVI V7.16B, #26` | Move immediate to all lanes |
| `0x4f01e408` | `MOVI V8.16B, #32` | Move immediate to all lanes |
| `0x3cf37a0d` | `LDR Q13, [X16, X19, LSL #4]` | Load with scaled index |

---

## Part 16: The Tail Mask Table

When fewer than 16 bytes remain, we can't do a full vector load and compare (we'd read garbage or crash on unmapped memory).

The code defines a lookup table with 16-byte masks:

```asm
// Entry 0: all zeros (for 0 remaining bytes)
DATA tail_mask_table<>+0x00(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x08(SB)/8, $0x0000000000000000

// Entry 1: first byte is 0xFF, rest are 0x00
DATA tail_mask_table<>+0x10(SB)/1, $0xff
DATA tail_mask_table<>+0x11(SB)/8, $0x0000000000000000
// ...

// Entry 8: first 8 bytes are 0xFF
DATA tail_mask_table<>+0x80(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0x88(SB)/8, $0x0000000000000000
// ...
```

Each entry is 16 bytes. Entry N has the first N bytes set to 0xFF, rest 0x00.

### Usage

```asm
WORD  $0x3cf37a0d   // LDR Q13, [X16, X19, LSL #4]
```

This loads from `R16 + (R19 << 4)` where:
- R16 = base address of tail_mask_table
- R19 = number of remaining bytes (1-15)
- `<< 4` multiplies by 16 (each table entry is 16 bytes)

Then:
```asm
VAND  V13.B16, V10.B16, V10.B16   // Mask out bytes beyond needle
```

This zeros out the bytes we don't care about, so garbage data doesn't cause false mismatches.

---

## Part 17: Tiered Loop Structure

The code has progressively smaller loops for handling different data sizes efficiently:

```
┌─────────────────────────────────────────────────┐
│  loop128_1byte   (processes 128 bytes/iteration) │
│       ↓ (when < 128 bytes remain)               │
│  loop32_1byte    (processes 32 bytes/iteration)  │
│       ↓ (when < 32 bytes remain)                │
│  loop16_1byte    (processes 16 bytes/iteration)  │
│       ↓ (when < 16 bytes remain)                │
│  scalar_1byte    (processes 1 byte/iteration)    │
└─────────────────────────────────────────────────┘
```

Each tier has an **entry point** that checks if there's enough data:

```asm
loop32_1byte_entry:
    CMP   $32, R12           // Is remaining >= 32?
    BLT   loop16_1byte_entry // If not, try smaller loop
```

This avoids wasted vector operations on small remainders.

### Loop Threshold Tuning

The threshold between 32-byte and 128-byte loops was empirically tuned for Graviton processors.

**Why two loop sizes?**
- **128-byte loop**: Lower per-byte overhead, better for large inputs (amortizes loop setup)
- **32-byte loop**: Tighter speculation overlap during VMOV stall, better for small inputs

**Threshold sweep on Graviton 4** (% of Go's case-sensitive strings.Index):

| Threshold | 768B | 1024B | 1280B | 1536B | 1792B | 2048B |
|-----------|------|-------|-------|-------|-------|-------|
| 2KB       | 85%  | 87%   | 84%   | 84%   | 80%   | 84%   |
| 1.5KB     | 85%  | 87%   | 84%   | 88%   | 94%   | 95%   |
| 1.25KB    | 85%  | 86%   | 85%   | 94%   | 99%   | 95%   |
| 1KB       | 84%  | 86%   | 97%   | 97%   | 94%   | 95%   |
| **768B**  | 86%  | **95%** | **97%** | 94%   | **100%** | 95%   |
| 512B      | 94%  | 95%   | 95%   | 94%   | 94%   | 95%   |

**Key observations:**
- At 2KB threshold, the 1792B case was only 80% (worst case)
- Lowering to 768B achieves 95-100% across the 1-2KB range
- Going below 768B hurts 1792B performance (128-byte loop overhead)

**Final threshold: 768 bytes** — optimal balance for Graviton 3/4.

Graviton 3 shows similar patterns (1024B at 99% with 768B threshold).

---

## Part 18: Summary Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      ADAPTIVE ALGORITHM                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                  1-BYTE MODE (Default)                   │   │
│  ├─────────────────────────────────────────────────────────┤   │
│  │  Load 128 bytes from haystack                           │   │
│  │       ↓                                                  │   │
│  │  VAND + VCMEQ: find rare1 byte matches                  │   │
│  │       ↓                                                  │   │
│  │  OR-reduce all 8 vectors                                │   │
│  │       ↓                                                  │   │
│  │  Any matches? ────NO────→ Loop to next 128 bytes        │   │
│  │       │YES                                               │   │
│  │       ↓                                                  │   │
│  │  Extract syndrome (magic constant + horizontal add)     │   │
│  │       ↓                                                  │   │
│  │  RBIT + CLZ: find first match position                  │   │
│  │       ↓                                                  │   │
│  │  Quick verify: first & last bytes                       │   │
│  │       ↓                                                  │   │
│  │  Full verify: byte-by-byte comparison                   │   │
│  │       ↓                                                  │   │
│  │  Match? ────YES────→ RETURN POSITION ✓                  │   │
│  │       │NO                                                │   │
│  │       ↓                                                  │   │
│  │  Increment failure counter                              │   │
│  │       ↓                                                  │   │
│  │  failures > 4 + (bytes/256)?                            │   │
│  │       │YES              │NO                              │   │
│  │       ↓                 ↓                                │   │
│  │  SWITCH TO 2-BYTE    Clear bit, try next match          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                          ↓                                      │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                  2-BYTE MODE (Fallback)                  │   │
│  ├─────────────────────────────────────────────────────────┤   │
│  │  Load rare1 positions (64 bytes)                        │   │
│  │  Load rare2 positions (64 bytes at different offset)    │   │
│  │       ↓                                                  │   │
│  │  Check rare1 matches (VAND + VCMEQ)                     │   │
│  │  Check rare2 matches (VAND + VCMEQ)                     │   │
│  │       ↓                                                  │   │
│  │  AND results: position must match BOTH                  │   │
│  │       ↓                                                  │   │
│  │  Far fewer candidates → less verification work          │   │
│  │       ↓                                                  │   │
│  │  Vectorized verify: 16 bytes/iteration                  │   │
│  │       ↓                                                  │   │
│  │  Use tail mask table for remainder                      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

Key Performance Characteristics (Graviton 4):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• 1-byte mode (letters): 86-100% of case-sensitive strings.Index speed
• 1-byte mode (non-letters): 95-100% of strings.Index speed  
• 2-byte mode: ~50% of pure scan speed, but far fewer false positives
• High false-positive scenarios (JSON): 6x faster than strings.Index
• Adaptive switch prevents worst-case scenarios on adversarial data
```

---

## Appendix: Instruction Reference

| Instruction | Full Name | Description |
|-------------|-----------|-------------|
| `ADD` | Add | `dest = src1 + src2` |
| `SUB` | Subtract | `dest = src1 - src2` |
| `SUBS` | Subtract and Set flags | Like SUB but sets condition flags |
| `AND` | Bitwise AND | `dest = src1 & src2` |
| `ORR` | Bitwise OR | `dest = src1 \| src2` |
| `EOR` | Exclusive OR | `dest = src1 ^ src2` |
| `BIC` | Bit Clear | `dest = src1 & ~src2` |
| `LSL` | Logical Shift Left | `dest = src << amount` |
| `LSR` | Logical Shift Right | `dest = src >> amount` (unsigned) |
| `RBIT` | Reverse Bits | Reverses all 64 bits |
| `CLZ` | Count Leading Zeros | Counts 0 bits before first 1 |
| `CMP` | Compare | Sets flags for `src1 - src2` |
| `CBZ` | Compare and Branch if Zero | Branch if register == 0 |
| `CBNZ` | Compare and Branch if Not Zero | Branch if register != 0 |
| `BEQ` | Branch if Equal | Branch if Z flag set |
| `BNE` | Branch if Not Equal | Branch if Z flag clear |
| `BLT` | Branch if Less Than | Branch if N != V |
| `BGT` | Branch if Greater Than | Branch if Z==0 and N==V |
| `BGE` | Branch if Greater or Equal | Branch if N == V |
| `BCS` | Branch if Carry Set | Branch if C flag set (unsigned >=) |
| `MOVD` | Move Doubleword | Copy 64-bit value |
| `MOVW` | Move Word | Copy 32-bit value |
| `MOVBU` | Move Byte Unsigned | Load byte, zero-extend to 64 bits |
| `VLD1` | Vector Load | Load 1-4 vectors from memory |
| `VLD1.P` | Vector Load Post-increment | Load and advance pointer |
| `VMOV` | Vector Move | Move between vector and GP registers |
| `VDUP` | Vector Duplicate | Broadcast scalar to all lanes |
| `VAND` | Vector AND | Bitwise AND across all lanes |
| `VORR` | Vector OR | Bitwise OR across all lanes |
| `VEOR` | Vector XOR | Bitwise XOR across all lanes |
| `VADD` | Vector Add | Add corresponding lanes |
| `VADDP` | Vector Add Pairwise | Add adjacent lanes |
| `VCMEQ` | Vector Compare Equal | Per-lane equality test |
| `FMOVS` | Float Move Single | Move 32 bits between FP and GP register |
| `FMOVD` | Float Move Double | Move 64 bits between FP and GP register |
