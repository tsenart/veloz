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

// ============================================================================
// FDR ENGINE: 9-64 patterns using hash table lookup
// ============================================================================
//
// func searchFDR_NEON(
//     haystack string,           // +0(FP): ptr, +8(FP): len
//     stateTable *uint64,        // +16(FP)
//     domainMask uint32,         // +24(FP)
//     stride int,                // +32(FP)
//     verifyValues *[64]uint64,  // +40(FP)
//     verifyMasks *[64]uint64,   // +48(FP)
//     verifyLengths *[64]uint8,  // +56(FP)
//     verifyPtrs *[64]string,    // +64(FP) (unused, for long patterns)
//     numPatterns int,           // +72(FP)
//     minPatternLen int,         // +80(FP)
//     immediateTrueMask uint64,  // +88(FP)
//     immediateFalseMask uint64, // +96(FP)
//     initialFoundMask uint64,   // +104(FP)
// ) uint64                       // +112(FP) return value
//
// Register allocation:
// R0  = haystack ptr
// R1  = haystack len
// R2  = stateTable ptr
// R3  = domainMask (32-bit)
// R4  = stride
// R5  = verifyValues ptr
// R6  = verifyMasks ptr
// R7  = verifyLengths ptr
// R8  = numPatterns
// R9  = immediateTrueMask
// R10 = immediateFalseMask
// R11 = foundMask (accumulator)
// R12 = current position
// R13 = searchLen (haystack_len - 4)
// R14 = allPatternsMask
// R15-R17, R19-R27 = temp (avoid R18 - platform register)

TEXT ·searchFDR_NEON(SB), NOSPLIT, $0-120
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVD  stateTable+16(FP), R2
	MOVW  domainMask+24(FP), R3
	MOVD  stride+32(FP), R4
	MOVD  verifyValues+40(FP), R5
	MOVD  verifyMasks+48(FP), R6
	MOVD  verifyLengths+56(FP), R7
	MOVD  numPatterns+72(FP), R8
	MOVD  immediateTrueMask+88(FP), R9
	MOVD  immediateFalseMask+96(FP), R10
	MOVD  initialFoundMask+104(FP), R11

	// Calculate searchLen = len - 4 (need at least 4 bytes for hash)
	SUB   $4, R1, R13
	CMP   $0, R13
	BLT   fdr_done

	// Setup current position
	MOVD  ZR, R12

	// Calculate allPatternsMask = (1 << numPatterns) - 1
	MOVD  $1, R14
	LSL   R8, R14, R14
	SUB   $1, R14, R14

	// Check stride for loop selection
	CMP   $4, R4
	BEQ   fdr_stride4_loop
	CMP   $2, R4
	BEQ   fdr_stride2_loop
	B     fdr_stride1_loop

// ============================================================================
// FDR STRIDE=1 LOOP: Process every position
// ============================================================================
fdr_stride1_loop:
	CMP   R13, R12
	BGT   fdr_done

	// Load 4 bytes and compute hash
	ADD   R0, R12, R15
	MOVWU (R15), R15                  // R15 = 4 bytes (little-endian)
	AND   R3, R15, R15                // R15 = hash = bytes & domainMask

	// Lookup in state table: candidates = stateTable[hash]
	LSL   $3, R15, R16                // offset = hash * 8
	ADD   R2, R16, R16
	MOVD  (R16), R16                  // R16 = state table entry

	// Invert: 1 bit = candidate (table uses 0 = might match)
	MVN   R16, R16
	BIC   R11, R16, R16               // Remove already-found patterns

	CBZ   R16, fdr_stride1_next

	// Verify each candidate
fdr_s1_verify:
	RBIT  R16, R17
	CLZ   R17, R17                    // R17 = pattern ID (0-63)

	// Check pattern length vs remaining haystack
	ADD   R7, R17, R19
	MOVBU (R19), R19                  // R19 = pattern length
	ADD   R12, R19, R20
	CMP   R1, R20
	BGT   fdr_s1_clear_bit

	// Load 8 bytes from haystack at position
	ADD   R0, R12, R20
	MOVD  (R20), R20                  // R20 = haystack bytes

	// Load verify value and mask
	LSL   $3, R17, R21                // offset = pid * 8
	ADD   R5, R21, R22
	MOVD  (R22), R22                  // R22 = expected value
	ADD   R6, R21, R21
	MOVD  (R21), R21                  // R21 = mask

	// Masked compare
	AND   R21, R20, R20
	CMP   R22, R20
	BNE   fdr_s1_clear_bit

	// For patterns > 8 bytes, need long verification
	CMP   $8, R19
	BGT   fdr_s1_long_verify

	// Pattern matched!
	MOVD  $1, R20
	LSL   R17, R20, R20
	ORR   R20, R11, R11               // foundMask |= (1 << pid)

	// Check immediate termination
	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	// All patterns found?
	CMP   R14, R11
	BEQ   fdr_done

	B     fdr_s1_clear_bit

fdr_s1_long_verify:
	// Long verification for FDR stride=1
	// R12 = position, R17 = pattern ID, R19 = pattern length
	MOVD  verifyPtrs+64(FP), R20
	LSL   $4, R17, R21
	ADD   R20, R21, R20
	MOVD  (R20), R20                  // R20 = pattern string ptr

	ADD   $8, R12, R21
	ADD   R0, R21, R21                // R21 = haystack ptr + pos + 8
	ADD   $8, R20, R20                // R20 = pattern ptr + 8
	SUB   $8, R19, R22                // R22 = remaining bytes

fdr_s1_long_loop:
	CBZ   R22, fdr_s1_long_match

	MOVBU (R21), R23
	MOVBU (R20), R24

	CMPW  R24, R23
	BEQ   fdr_s1_long_next

	SUBW  $'a', R23, R24
	CMPW  $26, R24
	BCS   fdr_s1_clear_bit

	MOVBU (R21), R23
	ANDW  $0xDF, R23, R23
	MOVBU (R20), R24
	CMPW  R24, R23
	BNE   fdr_s1_clear_bit

fdr_s1_long_next:
	ADD   $1, R21, R21
	ADD   $1, R20, R20
	SUB   $1, R22, R22
	B     fdr_s1_long_loop

fdr_s1_long_match:
	MOVD  $1, R20
	LSL   R17, R20, R20
	ORR   R20, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

fdr_s1_clear_bit:
	// Clear this pattern bit and continue
	MOVD  $1, R20
	LSL   R17, R20, R20
	BIC   R20, R16, R16
	CBNZ  R16, fdr_s1_verify

fdr_stride1_next:
	ADD   $1, R12, R12
	B     fdr_stride1_loop

// ============================================================================
// FDR STRIDE=2 LOOP: Process every 2nd position
// ============================================================================
fdr_stride2_loop:
	CMP   R13, R12
	BGT   fdr_done

	// Load 4 bytes and compute hash
	ADD   R0, R12, R15
	MOVWU (R15), R15
	AND   R3, R15, R15

	// Lookup in state table
	LSL   $3, R15, R16
	ADD   R2, R16, R16
	MOVD  (R16), R16

	// Invert and filter
	MVN   R16, R16
	BIC   R11, R16, R16

	CBZ   R16, fdr_stride2_next

	// Verify each candidate
fdr_s2_verify:
	RBIT  R16, R17
	CLZ   R17, R17

	ADD   R7, R17, R19
	MOVBU (R19), R19
	ADD   R12, R19, R20
	CMP   R1, R20
	BGT   fdr_s2_clear_bit

	ADD   R0, R12, R20
	MOVD  (R20), R20

	LSL   $3, R17, R21
	ADD   R5, R21, R22
	MOVD  (R22), R22
	ADD   R6, R21, R21
	MOVD  (R21), R21

	AND   R21, R20, R20
	CMP   R22, R20
	BNE   fdr_s2_clear_bit

	CMP   $8, R19
	BGT   fdr_s2_long_verify

	MOVD  $1, R20
	LSL   R17, R20, R20
	ORR   R20, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	B     fdr_s2_clear_bit

fdr_s2_long_verify:
	// Long verification for FDR stride=2
	MOVD  verifyPtrs+64(FP), R20
	LSL   $4, R17, R21
	ADD   R20, R21, R20
	MOVD  (R20), R20

	ADD   $8, R12, R21
	ADD   R0, R21, R21
	ADD   $8, R20, R20
	SUB   $8, R19, R22

fdr_s2_long_loop:
	CBZ   R22, fdr_s2_long_match

	MOVBU (R21), R23
	MOVBU (R20), R24

	CMPW  R24, R23
	BEQ   fdr_s2_long_next

	SUBW  $'a', R23, R24
	CMPW  $26, R24
	BCS   fdr_s2_clear_bit

	MOVBU (R21), R23
	ANDW  $0xDF, R23, R23
	MOVBU (R20), R24
	CMPW  R24, R23
	BNE   fdr_s2_clear_bit

fdr_s2_long_next:
	ADD   $1, R21, R21
	ADD   $1, R20, R20
	SUB   $1, R22, R22
	B     fdr_s2_long_loop

fdr_s2_long_match:
	MOVD  $1, R20
	LSL   R17, R20, R20
	ORR   R20, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

fdr_s2_clear_bit:
	MOVD  $1, R20
	LSL   R17, R20, R20
	BIC   R20, R16, R16
	CBNZ  R16, fdr_s2_verify

fdr_stride2_next:
	ADD   $2, R12, R12
	B     fdr_stride2_loop

// ============================================================================
// FDR STRIDE=4 LOOP: Process every 4th position (most patterns >=4 bytes)
// This is the most common case and uses batched processing
// ============================================================================
fdr_stride4_loop:
	// Check if we have at least 16 bytes to process in batches of 4 positions
	ADD   $16, R12, R15
	CMP   R13, R15
	BGT   fdr_stride4_single

	// Process 4 positions at once
	ADD   R0, R12, R15

	// Position 0
	MOVWU (R15), R16
	AND   R3, R16, R16
	LSL   $3, R16, R17
	ADD   R2, R17, R17
	MOVD  (R17), R19                  // R19 = candidates pos 0
	MVN   R19, R19
	BIC   R11, R19, R19

	// Position 1 (offset +4)
	MOVWU 4(R15), R16
	AND   R3, R16, R16
	LSL   $3, R16, R17
	ADD   R2, R17, R17
	MOVD  (R17), R20                  // R20 = candidates pos 1
	MVN   R20, R20
	BIC   R11, R20, R20

	// Position 2 (offset +8)
	MOVWU 8(R15), R16
	AND   R3, R16, R16
	LSL   $3, R16, R17
	ADD   R2, R17, R17
	MOVD  (R17), R21                  // R21 = candidates pos 2
	MVN   R21, R21
	BIC   R11, R21, R21

	// Position 3 (offset +12)
	MOVWU 12(R15), R16
	AND   R3, R16, R16
	LSL   $3, R16, R17
	ADD   R2, R17, R17
	MOVD  (R17), R22                  // R22 = candidates pos 3
	MVN   R22, R22
	BIC   R11, R22, R22

	// Quick check: any candidates?
	ORR   R19, R20, R15
	ORR   R21, R22, R16
	ORR   R15, R16, R15
	CBZ   R15, fdr_stride4_batch_next

	// Process position 0 candidates
	CBZ   R19, fdr_s4_pos1
	MOVD  R12, R23                    // R23 = current position

fdr_s4_pos0_verify:
	RBIT  R19, R17
	CLZ   R17, R17

	ADD   R7, R17, R24
	MOVBU (R24), R24
	ADD   R23, R24, R25
	CMP   R1, R25
	BGT   fdr_s4_pos0_clear

	ADD   R0, R23, R25
	MOVD  (R25), R25

	LSL   $3, R17, R26
	ADD   R5, R26, R27
	MOVD  (R27), R27
	ADD   R6, R26, R26
	MOVD  (R26), R26

	AND   R26, R25, R25
	CMP   R27, R25
	BNE   fdr_s4_pos0_clear

	CMP   $8, R24
	BGT   fdr_s4_pos0_long_verify

	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	// After match, also remove from other positions' candidates
	BIC   R25, R20, R20
	BIC   R25, R21, R21
	BIC   R25, R22, R22
	B     fdr_s4_pos0_clear

fdr_s4_pos0_long_verify:
	// Long verification for stride4 position 0
	// R17 = pattern ID, R23 = position, R24 = pattern length
	// Preserve R19-R22 (candidates for other positions)
	MOVD  verifyPtrs+64(FP), R25
	LSL   $4, R17, R26
	ADD   R25, R26, R25
	MOVD  (R25), R25                  // R25 = pattern string ptr

	ADD   $8, R23, R26
	ADD   R0, R26, R26                // R26 = haystack ptr + pos + 8
	ADD   $8, R25, R25                // R25 = pattern ptr + 8
	SUB   $8, R24, R15                // R15 = remaining bytes

fdr_s4_pos0_long_loop:
	CBZ   R15, fdr_s4_pos0_long_match

	MOVBU (R26), R16
	MOVBU (R25), R24

	CMPW  R24, R16
	BEQ   fdr_s4_pos0_long_next

	SUBW  $'a', R16, R24
	CMPW  $26, R24
	BCS   fdr_s4_pos0_clear

	MOVBU (R26), R16
	ANDW  $0xDF, R16, R16
	MOVBU (R25), R24
	CMPW  R24, R16
	BNE   fdr_s4_pos0_clear

fdr_s4_pos0_long_next:
	ADD   $1, R26, R26
	ADD   $1, R25, R25
	SUB   $1, R15, R15
	B     fdr_s4_pos0_long_loop

fdr_s4_pos0_long_match:
	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	// After match, remove from other positions' candidates
	BIC   R25, R20, R20
	BIC   R25, R21, R21
	BIC   R25, R22, R22

fdr_s4_pos0_clear:
	MOVD  $1, R25
	LSL   R17, R25, R25
	BIC   R25, R19, R19
	CBNZ  R19, fdr_s4_pos0_verify

fdr_s4_pos1:
	CBZ   R20, fdr_s4_pos2
	ADD   $4, R12, R23

fdr_s4_pos1_verify:
	RBIT  R20, R17
	CLZ   R17, R17

	ADD   R7, R17, R24
	MOVBU (R24), R24
	ADD   R23, R24, R25
	CMP   R1, R25
	BGT   fdr_s4_pos1_clear

	ADD   R0, R23, R25
	MOVD  (R25), R25

	LSL   $3, R17, R26
	ADD   R5, R26, R27
	MOVD  (R27), R27
	ADD   R6, R26, R26
	MOVD  (R26), R26

	AND   R26, R25, R25
	CMP   R27, R25
	BNE   fdr_s4_pos1_clear

	CMP   $8, R24
	BGT   fdr_s4_pos1_long_verify

	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	BIC   R25, R21, R21
	BIC   R25, R22, R22
	B     fdr_s4_pos1_clear

fdr_s4_pos1_long_verify:
	// Long verification for stride4 position 1
	MOVD  verifyPtrs+64(FP), R25
	LSL   $4, R17, R26
	ADD   R25, R26, R25
	MOVD  (R25), R25

	ADD   $8, R23, R26
	ADD   R0, R26, R26
	ADD   $8, R25, R25
	SUB   $8, R24, R15

fdr_s4_pos1_long_loop:
	CBZ   R15, fdr_s4_pos1_long_match

	MOVBU (R26), R16
	MOVBU (R25), R24

	CMPW  R24, R16
	BEQ   fdr_s4_pos1_long_next

	SUBW  $'a', R16, R24
	CMPW  $26, R24
	BCS   fdr_s4_pos1_clear

	MOVBU (R26), R16
	ANDW  $0xDF, R16, R16
	MOVBU (R25), R24
	CMPW  R24, R16
	BNE   fdr_s4_pos1_clear

fdr_s4_pos1_long_next:
	ADD   $1, R26, R26
	ADD   $1, R25, R25
	SUB   $1, R15, R15
	B     fdr_s4_pos1_long_loop

fdr_s4_pos1_long_match:
	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	BIC   R25, R21, R21
	BIC   R25, R22, R22

fdr_s4_pos1_clear:
	MOVD  $1, R25
	LSL   R17, R25, R25
	BIC   R25, R20, R20
	CBNZ  R20, fdr_s4_pos1_verify

fdr_s4_pos2:
	CBZ   R21, fdr_s4_pos3
	ADD   $8, R12, R23

fdr_s4_pos2_verify:
	RBIT  R21, R17
	CLZ   R17, R17

	ADD   R7, R17, R24
	MOVBU (R24), R24
	ADD   R23, R24, R25
	CMP   R1, R25
	BGT   fdr_s4_pos2_clear

	ADD   R0, R23, R25
	MOVD  (R25), R25

	LSL   $3, R17, R26
	ADD   R5, R26, R27
	MOVD  (R27), R27
	ADD   R6, R26, R26
	MOVD  (R26), R26

	AND   R26, R25, R25
	CMP   R27, R25
	BNE   fdr_s4_pos2_clear

	CMP   $8, R24
	BGT   fdr_s4_pos2_long_verify

	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	BIC   R25, R22, R22
	B     fdr_s4_pos2_clear

fdr_s4_pos2_long_verify:
	// Long verification for stride4 position 2
	MOVD  verifyPtrs+64(FP), R25
	LSL   $4, R17, R26
	ADD   R25, R26, R25
	MOVD  (R25), R25

	ADD   $8, R23, R26
	ADD   R0, R26, R26
	ADD   $8, R25, R25
	SUB   $8, R24, R15

fdr_s4_pos2_long_loop:
	CBZ   R15, fdr_s4_pos2_long_match

	MOVBU (R26), R16
	MOVBU (R25), R24

	CMPW  R24, R16
	BEQ   fdr_s4_pos2_long_next

	SUBW  $'a', R16, R24
	CMPW  $26, R24
	BCS   fdr_s4_pos2_clear

	MOVBU (R26), R16
	ANDW  $0xDF, R16, R16
	MOVBU (R25), R24
	CMPW  R24, R16
	BNE   fdr_s4_pos2_clear

fdr_s4_pos2_long_next:
	ADD   $1, R26, R26
	ADD   $1, R25, R25
	SUB   $1, R15, R15
	B     fdr_s4_pos2_long_loop

fdr_s4_pos2_long_match:
	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

	BIC   R25, R22, R22

fdr_s4_pos2_clear:
	MOVD  $1, R25
	LSL   R17, R25, R25
	BIC   R25, R21, R21
	CBNZ  R21, fdr_s4_pos2_verify

fdr_s4_pos3:
	CBZ   R22, fdr_stride4_batch_next
	ADD   $12, R12, R23

fdr_s4_pos3_verify:
	RBIT  R22, R17
	CLZ   R17, R17

	ADD   R7, R17, R24
	MOVBU (R24), R24
	ADD   R23, R24, R25
	CMP   R1, R25
	BGT   fdr_s4_pos3_clear

	ADD   R0, R23, R25
	MOVD  (R25), R25

	LSL   $3, R17, R26
	ADD   R5, R26, R27
	MOVD  (R27), R27
	ADD   R6, R26, R26
	MOVD  (R26), R26

	AND   R26, R25, R25
	CMP   R27, R25
	BNE   fdr_s4_pos3_clear

	CMP   $8, R24
	BGT   fdr_s4_pos3_long_verify

	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done
	B     fdr_s4_pos3_clear

fdr_s4_pos3_long_verify:
	// Long verification for stride4 position 3
	MOVD  verifyPtrs+64(FP), R25
	LSL   $4, R17, R26
	ADD   R25, R26, R25
	MOVD  (R25), R25

	ADD   $8, R23, R26
	ADD   R0, R26, R26
	ADD   $8, R25, R25
	SUB   $8, R24, R15

fdr_s4_pos3_long_loop:
	CBZ   R15, fdr_s4_pos3_long_match

	MOVBU (R26), R16
	MOVBU (R25), R24

	CMPW  R24, R16
	BEQ   fdr_s4_pos3_long_next

	SUBW  $'a', R16, R24
	CMPW  $26, R24
	BCS   fdr_s4_pos3_clear

	MOVBU (R26), R16
	ANDW  $0xDF, R16, R16
	MOVBU (R25), R24
	CMPW  R24, R16
	BNE   fdr_s4_pos3_clear

fdr_s4_pos3_long_next:
	ADD   $1, R26, R26
	ADD   $1, R25, R25
	SUB   $1, R15, R15
	B     fdr_s4_pos3_long_loop

fdr_s4_pos3_long_match:
	MOVD  $1, R25
	LSL   R17, R25, R25
	ORR   R25, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

fdr_s4_pos3_clear:
	MOVD  $1, R25
	LSL   R17, R25, R25
	BIC   R25, R22, R22
	CBNZ  R22, fdr_s4_pos3_verify

fdr_stride4_batch_next:
	ADD   $16, R12, R12
	B     fdr_stride4_loop

// Single position processing for tail
fdr_stride4_single:
	CMP   R13, R12
	BGT   fdr_done

	ADD   R0, R12, R15
	MOVWU (R15), R15
	AND   R3, R15, R15

	LSL   $3, R15, R16
	ADD   R2, R16, R16
	MOVD  (R16), R16

	MVN   R16, R16
	BIC   R11, R16, R16

	CBZ   R16, fdr_stride4_single_next

fdr_s4_single_verify:
	RBIT  R16, R17
	CLZ   R17, R17

	ADD   R7, R17, R19
	MOVBU (R19), R19
	ADD   R12, R19, R20
	CMP   R1, R20
	BGT   fdr_s4_single_clear

	ADD   R0, R12, R20
	MOVD  (R20), R20

	LSL   $3, R17, R21
	ADD   R5, R21, R22
	MOVD  (R22), R22
	ADD   R6, R21, R21
	MOVD  (R21), R21

	AND   R21, R20, R20
	CMP   R22, R20
	BNE   fdr_s4_single_clear

	CMP   $8, R19
	BGT   fdr_s4_single_long_verify

	MOVD  $1, R20
	LSL   R17, R20, R20
	ORR   R20, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done
	B     fdr_s4_single_clear

fdr_s4_single_long_verify:
	// Long verification for stride4 single tail
	// R17 = pattern ID, R12 = position, R19 = pattern length
	MOVD  verifyPtrs+64(FP), R20
	LSL   $4, R17, R21
	ADD   R20, R21, R20
	MOVD  (R20), R20                  // R20 = pattern string ptr

	ADD   $8, R12, R21
	ADD   R0, R21, R21                // R21 = haystack ptr + pos + 8
	ADD   $8, R20, R20                // R20 = pattern ptr + 8
	SUB   $8, R19, R22                // R22 = remaining bytes

fdr_s4_single_long_loop:
	CBZ   R22, fdr_s4_single_long_match

	MOVBU (R21), R23
	MOVBU (R20), R24

	CMPW  R24, R23
	BEQ   fdr_s4_single_long_next

	SUBW  $'a', R23, R24
	CMPW  $26, R24
	BCS   fdr_s4_single_clear

	MOVBU (R21), R23
	ANDW  $0xDF, R23, R23
	MOVBU (R20), R24
	CMPW  R24, R23
	BNE   fdr_s4_single_clear

fdr_s4_single_long_next:
	ADD   $1, R21, R21
	ADD   $1, R20, R20
	SUB   $1, R22, R22
	B     fdr_s4_single_long_loop

fdr_s4_single_long_match:
	MOVD  $1, R20
	LSL   R17, R20, R20
	ORR   R20, R11, R11

	TST   R9, R11
	BNE   fdr_done
	TST   R10, R11
	BNE   fdr_done

	CMP   R14, R11
	BEQ   fdr_done

fdr_s4_single_clear:
	MOVD  $1, R20
	LSL   R17, R20, R20
	BIC   R20, R16, R16
	CBNZ  R16, fdr_s4_single_verify

fdr_stride4_single_next:
	ADD   $4, R12, R12
	B     fdr_stride4_single

fdr_done:
	MOVD  R11, ret+112(FP)
	RET
