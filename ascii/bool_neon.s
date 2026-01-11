//go:build !noasm && arm64

// NEON-accelerated multi-needle boolean substring search
//
// This file implements the Direct TBL engine for 1-8 patterns.
// Uses nibble-based TBL lookups to filter candidate positions,
// then verifies matches using masked 8-byte comparisons.

#include "textflag.h"

// func searchTBL_NEON(
//     haystack string,           // +0(FP): ptr, +8(FP): len
//     masksLo *[16]uint8,        // +16(FP)
//     masksHi *[16]uint8,        // +24(FP)
//     verifyValues *[64]uint64,  // +32(FP)
//     verifyMasks *[64]uint64,   // +40(FP)
//     verifyLengths *[64]uint8,  // +48(FP)
//     verifyPtrs *[64]string,    // +56(FP) (unused, for long patterns)
//     numPatterns int,           // +64(FP)
//     minPatternLen int,         // +72(FP)
//     immediateTrueMask uint64,  // +80(FP)
//     immediateFalseMask uint64, // +88(FP)
//     initialFoundMask uint64,   // +96(FP)
// ) uint64                       // +104(FP) return value
//
// Register allocation:
// R0  = haystack ptr
// R1  = haystack len
// R2  = masksLo ptr
// R3  = masksHi ptr
// R4  = verifyValues ptr
// R5  = verifyMasks ptr
// R6  = verifyLengths ptr
// R7  = numPatterns
// R8  = minPatternLen
// R9  = immediateTrueMask
// R10 = immediateFalseMask
// R11 = foundMask (accumulator)
// R12 = searchLen
// R13 = current position
// R14 = allPatternsMask
// R15 = temp
// R16, R17, R19-R27 = temp (avoid R18 - platform register)

TEXT ·searchTBL_NEON(SB), NOSPLIT, $0-112
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVD  masksLo+16(FP), R2
	MOVD  masksHi+24(FP), R3
	MOVD  verifyValues+32(FP), R4
	MOVD  verifyMasks+40(FP), R5
	MOVD  verifyLengths+48(FP), R6
	MOVD  numPatterns+64(FP), R7
	MOVD  minPatternLen+72(FP), R8
	MOVD  immediateTrueMask+80(FP), R9
	MOVD  immediateFalseMask+88(FP), R10
	MOVD  initialFoundMask+96(FP), R11

	// Calculate searchLen = len - minPatternLen
	SUBS  R8, R1, R12
	BLT   done

	// Setup current position
	MOVD  ZR, R13

	// Calculate allPatternsMask = (1 << numPatterns) - 1
	MOVD  $1, R14
	LSL   R7, R14, R14
	SUB   $1, R14, R14

	// Load TBL masks into vector registers
	VLD1  (R2), [V0.B16]              // V0 = masksLo table
	VLD1  (R3), [V1.B16]              // V1 = masksHi table

	// Nibble mask constant 0x0F
	MOVD  $0x0F0F0F0F0F0F0F0F, R15
	VMOV  R15, V2.D[0]
	VMOV  R15, V2.D[1]                // V2 = 0x0F nibble mask

	// All-ones vector for NOT operation (XOR with this = NOT)
	MOVD  $-1, R15
	VMOV  R15, V10.D[0]
	VMOV  R15, V10.D[1]               // V10 = all ones

	// Check if we can do 16-byte chunks
	ADD   $1, R12, R16                // R16 = remaining = searchLen + 1
	CMP   $16, R16
	BLT   scalar_entry

// ============================================================================
// VECTORIZED 16-BYTE LOOP
// ============================================================================
loop16:
	// Load 16 bytes from haystack[pos]
	ADD   R0, R13, R17
	VLD1  (R17), [V16.B16]

	// Extract nibbles
	VAND  V2.B16, V16.B16, V3.B16     // V3 = lo nibbles
	VUSHR $4, V16.B16, V4.B16         // V4 = hi nibbles

	// TBL lookups
	VTBL  V3.B16, [V0.B16], V5.B16    // V5 = masksLo[lo_nibble]
	VTBL  V4.B16, [V1.B16], V6.B16    // V6 = masksHi[hi_nibble]

	// Combine: 0 bit = pattern might match
	VORR  V5.B16, V6.B16, V7.B16

	// Invert using XOR with all-ones: 1 bit = candidate
	VEOR  V10.B16, V7.B16, V7.B16

	// Quick check: any candidates?
	VADDP V7.D2, V7.D2, V8.D2
	VMOV  V8.D[0], R17
	CBZ   R17, loop16_next

	// We have candidates - process each byte position
	// V7 contains candidate mask per byte

	// Process bytes 0-7 (low 64 bits)
	VMOV  V7.D[0], R17
	MOVD  R13, R19                    // R19 = base position
	CBZ   R17, process_hi

process_lo:
	// Find first set byte in R17
	RBIT  R17, R20
	CLZ   R20, R20
	LSR   $3, R20, R20                // R20 = byte offset (0-7)

	// Calculate position
	ADD   R19, R20, R21               // R21 = haystack position

	// Check bounds
	CMP   R12, R21
	BGT   clear_lo_byte

	// Get candidate patterns for this byte
	LSL   $3, R20, R22                // bit offset
	LSR   R22, R17, R23               // shift to get this byte's candidates
	AND   $0xFF, R23, R23             // R23 = candidates for this byte
	BIC   R11, R23, R23               // remove already found

	CBZ   R23, clear_lo_byte

	// Verify each candidate pattern
verify_lo:
	RBIT  R23, R24
	CLZ   R24, R24                    // R24 = pattern ID (0-7)

	// Check pattern length vs remaining haystack
	ADD   R6, R24, R25
	MOVBU (R25), R25                  // R25 = pattern length
	ADD   R21, R25, R26
	CMP   R1, R26
	BGT   clear_lo_bit

	// Load 8 bytes from haystack at position
	ADD   R0, R21, R26
	MOVD  (R26), R26                  // R26 = haystack bytes

	// Load verify value and mask
	LSL   $3, R24, R27                // offset = pid * 8
	ADD   R4, R27, R15
	MOVD  (R15), R15                  // R15 = expected value
	ADD   R5, R27, R27
	MOVD  (R27), R27                  // R27 = mask

	// Masked compare
	AND   R27, R26, R26
	CMP   R15, R26
	BNE   clear_lo_bit

	// For patterns > 8 bytes, do extended verification
	CMP   $8, R25
	BGT   verify_lo_long

	// Pattern matched!
	MOVD  $1, R26
	LSL   R24, R26, R26
	ORR   R26, R11, R11               // foundMask |= (1 << pid)

	// Check immediate termination
	TST   R9, R11
	BNE   done
	TST   R10, R11
	BNE   done

	// All patterns found?
	CMP   R14, R11
	BEQ   done

	B     lo_match_done

verify_lo_long:
	// Long pattern verification (>8 bytes)
	// R21 = haystack position, R24 = pattern ID, R25 = pattern length
	// First 8 bytes already matched. Now check bytes 8 onwards.
	//
	// Load pattern string from verifyPtrs[pid]
	// verifyPtrs is [64]string, each string is 16 bytes (ptr + len)
	MOVD  verifyPtrs+56(FP), R26      // R26 = verifyPtrs base
	LSL   $4, R24, R27                // offset = pid * 16
	ADD   R26, R27, R26               // R26 = &verifyPtrs[pid]
	MOVD  (R26), R26                  // R26 = pattern string ptr (already uppercase normalized)

	// Setup comparison loop
	// Use end pointer instead of counter to avoid R27 (REGTMP) clobbering
	ADD   $8, R21, R15                // R15 = haystack position + 8
	ADD   R0, R15, R15                // R15 = haystack ptr + position + 8
	ADD   $8, R26, R26                // R26 = pattern ptr + 8 (skip first 8 bytes)
	ADD   R25, R15, R25               // R25 = end ptr = haystack ptr + pos + patternLen
	SUB   $8, R25, R25                // adjust for already-compared 8 bytes

verify_lo_long_loop:
	CMP   R25, R15
	BEQ   lo_match_success            // All bytes matched

	// Load bytes from haystack and pattern
	// Must preserve: R16 (remaining), R19 (base pos), R20 (byte offset), R21 (position), R23 (candidates)
	// Use R22 for haystack byte, load pattern byte directly to compare via subtraction
	MOVBU (R15), R22                  // haystack byte
	MOVBU (R26), R27                  // pattern byte (REGTMP, but used immediately)

	// Case-insensitive comparison
	// Pattern is already uppercase. Haystack byte needs case-folding.
	CMPW  R27, R22
	BEQ   verify_lo_long_next

	// Try case-folding: if haystack byte is lowercase, convert to uppercase
	SUBW  $'a', R22, R27              // check if lowercase
	CMPW  $26, R27
	BCS   clear_lo_bit                // Not a letter, mismatch

	// Convert to uppercase and compare - pattern byte known to be uppercase
	// haystack byte needs bit 5 cleared, then compare
	// NOTE: ANDW with immediate uses R27 (REGTMP), so do AND first, then load pattern byte
	ANDW  $0xDF, R22, R22             // Clear bit 5 (uppercase)
	MOVBU (R26), R27                  // reload pattern byte (after AND!)
	CMPW  R27, R22
	BNE   clear_lo_bit                // Mismatch

verify_lo_long_next:
	ADD   $1, R15, R15
	ADD   $1, R26, R26
	B     verify_lo_long_loop

lo_match_success:
	// Pattern matched! Reload pattern ID and set bit
	// R24 still holds pattern ID
	MOVD  $1, R26
	LSL   R24, R26, R26
	ORR   R26, R11, R11               // foundMask |= (1 << pid)

	// Check immediate termination
	TST   R9, R11
	BNE   done
	TST   R10, R11
	BNE   done

	// All patterns found?
	CMP   R14, R11
	BEQ   done

lo_match_done:

clear_lo_bit:
	// Clear this pattern bit and continue
	MOVD  $1, R26
	LSL   R24, R26, R26
	BIC   R26, R23, R23
	CBNZ  R23, verify_lo

clear_lo_byte:
	// Clear this byte's bits and check for more bytes
	MOVD  $0xFF, R22
	LSL   $3, R20, R24
	LSL   R24, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, process_lo

process_hi:
	// Process bytes 8-15 (high 64 bits)
	VMOV  V7.D[1], R17
	ADD   $8, R19, R19                // adjust base position
	CBZ   R17, loop16_next

process_hi_loop:
	RBIT  R17, R20
	CLZ   R20, R20
	LSR   $3, R20, R20                // byte offset (0-7, add 8 for actual position)

	ADD   R19, R20, R21               // haystack position

	CMP   R12, R21
	BGT   clear_hi_byte

	LSL   $3, R20, R22
	LSR   R22, R17, R23
	AND   $0xFF, R23, R23
	BIC   R11, R23, R23

	CBZ   R23, clear_hi_byte

verify_hi:
	RBIT  R23, R24
	CLZ   R24, R24

	ADD   R6, R24, R25
	MOVBU (R25), R25
	ADD   R21, R25, R26
	CMP   R1, R26
	BGT   clear_hi_bit

	ADD   R0, R21, R26
	MOVD  (R26), R26

	LSL   $3, R24, R27
	ADD   R4, R27, R15
	MOVD  (R15), R15
	ADD   R5, R27, R27
	MOVD  (R27), R27

	AND   R27, R26, R26
	CMP   R15, R26
	BNE   clear_hi_bit

	CMP   $8, R25
	BGT   verify_hi_long

	MOVD  $1, R26
	LSL   R24, R26, R26
	ORR   R26, R11, R11

	TST   R9, R11
	BNE   done
	TST   R10, R11
	BNE   done

	CMP   R14, R11
	BEQ   done

	B     hi_match_done

verify_hi_long:
	// Long pattern verification (>8 bytes) for hi bytes
	// R21 = haystack position, R24 = pattern ID, R25 = pattern length
	MOVD  verifyPtrs+56(FP), R26
	LSL   $4, R24, R27
	ADD   R26, R27, R26
	MOVD  (R26), R26

	// Use end pointer instead of counter to avoid R27 (REGTMP) clobbering
	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R26, R26
	ADD   R25, R15, R25               // R25 = end ptr
	SUB   $8, R25, R25

verify_hi_long_loop:
	CMP   R25, R15
	BEQ   hi_match_success

	// Must preserve: R16 (remaining), R19 (base pos), R20 (byte offset), R21 (position), R23 (candidates)
	// Use R22 for haystack byte, R27 (REGTMP) for pattern byte
	MOVBU (R15), R22                  // haystack byte
	MOVBU (R26), R27                  // pattern byte (REGTMP, used immediately)

	CMPW  R27, R22
	BEQ   verify_hi_long_next

	SUBW  $'a', R22, R27              // check if lowercase
	CMPW  $26, R27
	BCS   clear_hi_bit                // Not a letter, mismatch

	// NOTE: ANDW with immediate uses R27 (REGTMP), so do AND first, then load pattern byte
	ANDW  $0xDF, R22, R22             // Clear bit 5 (uppercase)
	MOVBU (R26), R27                  // reload pattern byte (after AND!)
	CMPW  R27, R22
	BNE   clear_hi_bit

verify_hi_long_next:
	ADD   $1, R15, R15
	ADD   $1, R26, R26
	B     verify_hi_long_loop

hi_match_success:
	MOVD  $1, R26
	LSL   R24, R26, R26
	ORR   R26, R11, R11

	TST   R9, R11
	BNE   done
	TST   R10, R11
	BNE   done

	CMP   R14, R11
	BEQ   done

hi_match_done:

clear_hi_bit:
	MOVD  $1, R26
	LSL   R24, R26, R26
	BIC   R26, R23, R23
	CBNZ  R23, verify_hi

clear_hi_byte:
	MOVD  $0xFF, R22
	LSL   $3, R20, R24
	LSL   R24, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, process_hi_loop

loop16_next:
	ADD   $16, R13, R13
	SUB   $16, R16, R16
	CMP   $16, R16
	BGE   loop16

// ============================================================================
// SCALAR LOOP: Handle remaining bytes one at a time
// ============================================================================
scalar_entry:
	CMP   $0, R16
	BLE   done

scalar_loop:
	// Load byte
	ADD   R0, R13, R17
	MOVBU (R17), R17                  // R17 = haystack byte

	// Nibble lookup
	AND   $0x0F, R17, R19             // lo nibble
	LSR   $4, R17, R20                // hi nibble

	ADD   R2, R19, R21
	MOVBU (R21), R19                  // masksLo[lo]
	ADD   R3, R20, R21
	MOVBU (R21), R20                  // masksHi[hi]

	ORR   R19, R20, R17
	MVN   R17, R17
	AND   $0xFF, R17, R17             // candidates
	BIC   R11, R17, R17               // remove found

	CBZ   R17, scalar_next

	// Current position
	MOVD  R13, R21

verify_scalar:
	RBIT  R17, R19
	CLZ   R19, R19                    // R19 = pattern ID

	// Bounds check
	ADD   R6, R19, R20
	MOVBU (R20), R20                  // pattern length
	ADD   R21, R20, R22
	CMP   R1, R22
	BGT   clear_scalar_bit

	// Load and verify
	ADD   R0, R21, R22
	MOVD  (R22), R22                  // haystack bytes

	LSL   $3, R19, R23
	ADD   R4, R23, R24
	MOVD  (R24), R24                  // expected
	ADD   R5, R23, R23
	MOVD  (R23), R23                  // mask

	AND   R23, R22, R22
	CMP   R24, R22
	BNE   clear_scalar_bit

	CMP   $8, R20
	BGT   verify_scalar_long

	// Match!
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R11, R11

	TST   R9, R11
	BNE   done
	TST   R10, R11
	BNE   done

	CMP   R14, R11
	BEQ   done

	B     scalar_match_done

verify_scalar_long:
	// Long pattern verification for scalar loop
	// R21 = haystack position, R19 = pattern ID, R20 = pattern length
	MOVD  verifyPtrs+56(FP), R22
	LSL   $4, R19, R23
	ADD   R22, R23, R22
	MOVD  (R22), R22                  // R22 = pattern string ptr

	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R22, R22
	SUB   $8, R20, R23

verify_scalar_long_loop:
	CBZ   R23, scalar_match_success

	MOVBU (R15), R24
	MOVBU (R22), R25

	CMPW  R25, R24
	BEQ   verify_scalar_long_next

	SUBW  $'a', R24, R25
	CMPW  $26, R25
	BCS   clear_scalar_bit

	MOVBU (R15), R24
	ANDW  $0xDF, R24, R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BNE   clear_scalar_bit

verify_scalar_long_next:
	ADD   $1, R15, R15
	ADD   $1, R22, R22
	SUB   $1, R23, R23
	B     verify_scalar_long_loop

scalar_match_success:
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R11, R11

	TST   R9, R11
	BNE   done
	TST   R10, R11
	BNE   done

	CMP   R14, R11
	BEQ   done

scalar_match_done:

clear_scalar_bit:
	MOVD  $1, R22
	LSL   R19, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, verify_scalar

scalar_next:
	ADD   $1, R13, R13
	SUB   $1, R16, R16
	CBNZ  R16, scalar_loop

done:
	MOVD  R11, ret+104(FP)
	RET
