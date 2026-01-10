//go:build !noasm && arm64

// SVE implementation for Graviton 3 (256-bit vectors)
//
// Strategy: Always 2-byte mode (like NEON adaptive 2-byte, but with 256-bit vectors)
// Grounded on ascii_neon_adaptive.s 2-byte path, optimized for SVE:
//
// Key SVE advantages over NEON:
// 1. 256-bit vectors = 2× bytes per instruction (32B vs 16B)
// 2. BRKB+CNTP for position extraction (2 inst vs SHRN+FMOVD+RBIT+CLZ)
// 3. WHILELO for tail handling (no 256-byte mask table)
// 4. Native predicates = results directly in predicates, no syndrome extraction
//
// Performance targets (vs NEON adaptive on G3):
// - Pure scan: ~50-60 GB/s (vs NEON 29 GB/s) - 2× vector width
// - High-FP: ~25-30 GB/s (vs NEON 15-17 GB/s)
//
// Register allocation:
// - R0-R7: function arguments (consumed early)
// - R8-R15: temporaries
// - R16-R17: scratch
// - R19-R25: callee-saved (avoid or save/restore)
// - R27: REGTMP (NEVER USE - Go assembler reserved)
// - R18, R28, R29: platform reserved (NEVER USE)
//
// SVE register allocation:
// - z0-z1: rare1 mask/target
// - z2-z3: rare2 mask/target
// - z4: case-fold constant (#32)
// - z8-z15: data vectors
// - z16-z23: scratch for filtering
// - p0: all-true predicate
// - p1-p7: match predicates

#include "textflag.h"

// func indexFoldNeedleSveG3(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleSveG3(SB), NOSPLIT|NOFRAME, $0-72
	MOVD  haystack+0(FP), R0      // R0 = haystack ptr
	MOVD  haystack_len+8(FP), R1  // R1 = haystack len
	MOVBU rare1+16(FP), R2        // R2 = rare1 byte
	MOVD  off1+24(FP), R3         // R3 = off1
	MOVBU rare2+32(FP), R4        // R4 = rare2 byte
	MOVD  off2+40(FP), R5         // R5 = off2
	MOVD  norm_needle+48(FP), R6  // R6 = needle ptr
	MOVD  needle_len+56(FP), R7   // R7 = needle len

	// Early exits
	SUBS  R7, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   not_found
	CBZ   R7, found_zero

	// Get vector length: rdvl x8, #1 -> R8 = VL in bytes (32 on G3)
	WORD  $0x04bf5028              // rdvl x8, #1

	// Pre-load case-fold mask (0xDF not valid ARM64 logical immediate)
	MOVW  $0xDF, R24              // R24 = case-fold mask

	// Compute mask and target for rare1
	// If letter: mask=0xDF, target=uppercase
	// If non-letter: mask=0xFF, target=byte
	ORRW  $0x20, R2, R10
	SUBW  $97, R10, R10
	CMPW  $26, R10
	BCS   not_letter1
	MOVW  $0xDF, R10              // mask for letter
	ANDW  R24, R2, R11            // target (uppercase)
	B     setup_rare1
not_letter1:
	MOVW  $0xFF, R10              // mask = 0xFF (exact match)
	MOVW  R2, R11                 // target = byte itself
setup_rare1:
	// Broadcast to SVE vectors: mov z0.b, wN
	// Encoding: mov z0.b, w10 = 0x05203940 + (reg << 5)
	WORD  $0x05203940              // mov z0.b, w10 (rare1 mask)
	WORD  $0x05203961              // mov z1.b, w11 (rare1 target)

	// Compute mask and target for rare2
	ORRW  $0x20, R4, R12
	SUBW  $97, R12, R12
	CMPW  $26, R12
	BCS   not_letter2
	MOVW  $0xDF, R12              // mask for letter
	ANDW  R24, R4, R13            // target (uppercase)
	B     setup_rare2
not_letter2:
	MOVW  $0xFF, R12              // mask = 0xFF
	MOVW  R4, R13                 // target = byte itself
setup_rare2:
	WORD  $0x05203982              // mov z2.b, w12 (rare2 mask)
	WORD  $0x052039a3              // mov z3.b, w13 (rare2 target)

	// Case-fold constant for verification: z4.b = #32
	WORD  $0x2538c404              // mov z4.b, #32

	// ptrue p0.b - all-true predicate
	WORD  $0x2518e3e0              // ptrue p0.b

	// Preload first/last needle bytes for quick verification
	MOVBU (R6), R14               // R14 = needle[0] (normalized)
	SUB   $1, R7, R15             // R15 = needleLen - 1
	ADD   R6, R15, R16
	MOVBU (R16), R16              // R16 = needle[needleLen-1] (normalized)

	// Main loop setup
	ADD   $1, R9, R19             // R19 = remaining = searchLen + 1
	MOVD  ZR, R20                 // R20 = i (current position)

	// Compute 4*VL for main loop (128B on G3)
	LSL   $2, R8, R21             // R21 = 4*VL = 128

	// Check if we can do 4x loop
	CMP   R21, R19
	BLT   loop_1x_entry

// ============================================================================
// MAIN LOOP: Process 4*VL bytes per iteration (128B on G3)
// Filters on BOTH rare1 AND rare2 (like NEON 2-byte mode)
// ============================================================================

loop_4x:
	// Base addresses for this iteration
	ADD   R20, R0, R10            // R10 = haystack + i
	ADD   R3, R10, R11            // R11 = haystack + i + off1
	ADD   R5, R10, R12            // R12 = haystack + i + off2

	// Load 4 vectors at off1 position
	// ld1b {z8.b}, p0/z, [x11]
	WORD  $0xa4004168              // ld1b {z8.b}, p0/z, [x11]
	ADD   R8, R11, R11
	WORD  $0xa4004169              // ld1b {z9.b}, p0/z, [x11]
	ADD   R8, R11, R11
	WORD  $0xa400416a              // ld1b {z10.b}, p0/z, [x11]
	ADD   R8, R11, R11
	WORD  $0xa400416b              // ld1b {z11.b}, p0/z, [x11]

	// Load 4 vectors at off2 position
	WORD  $0xa400418c              // ld1b {z12.b}, p0/z, [x12]
	ADD   R8, R12, R12
	WORD  $0xa400418d              // ld1b {z13.b}, p0/z, [x12]
	ADD   R8, R12, R12
	WORD  $0xa400418e              // ld1b {z14.b}, p0/z, [x12]
	ADD   R8, R12, R12
	WORD  $0xa400418f              // ld1b {z15.b}, p0/z, [x12]

	// Filter rare1: AND with mask, CMPEQ with target
	// and z16.d, z8.d, z0.d
	WORD  $0x04203110              // and z16.d, z8.d, z0.d
	WORD  $0x04203131              // and z17.d, z9.d, z0.d
	WORD  $0x04203152              // and z18.d, z10.d, z0.d
	WORD  $0x04203173              // and z19.d, z11.d, z0.d

	// cmpeq p1.b, p0/z, z16.b, z1.b
	WORD  $0x24212201              // cmpeq p1.b, p0/z, z16.b, z1.b
	WORD  $0x24212222              // cmpeq p2.b, p0/z, z17.b, z1.b
	WORD  $0x24212243              // cmpeq p3.b, p0/z, z18.b, z1.b
	WORD  $0x24212264              // cmpeq p4.b, p0/z, z19.b, z1.b

	// Filter rare2: AND with mask, CMPEQ with target
	WORD  $0x04223194              // and z20.d, z12.d, z2.d
	WORD  $0x042231b5              // and z21.d, z13.d, z2.d
	WORD  $0x042231d6              // and z22.d, z14.d, z2.d
	WORD  $0x042231f7              // and z23.d, z15.d, z2.d

	// cmpeq p5.b, p0/z, z20.b, z3.b
	WORD  $0x24232285              // cmpeq p5.b, p0/z, z20.b, z3.b
	WORD  $0x242322a6              // cmpeq p6.b, p0/z, z21.b, z3.b
	WORD  $0x242322c7              // cmpeq p7.b, p0/z, z22.b, z3.b
	// Need p for z23, reuse after AND

	// Combine: AND rare1 and rare2 predicates
	// ands p1.b, p0/z, p1.b, p5.b (sets flags)
	WORD  $0x25454021              // ands p1.b, p0/z, p1.b, p5.b
	BNE   found_match_v0

	WORD  $0x25464042              // ands p2.b, p0/z, p2.b, p6.b
	BNE   found_match_v1

	WORD  $0x25474063              // ands p3.b, p0/z, p3.b, p7.b
	BNE   found_match_v2

	// For v3: compute p7 for z23, then AND with p4
	WORD  $0x242322e7              // cmpeq p7.b, p0/z, z23.b, z3.b
	WORD  $0x25474084              // ands p4.b, p0/z, p4.b, p7.b
	BNE   found_match_v3

	// No matches in 4*VL bytes, advance
	ADD   R21, R20, R20           // i += 4*VL
	SUB   R21, R19, R19           // remaining -= 4*VL
	CMP   R21, R19
	BGE   loop_4x

	// Fall through to 1x loop
	B     loop_1x_entry

// ============================================================================
// 1x LOOP: Process 1*VL bytes per iteration
// ============================================================================

loop_1x_entry:
	CMP   R8, R19
	BLT   loop_tail

loop_1x:
	ADD   R20, R0, R10            // R10 = haystack + i
	ADD   R3, R10, R11            // R11 = off1 ptr
	ADD   R5, R10, R12            // R12 = off2 ptr

	// Load at off1 and off2
	WORD  $0xa4004168              // ld1b {z8.b}, p0/z, [x11]
	WORD  $0xa400418c              // ld1b {z12.b}, p0/z, [x12]

	// Filter rare1
	WORD  $0x04203110              // and z16.d, z8.d, z0.d
	WORD  $0x24212201              // cmpeq p1.b, p0/z, z16.b, z1.b

	// Filter rare2
	WORD  $0x04223194              // and z20.d, z12.d, z2.d
	WORD  $0x24232285              // cmpeq p5.b, p0/z, z20.b, z3.b

	// Combine
	WORD  $0x25454021              // ands p1.b, p0/z, p1.b, p5.b
	BNE   found_match_1x

advance_1x:
	ADD   R8, R20, R20            // i += VL
	SUB   R8, R19, R19            // remaining -= VL
	CMP   R8, R19
	BGE   loop_1x

// ============================================================================
// TAIL: Process remaining bytes with WHILELO (no mask table!)
// ============================================================================

loop_tail:
	CBZ   R19, not_found

	// whilelo p1.b, xzr, x19 - generate predicate for remaining bytes
	WORD  $0x25381fe1              // whilelo p1.b, xzr, x19

	ADD   R20, R0, R10
	ADD   R3, R10, R11
	ADD   R5, R10, R12

	// Predicated loads
	WORD  $0xa4004568              // ld1b {z8.b}, p1/z, [x11]
	WORD  $0xa400458c              // ld1b {z12.b}, p1/z, [x12]

	// Filter with governing predicate p1
	WORD  $0x04203110              // and z16.d, z8.d, z0.d
	WORD  $0x24212441              // cmpeq p2.b, p1/z, z16.b, z1.b

	WORD  $0x04223194              // and z20.d, z12.d, z2.d
	WORD  $0x24234485              // cmpeq p5.b, p1/z, z20.b, z3.b

	// Combine: ands with p1 governing
	WORD  $0x25454442              // ands p2.b, p1/z, p2.b, p5.b
	BNE   found_match_tail

	B     not_found

// ============================================================================
// MATCH HANDLERS: Extract position using BRKB+CNTP, verify
// ============================================================================

found_match_v0:
	MOVD  ZR, R17                 // offset = 0
	B     extract_and_verify

found_match_v1:
	MOVD  R8, R17                 // offset = VL
	WORD  $0x05c14041              // mov p1.b, p2.b
	B     extract_and_verify

found_match_v2:
	LSL   $1, R8, R17             // offset = 2*VL
	WORD  $0x05c14061              // mov p1.b, p3.b
	B     extract_and_verify

found_match_v3:
	ADD   R8, R8, R17
	ADD   R8, R17, R17            // offset = 3*VL
	WORD  $0x05c14081              // mov p1.b, p4.b
	B     extract_and_verify

found_match_1x:
	MOVD  ZR, R17                 // offset = 0
	B     extract_and_verify

found_match_tail:
	MOVD  ZR, R17                 // offset = 0
	WORD  $0x05c14041              // mov p1.b, p2.b
	// Save p1 governing mask for tail
	MOVD  R19, R22                // R22 = remaining (for tail verify)
	B     extract_and_verify

extract_and_verify:
	// Use BRKB + CNTP to find first match position
	// brkb p2.b, p0/z, p1.b - break after first true
	WORD  $0x25904022              // brkb p2.b, p0/z, p1.b
	// cntp x10, p0, p2.b - count preceding elements
	WORD  $0x252080ca              // cntp x10, p0, p2.b

	// Total position = i + offset + pos_in_vec
	ADD   R20, R17, R11           // R11 = i + offset
	ADD   R10, R11, R11           // R11 = i + offset + pos = candidate

	// Bounds check
	CMP   R9, R11
	BGT   clear_and_continue

	// Candidate pointer
	ADD   R0, R11, R10            // R10 = &haystack[candidate]

	// Quick check first byte (case-fold and compare)
	MOVBU (R10), R12
	SUBW  $97, R12, R13
	CMPW  $26, R13
	BCS   qc1_not_letter
	ANDW  R24, R12, R12           // case-fold to upper
qc1_not_letter:
	CMPW  R14, R12                // R14 = needle[0]
	BNE   clear_and_continue

	// Quick check last byte
	ADD   R7, R10, R12
	SUB   $1, R12
	MOVBU (R12), R12
	SUBW  $97, R12, R13
	CMPW  $26, R13
	BCS   qc2_not_letter
	ANDW  R24, R12, R12
qc2_not_letter:
	CMPW  R16, R12                // R16 = needle[last]
	BNE   clear_and_continue

	// Full SVE vectorized verification
	MOVD  R10, R12                // R12 = haystack ptr
	MOVD  R6, R13                 // R13 = needle ptr
	MOVD  R7, R22                 // R22 = remaining length

verify_loop:
	CMP   R8, R22
	BLT   verify_tail

	// Load VL bytes from haystack and needle
	WORD  $0xa400a188              // ld1b {z8.b}, p0/z, [x12]
	WORD  $0xa400a1a9              // ld1b {z9.b}, p0/z, [x13]

	// Normalize haystack: if 'a'<=c<='z', XOR with 32
	// cmphs p2.b, p0/z, z8.b, #97 (>= 'a')
	WORD  $0x24384102              // cmphs p2.b, p0/z, z8.b, #97
	// cmpls p3.b, p0/z, z8.b, #122 (<= 'z')
	WORD  $0x243ea103              // cmpls p3.b, p0/z, z8.b, #122
	// and p2.b, p0/z, p2.b, p3.b (is_letter)
	WORD  $0x25034042              // and p2.b, p0/z, p2.b, p3.b
	// eor z8.b, p2/m, z8.b, z4.b (flip case where is_letter)
	WORD  $0x04840908              // eor z8.b, p2/m, z8.b, z4.b

	// Compare with needle: XOR to find differences
	WORD  $0x04a83108              // eor z8.d, z8.d, z9.d

	// Check if any non-zero
	WORD  $0x25008102              // cmpne p2.b, p0/z, z8.b, #0
	WORD  $0x25c24042              // orrs p2.b, p0/z, p2.b, p2.b
	BNE   clear_and_continue

	// Advance
	ADD   R8, R12, R12
	ADD   R8, R13, R13
	SUB   R8, R22, R22
	B     verify_loop

verify_tail:
	CBZ   R22, found

	// whilelo p2.b, xzr, x22
	WORD  $0x25381fd6              // whilelo p2.b, xzr, x22 (use x22 = R22)

	WORD  $0xa400a588              // ld1b {z8.b}, p2/z, [x12]
	WORD  $0xa400a5a9              // ld1b {z9.b}, p2/z, [x13]

	// Same case-fold + compare, governed by p2
	WORD  $0x24384502              // cmphs p2.b, p2/z, z8.b, #97
	WORD  $0x243ea543              // cmpls p3.b, p2/z, z8.b, #122
	WORD  $0x25034542              // and p2.b, p2/z, p2.b, p3.b
	WORD  $0x04840908              // eor z8.b, p2/m, z8.b, z4.b
	WORD  $0x04a83108              // eor z8.d, z8.d, z9.d

	// Reload tail mask and check
	WORD  $0x25381fd6              // whilelo p2.b, xzr, x22
	WORD  $0x25008542              // cmpne p2.b, p2/z, z8.b, #0
	WORD  $0x25c24042              // orrs p2.b, p0/z, p2.b, p2.b
	BNE   clear_and_continue

found:
	// Return position: candidate is in R11
	MOVD  R11, R0
	MOVD  R0, ret+64(FP)
	RET

clear_and_continue:
	// Clear first match from p1 and try next
	// brka p2.b, p0/z, p1.b - break at first true (inclusive)
	WORD  $0x25104022              // brka p2.b, p0/z, p1.b
	// bics p1.b, p0/z, p1.b, p2.b - clear first match
	WORD  $0x25424031              // bics p1.b, p0/z, p1.b, p2.b
	BNE   extract_and_verify

	// Exhausted this vector, continue to next
	ADD   R8, R20, R20
	SUB   R8, R19, R19
	CMP   R8, R19
	BGE   loop_1x
	B     loop_tail

not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+64(FP)
	RET

found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+64(FP)
	RET
