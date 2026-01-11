//go:build !noasm && arm64

// NEON-accelerated FDR engine for 9-64 patterns
//
// Uses TBL prefilter for fast path, then FDR hash confirmation.
// Key insight: TBL lookup gives 8-bit group mask per byte position.
// Group mask is converted to 64-bit pattern mask via precomputed LUT.

#include "textflag.h"

// func searchFDR_NEON(
//     haystack string,           // +0(FP): ptr, +8(FP): len
//     stateTable *uint64,        // +16(FP)
//     domainMask uint32,         // +24(FP)
//     stride int,                // +32(FP)
//     coarseLo *[16]uint8,       // +40(FP) - TBL prefilter tables
//     coarseHi *[16]uint8,       // +48(FP)
//     groupLUT *[256]uint64,     // +56(FP) - 8-bit group mask → 64-bit pattern mask
//     verifyValues *[64]uint64,  // +64(FP)
//     verifyMasks *[64]uint64,   // +72(FP)
//     verifyLengths *[64]uint8,  // +80(FP)
//     verifyPtrs *[64]string,    // +88(FP)
//     numPatterns int,           // +96(FP)
//     minPatternLen int,         // +104(FP)
//     immediateTrueMask uint64,  // +112(FP)
//     immediateFalseMask uint64, // +120(FP)
//     initialFoundMask uint64,   // +128(FP)
// ) uint64                       // +136(FP) return value
//
// Register allocation:
// R0  = haystack ptr
// R1  = haystack len
// R2  = stateTable ptr
// R3  = domainMask (32-bit)
// R4  = groupLUT ptr
// R5  = verifyValues ptr
// R6  = verifyMasks ptr
// R7  = verifyLengths ptr
// R8  = immediateTrueMask
// R9  = immediateFalseMask
// R10 = foundMask (accumulator)
// R11 = current position
// R12 = searchLen (haystack_len - minPatternLen)
// R13 = allPatternsMask
// R14 = stride
// R15-R17, R19-R26 = temp (avoid R18 platform, R27 REGTMP)
//
// Vector registers:
// V0  = coarseLo TBL table
// V1  = coarseHi TBL table
// V2  = 0x0F nibble mask
// V3  = all ones for NOT

TEXT ·searchFDR_NEON(SB), NOSPLIT, $0-144
	// Load parameters
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVD  stateTable+16(FP), R2
	MOVW  domainMask+24(FP), R3
	MOVD  stride+32(FP), R14
	MOVD  coarseLo+40(FP), R15
	MOVD  coarseHi+48(FP), R16
	MOVD  groupLUT+56(FP), R4
	MOVD  verifyValues+64(FP), R5
	MOVD  verifyMasks+72(FP), R6
	MOVD  verifyLengths+80(FP), R7
	MOVD  numPatterns+96(FP), R17
	MOVD  minPatternLen+104(FP), R19
	MOVD  immediateTrueMask+112(FP), R8
	MOVD  immediateFalseMask+120(FP), R9
	MOVD  initialFoundMask+128(FP), R10

	// Calculate searchLen = len - minPatternLen
	SUBS  R19, R1, R12
	BLT   fdr_done

	// Calculate allPatternsMask = (1 << numPatterns) - 1
	MOVD  $1, R13
	LSL   R17, R13, R13
	SUB   $1, R13, R13

	// Setup current position
	MOVD  ZR, R11

	// Load TBL prefilter tables into vector registers
	VLD1  (R15), [V0.B16]              // V0 = coarseLo table
	VLD1  (R16), [V1.B16]              // V1 = coarseHi table

	// Nibble mask constant 0x0F
	MOVD  $0x0F0F0F0F0F0F0F0F, R15
	VMOV  R15, V2.D[0]
	VMOV  R15, V2.D[1]                // V2 = 0x0F nibble mask

	// All-ones vector for NOT operation
	MOVD  $-1, R15
	VMOV  R15, V3.D[0]
	VMOV  R15, V3.D[1]                // V3 = all ones

	// Check if we can do 16-byte chunks with stride 4
	CMP   $4, R14
	BNE   fdr_tail_entry

	// Check if enough bytes for 16-byte chunk
	CMP   $16, R12
	BLT   fdr_tail_entry

// ============================================================================
// MAIN LOOP: Process 16 bytes at a time with TBL prefilter (stride 4)
// ============================================================================
fdr_loop16:
	// Load 16 bytes from haystack
	ADD   R0, R11, R15
	VLD1  (R15), [V16.B16]

	// Extract nibbles
	VAND  V2.B16, V16.B16, V4.B16     // V4 = lo nibbles
	VUSHR $4, V16.B16, V5.B16         // V5 = hi nibbles

	// TBL lookups for coarse group filtering
	VTBL  V4.B16, [V0.B16], V6.B16    // V6 = coarseLo[lo_nibble]
	VTBL  V5.B16, [V1.B16], V7.B16    // V7 = coarseHi[hi_nibble]

	// Combine: 0 bit = group might match (inverted logic)
	VORR  V6.B16, V7.B16, V8.B16

	// Invert: 1 bit = candidate group
	VEOR  V3.B16, V8.B16, V8.B16

	// Quick check: any candidates at all?
	VADDP V8.D2, V8.D2, V9.D2
	VMOV  V9.D[0], R15
	CBZ   R15, fdr_loop16_next

	// Position 0: byte 0
	VMOV  V8.B[0], R16                // R16 = group mask at pos 0
	CBZ   R16, fdr_pos4

	// LUT lookup: group mask → pattern mask
	LSL   $3, R16, R17                // offset = groupMask * 8
	ADD   R4, R17, R17
	MOVD  (R17), R19                  // R19 = pattern mask from LUT

	// FDR hash lookup
	ADD   R0, R11, R15
	MOVWU (R15), R15
	AND   R3, R15, R15
	LSL   $3, R15, R17
	ADD   R2, R17, R17
	MOVD  (R17), R17                  // R17 = state table entry

	// Combine: candidates = ~state & LUT_mask & ~foundMask
	MVN   R17, R17
	AND   R19, R17, R17
	BIC   R10, R17, R17
	CBZ   R17, fdr_pos4

	MOVD  R11, R21                    // R21 = current position

fdr_verify_0:
	RBIT  R17, R19
	CLZ   R19, R19                    // R19 = pattern ID

	ADD   R7, R19, R20
	MOVBU (R20), R20                  // R20 = pattern length
	ADD   R21, R20, R22
	CMP   R1, R22
	BGT   fdr_clear_0

	ADD   R0, R21, R22
	MOVD  (R22), R22                  // R22 = haystack bytes

	LSL   $3, R19, R23
	ADD   R5, R23, R24
	MOVD  (R24), R24                  // expected value
	ADD   R6, R23, R23
	MOVD  (R23), R23                  // mask

	AND   R23, R22, R22
	CMP   R24, R22
	BNE   fdr_clear_0

	CMP   $8, R20
	BGT   fdr_verify_long_0

	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10

	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done
	B     fdr_clear_0

fdr_verify_long_0:
	MOVD  verifyPtrs+88(FP), R22
	LSL   $4, R19, R23
	ADD   R22, R23, R22
	MOVD  (R22), R22

	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R22, R22
	SUB   $8, R20, R23

fdr_long_loop_0:
	CBZ   R23, fdr_long_match_0
	MOVBU (R15), R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BEQ   fdr_long_next_0
	SUBW  $'a', R24, R25
	CMPW  $26, R25
	BCS   fdr_clear_0
	MOVBU (R15), R24
	ANDW  $0xDF, R24, R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BNE   fdr_clear_0

fdr_long_next_0:
	ADD   $1, R15, R15
	ADD   $1, R22, R22
	SUB   $1, R23, R23
	B     fdr_long_loop_0

fdr_long_match_0:
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done

fdr_clear_0:
	MOVD  $1, R22
	LSL   R19, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, fdr_verify_0

fdr_pos4:
	VMOV  V8.B[4], R16
	CBZ   R16, fdr_pos8

	ADD   $4, R11, R21
	CMP   R12, R21
	BGT   fdr_pos8

	LSL   $3, R16, R17
	ADD   R4, R17, R17
	MOVD  (R17), R19

	ADD   R0, R21, R15
	MOVWU (R15), R15
	AND   R3, R15, R15
	LSL   $3, R15, R17
	ADD   R2, R17, R17
	MOVD  (R17), R17

	MVN   R17, R17
	AND   R19, R17, R17
	BIC   R10, R17, R17
	CBZ   R17, fdr_pos8

fdr_verify_4:
	RBIT  R17, R19
	CLZ   R19, R19

	ADD   R7, R19, R20
	MOVBU (R20), R20
	ADD   R21, R20, R22
	CMP   R1, R22
	BGT   fdr_clear_4

	ADD   R0, R21, R22
	MOVD  (R22), R22

	LSL   $3, R19, R23
	ADD   R5, R23, R24
	MOVD  (R24), R24
	ADD   R6, R23, R23
	MOVD  (R23), R23

	AND   R23, R22, R22
	CMP   R24, R22
	BNE   fdr_clear_4

	CMP   $8, R20
	BGT   fdr_verify_long_4

	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done
	B     fdr_clear_4

fdr_verify_long_4:
	MOVD  verifyPtrs+88(FP), R22
	LSL   $4, R19, R23
	ADD   R22, R23, R22
	MOVD  (R22), R22
	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R22, R22
	SUB   $8, R20, R23

fdr_long_loop_4:
	CBZ   R23, fdr_long_match_4
	MOVBU (R15), R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BEQ   fdr_long_next_4
	SUBW  $'a', R24, R25
	CMPW  $26, R25
	BCS   fdr_clear_4
	MOVBU (R15), R24
	ANDW  $0xDF, R24, R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BNE   fdr_clear_4

fdr_long_next_4:
	ADD   $1, R15, R15
	ADD   $1, R22, R22
	SUB   $1, R23, R23
	B     fdr_long_loop_4

fdr_long_match_4:
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done

fdr_clear_4:
	MOVD  $1, R22
	LSL   R19, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, fdr_verify_4

fdr_pos8:
	VMOV  V8.B[8], R16
	CBZ   R16, fdr_pos12

	ADD   $8, R11, R21
	CMP   R12, R21
	BGT   fdr_pos12

	LSL   $3, R16, R17
	ADD   R4, R17, R17
	MOVD  (R17), R19

	ADD   R0, R21, R15
	MOVWU (R15), R15
	AND   R3, R15, R15
	LSL   $3, R15, R17
	ADD   R2, R17, R17
	MOVD  (R17), R17

	MVN   R17, R17
	AND   R19, R17, R17
	BIC   R10, R17, R17
	CBZ   R17, fdr_pos12

fdr_verify_8:
	RBIT  R17, R19
	CLZ   R19, R19

	ADD   R7, R19, R20
	MOVBU (R20), R20
	ADD   R21, R20, R22
	CMP   R1, R22
	BGT   fdr_clear_8

	ADD   R0, R21, R22
	MOVD  (R22), R22

	LSL   $3, R19, R23
	ADD   R5, R23, R24
	MOVD  (R24), R24
	ADD   R6, R23, R23
	MOVD  (R23), R23

	AND   R23, R22, R22
	CMP   R24, R22
	BNE   fdr_clear_8

	CMP   $8, R20
	BGT   fdr_verify_long_8

	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done
	B     fdr_clear_8

fdr_verify_long_8:
	MOVD  verifyPtrs+88(FP), R22
	LSL   $4, R19, R23
	ADD   R22, R23, R22
	MOVD  (R22), R22
	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R22, R22
	SUB   $8, R20, R23

fdr_long_loop_8:
	CBZ   R23, fdr_long_match_8
	MOVBU (R15), R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BEQ   fdr_long_next_8
	SUBW  $'a', R24, R25
	CMPW  $26, R25
	BCS   fdr_clear_8
	MOVBU (R15), R24
	ANDW  $0xDF, R24, R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BNE   fdr_clear_8

fdr_long_next_8:
	ADD   $1, R15, R15
	ADD   $1, R22, R22
	SUB   $1, R23, R23
	B     fdr_long_loop_8

fdr_long_match_8:
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done

fdr_clear_8:
	MOVD  $1, R22
	LSL   R19, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, fdr_verify_8

fdr_pos12:
	VMOV  V8.B[12], R16
	CBZ   R16, fdr_loop16_next

	ADD   $12, R11, R21
	CMP   R12, R21
	BGT   fdr_loop16_next

	LSL   $3, R16, R17
	ADD   R4, R17, R17
	MOVD  (R17), R19

	ADD   R0, R21, R15
	MOVWU (R15), R15
	AND   R3, R15, R15
	LSL   $3, R15, R17
	ADD   R2, R17, R17
	MOVD  (R17), R17

	MVN   R17, R17
	AND   R19, R17, R17
	BIC   R10, R17, R17
	CBZ   R17, fdr_loop16_next

fdr_verify_12:
	RBIT  R17, R19
	CLZ   R19, R19

	ADD   R7, R19, R20
	MOVBU (R20), R20
	ADD   R21, R20, R22
	CMP   R1, R22
	BGT   fdr_clear_12

	ADD   R0, R21, R22
	MOVD  (R22), R22

	LSL   $3, R19, R23
	ADD   R5, R23, R24
	MOVD  (R24), R24
	ADD   R6, R23, R23
	MOVD  (R23), R23

	AND   R23, R22, R22
	CMP   R24, R22
	BNE   fdr_clear_12

	CMP   $8, R20
	BGT   fdr_verify_long_12

	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done
	B     fdr_clear_12

fdr_verify_long_12:
	MOVD  verifyPtrs+88(FP), R22
	LSL   $4, R19, R23
	ADD   R22, R23, R22
	MOVD  (R22), R22
	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R22, R22
	SUB   $8, R20, R23

fdr_long_loop_12:
	CBZ   R23, fdr_long_match_12
	MOVBU (R15), R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BEQ   fdr_long_next_12
	SUBW  $'a', R24, R25
	CMPW  $26, R25
	BCS   fdr_clear_12
	MOVBU (R15), R24
	ANDW  $0xDF, R24, R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BNE   fdr_clear_12

fdr_long_next_12:
	ADD   $1, R15, R15
	ADD   $1, R22, R22
	SUB   $1, R23, R23
	B     fdr_long_loop_12

fdr_long_match_12:
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done

fdr_clear_12:
	MOVD  $1, R22
	LSL   R19, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, fdr_verify_12

fdr_loop16_next:
	ADD   $16, R11, R11
	CMP   R12, R11
	BLE   fdr_loop16

// ============================================================================
// TAIL: Handle remaining positions one at a time
// ============================================================================
fdr_tail_entry:
	CMP   R12, R11
	BGT   fdr_done

fdr_tail_loop:
	// TBL prefilter for single position
	ADD   R0, R11, R15
	MOVBU (R15), R16

	AND   $0x0F, R16, R17
	LSR   $4, R16, R19

	MOVD  coarseLo+40(FP), R20
	ADD   R20, R17, R20
	MOVBU (R20), R17

	MOVD  coarseHi+48(FP), R20
	ADD   R20, R19, R20
	MOVBU (R20), R19

	ORR   R17, R19, R16
	MVN   R16, R16
	AND   $0xFF, R16, R16
	CBZ   R16, fdr_tail_next

	// LUT lookup
	LSL   $3, R16, R17
	ADD   R4, R17, R17
	MOVD  (R17), R19

	// FDR hash lookup
	ADD   R0, R11, R15
	MOVWU (R15), R15
	AND   R3, R15, R15
	LSL   $3, R15, R17
	ADD   R2, R17, R17
	MOVD  (R17), R17

	MVN   R17, R17
	AND   R19, R17, R17
	BIC   R10, R17, R17
	CBZ   R17, fdr_tail_next

	MOVD  R11, R21

fdr_tail_verify:
	RBIT  R17, R19
	CLZ   R19, R19

	ADD   R7, R19, R20
	MOVBU (R20), R20
	ADD   R21, R20, R22
	CMP   R1, R22
	BGT   fdr_tail_clear

	ADD   R0, R21, R22
	MOVD  (R22), R22

	LSL   $3, R19, R23
	ADD   R5, R23, R24
	MOVD  (R24), R24
	ADD   R6, R23, R23
	MOVD  (R23), R23

	AND   R23, R22, R22
	CMP   R24, R22
	BNE   fdr_tail_clear

	CMP   $8, R20
	BGT   fdr_tail_long

	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done
	B     fdr_tail_clear

fdr_tail_long:
	MOVD  verifyPtrs+88(FP), R22
	LSL   $4, R19, R23
	ADD   R22, R23, R22
	MOVD  (R22), R22
	ADD   $8, R21, R15
	ADD   R0, R15, R15
	ADD   $8, R22, R22
	SUB   $8, R20, R23

fdr_tail_long_loop:
	CBZ   R23, fdr_tail_long_match
	MOVBU (R15), R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BEQ   fdr_tail_long_next
	SUBW  $'a', R24, R25
	CMPW  $26, R25
	BCS   fdr_tail_clear
	MOVBU (R15), R24
	ANDW  $0xDF, R24, R24
	MOVBU (R22), R25
	CMPW  R25, R24
	BNE   fdr_tail_clear

fdr_tail_long_next:
	ADD   $1, R15, R15
	ADD   $1, R22, R22
	SUB   $1, R23, R23
	B     fdr_tail_long_loop

fdr_tail_long_match:
	MOVD  $1, R22
	LSL   R19, R22, R22
	ORR   R22, R10, R10
	TST   R8, R10
	BNE   fdr_done
	TST   R9, R10
	BNE   fdr_done
	CMP   R13, R10
	BEQ   fdr_done

fdr_tail_clear:
	MOVD  $1, R22
	LSL   R19, R22, R22
	BIC   R22, R17, R17
	CBNZ  R17, fdr_tail_verify

fdr_tail_next:
	ADD   R14, R11, R11
	CMP   R12, R11
	BLE   fdr_tail_loop

fdr_done:
	MOVD  R10, ret+136(FP)
	RET
