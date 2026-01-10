//go:build !noasm && arm64

// Adaptive NEON case-insensitive substring search
// 
// Strategy:
// 1. Start with 1-byte fast path (36.5 GB/s on clean data)
// 2. Track verification failures in R25
// 3. When failures > 4 + (bytes_scanned >> 10), cut over to 2-byte mode
// 4. 2-byte mode filters on both rare1 AND rare2 (17 GB/s consistent)
//
// This achieves ~35 GB/s on clean workloads and ~17 GB/s on high-FP data.

#include "textflag.h"

// func indexFoldNeedleAdaptive(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleAdaptive(SB), NOSPLIT, $0-72
	MOVD  haystack+0(FP), R0      // R0 = haystack ptr
	MOVD  haystack_len+8(FP), R1  // R1 = haystack len
	MOVBU rare1+16(FP), R2        // R2 = rare1 byte
	MOVD  off1+24(FP), R3         // R3 = off1
	MOVBU rare2+32(FP), R4        // R4 = rare2 byte (save for 2-byte mode)
	MOVD  off2+40(FP), R5         // R5 = off2 (save for 2-byte mode)
	MOVD  norm_needle+48(FP), R6  // R6 = needle ptr
	MOVD  needle_len+56(FP), R7   // R7 = needle len

	// Early exits
	SUBS  R7, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   not_found
	CBZ   R7, found_zero

	// Pre-load case-fold mask to avoid clobbering R27 (REGTMP)
	// 0xDF is not a valid ARM64 logical immediate, so ANDW $0xDF uses R27
	MOVW  $0xDF, R24              // R24 = case-fold mask (used throughout)

	// Compute mask and target for rare1
	ORRW  $0x20, R2, R10
	SUBW  $97, R10, R10
	CMPW  $26, R10
	BCS   not_letter1
	MOVW  $0xDF, R26              // mask for letter
	ANDW  R24, R2, R27            // target (uppercase) - use R24 not immediate
	B     setup_rare1
not_letter1:
	MOVW  $0xFF, R26              // mask = 0xFF (exact match)
	MOVW  R2, R27                 // target = byte itself
setup_rare1:
	VDUP  R26, V0.B16             // V0 = rare1 mask (broadcast)
	VDUP  R27, V1.B16             // V1 = rare1 target (broadcast)

	// Magic constant for syndrome extraction
	MOVD  $0x4010040140100401, R10
	VMOV  R10, V5.D[0]
	VMOV  R10, V5.D[1]

	// Setup pointers
	ADD   R3, R0, R10             // R10 = searchPtr = haystack + off1
	MOVD  R10, R11                // R11 = original searchPtr start
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	// Initialize failure counter
	MOVD  ZR, R25                 // R25 = failure count = 0

	// Need at least 128 bytes for main loop
	CMP   $128, R12
	BLT   loop64_1byte_entry

// ============================================================================
// 1-BYTE FAST PATH: Search for rare1 only (high throughput, may have FPs)
// ============================================================================

loop128_1byte:
	// Load 128 bytes (8 x 16-byte vectors) in two batches
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	VLD1.P 64(R10), [V24.B16, V25.B16, V26.B16, V27.B16]
	SUB   $128, R12, R12

	// Process first 64 bytes (chunks 0-3)
	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VAND  V0.B16, V18.B16, V22.B16
	VAND  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Process second 64 bytes (chunks 4-7)
	VAND  V0.B16, V24.B16, V28.B16
	VAND  V0.B16, V25.B16, V29.B16
	VAND  V0.B16, V26.B16, V30.B16
	VAND  V0.B16, V27.B16, V31.B16
	VCMEQ V1.B16, V28.B16, V28.B16
	VCMEQ V1.B16, V29.B16, V29.B16
	VCMEQ V1.B16, V30.B16, V30.B16
	VCMEQ V1.B16, V31.B16, V31.B16

	// Combine all 8 chunks for quick check
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V7.B16
	VORR  V28.B16, V29.B16, V8.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V7.B16, V6.B16
	VORR  V8.B16, V9.B16, V8.B16
	VORR  V6.B16, V8.B16, V6.B16

	// Fast reduce to check if any matches
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	
	// Early exit: no matches in 128 bytes
	CMP   $128, R12
	BLT   end128_1byte
	CBZ   R13, loop128_1byte      // No matches, continue fast path

end128_1byte:
	// We have potential matches - process each chunk
	// Check first 64 bytes
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, end128_first64_1byte

	// Check second 64 bytes
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, end128_second64_1byte

	// No matches, try next iteration or fall through
	CMP   $128, R12
	BGE   loop128_1byte
	B     loop64_1byte_entry

end128_first64_1byte:
	// Process syndrome for first 64 bytes
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R17
	VMOV  R17, V4.D[0]            // Store block offset in V4 (64 = first block)
	B     check_chunks_1byte

end128_second64_1byte:
	// Process syndrome for second 64 bytes
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	VMOV  ZR, V4.D[0]             // Store block offset in V4 (0 = second block)
	B     check_chunks_1byte

check_chunks_1byte:
	// Check chunk 0
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14                 // chunk offset = 0
	CBNZ  R13, try_match_1byte

	// Check chunk 1
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, try_match_1byte

	// Check chunk 2
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, try_match_1byte

	// Check chunk 3
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, try_match_1byte

	// No matches in this block, check if we should continue with first 64
	VMOV  V4.D[0], R17
	CBNZ  R17, check_second64_after_first
	CMP   $128, R12
	BGE   loop128_1byte
	B     loop64_1byte_entry

check_second64_after_first:
	// We were in first 64, now check second 64
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, continue_1byte_check
	B     end128_second64_1byte

continue_1byte_check:
	CMP   $128, R12
	BGE   loop128_1byte
	B     loop64_1byte_entry

try_match_1byte:
	// R13 = syndrome, R14 = chunk offset, V4.D[0] = block offset
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15            // bit position -> byte position
	ADD   R14, R15, R15           // add chunk offset
	VMOV  V4.D[0], R17
	SUB   R17, R15, R15           // adjust for block (0 or 64)
	ADD   $64, R15, R15           // adjust since second VLD1 was +64

	// Calculate position in haystack
	SUB   $128, R10, R16          // ptr before both loads
	ADD   R15, R16, R16           // ptr to match
	SUB   R11, R16, R16           // offset from searchPtr start

	CMP   R9, R16
	BGT   clear_1byte

	// Verify the match
	ADD   R0, R16, R8             // R8 = &haystack[candidate]
	B     verify_match_1byte

clear_1byte:
	// Clear this bit and try next
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try_match_1byte

	// Move to next chunk
	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   check_next_chunk_1byte
	// Exhausted this block
	VMOV  V4.D[0], R17
	CBNZ  R17, check_second64_after_first
	B     continue_1byte_check

check_next_chunk_1byte:
	CMP   $16, R14
	BEQ   chunk1_1byte
	CMP   $32, R14
	BEQ   chunk2_1byte
	CMP   $48, R14
	BEQ   chunk3_1byte
	B     continue_1byte_check

chunk1_1byte:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try_match_1byte
	ADD   $16, R14, R14
chunk2_1byte:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try_match_1byte
	ADD   $16, R14, R14
chunk3_1byte:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try_match_1byte
	B     continue_1byte_check

verify_match_1byte:
	// Quick checks: first and last byte
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf1a
	ANDW  R24, R17, R17
vnf1a:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   verify_fail_1byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf1b
	ANDW  R24, R17, R17
vnf1b:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   verify_fail_1byte

	// Full verification loop
	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop_1byte:
	CBZ   R20, found
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf1c
	ANDW  R24, R21, R21
vnf1c:
	CMPW  R22, R21
	BNE   verify_fail_1byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop_1byte

verify_fail_1byte:
	// Increment failure counter
	ADD   $1, R25, R25

	// Check threshold: failures > 4 + (bytes_scanned >> 10)
	// bytes_scanned = original_remaining - current_remaining
	// >> 10 means allow ~1 extra failure per 1KB scanned
	SUB   R11, R10, R17           // bytes_scanned = current_ptr - start_ptr
	LSR   $10, R17, R17           // bytes_scanned >> 10
	ADD   $4, R17, R17            // threshold = 4 + (bytes_scanned >> 10)
	CMP   R17, R25
	BGT   setup_2byte_mode        // Too many failures, switch to 2-byte

	// Continue 1-byte search
	B     clear_1byte

// ============================================================================
// 64-BYTE 1-BYTE PATH (for remainder)
// ============================================================================

loop64_1byte_entry:
	CMP   $64, R12
	BLT   loop32_1byte_entry

loop64_1byte:
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	SUB   $64, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VAND  V0.B16, V18.B16, V22.B16
	VAND  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, check64_1byte_continue

	// Process matches in 64 bytes
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16

	// Check chunk 0
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, try64_1byte

	// Check chunk 1
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, try64_1byte

	// Check chunk 2
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, try64_1byte

	// Check chunk 3
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, try64_1byte

check64_1byte_continue:
	CMP   $64, R12
	BGE   loop64_1byte
	B     loop32_1byte_entry

try64_1byte:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15

	SUB   $64, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear64_1byte

	ADD   R0, R16, R8

	// Quick verify
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf64a
	ANDW  R24, R17, R17
vnf64a:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   verify_fail64_1byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf64b
	ANDW  R24, R17, R17
vnf64b:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   verify_fail64_1byte

	// Full verify
	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop64_1byte:
	CBZ   R20, found
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf64c
	ANDW  R24, R21, R21
vnf64c:
	CMPW  R22, R21
	BNE   verify_fail64_1byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop64_1byte

verify_fail64_1byte:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $10, R17, R17
	ADD   $4, R17, R17
	CMP   R17, R25
	BGT   setup_2byte_mode
	B     clear64_1byte

clear64_1byte:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try64_1byte

	// Next chunk
	ADD   $16, R14, R14
	CMP   $64, R14
	BGE   check64_1byte_continue
	CMP   $16, R14
	BEQ   chunk1_64_1byte
	CMP   $32, R14
	BEQ   chunk2_64_1byte
	CMP   $48, R14
	BEQ   chunk3_64_1byte
	B     check64_1byte_continue

chunk1_64_1byte:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try64_1byte
	ADD   $16, R14, R14
chunk2_64_1byte:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try64_1byte
	ADD   $16, R14, R14
chunk3_64_1byte:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try64_1byte
	B     check64_1byte_continue

// ============================================================================
// 32-BYTE 1-BYTE PATH
// ============================================================================

loop32_1byte_entry:
	CMP   $32, R12
	BLT   loop16_1byte_entry

loop32_1byte:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUB   $32, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16

	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, check32_1byte_continue

	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16

	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, try32_1byte

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, try32_1byte

check32_1byte_continue:
	CMP   $32, R12
	BGE   loop32_1byte
	B     loop16_1byte_entry

try32_1byte:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15

	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear32_1byte

	ADD   R0, R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf32a_1
	ANDW  R24, R17, R17
vnf32a_1:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   verify_fail32_1byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf32b_1
	ANDW  R24, R17, R17
vnf32b_1:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   verify_fail32_1byte

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop32_1byte:
	CBZ   R20, found
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf32c_1
	ANDW  R24, R21, R21
vnf32c_1:
	CMPW  R22, R21
	BNE   verify_fail32_1byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop32_1byte

verify_fail32_1byte:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $10, R17, R17
	ADD   $4, R17, R17
	CMP   R17, R25
	BGT   setup_2byte_mode
	B     clear32_1byte

clear32_1byte:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try32_1byte

	CMP   $0, R14
	BNE   check32_1byte_continue
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, try32_1byte
	B     check32_1byte_continue

// ============================================================================
// 16-BYTE 1-BYTE PATH
// ============================================================================

loop16_1byte_entry:
	CMP   $16, R12
	BLT   scalar_1byte_entry

loop16_1byte:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, check16_1byte_continue

try16_1byte:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear16_1byte

	ADD   R0, R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf16a_1
	ANDW  R24, R17, R17
vnf16a_1:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   verify_fail16_1byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf16b_1
	ANDW  R24, R17, R17
vnf16b_1:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   verify_fail16_1byte

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop16_1byte:
	CBZ   R20, found
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf16c_1
	ANDW  R24, R21, R21
vnf16c_1:
	CMPW  R22, R21
	BNE   verify_fail16_1byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop16_1byte

verify_fail16_1byte:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $10, R17, R17
	ADD   $4, R17, R17
	CMP   R17, R25
	BGT   setup_2byte_mode
	B     clear16_1byte

clear16_1byte:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try16_1byte

check16_1byte_continue:
	CMP   $16, R12
	BGE   loop16_1byte

// ============================================================================
// SCALAR 1-BYTE PATH
// ============================================================================

scalar_1byte_entry:
	CMP   $0, R12
	BLE   not_found

scalar_1byte:
	MOVBU (R10), R13
	ANDW  R26, R13, R14
	CMPW  R27, R14
	BNE   scalar_next_1byte

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   scalar_next_1byte

	ADD   R0, R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf1_1
	ANDW  R24, R17, R17
snf1_1:
	MOVBU (R6), R19
	
	// DEBUG: return -2000 - (R17 << 8 | R19) to see what we're comparing
	// MOVD  $-2000, R0
	// LSL   $8, R17, R17
	// ORR   R19, R17, R17
	// SUB   R17, R0, R0
	// MOVD  R0, ret+64(FP)
	// RET
	
	CMPW  R19, R17
	BNE   scalar_fail_1byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf2_1
	ANDW  R24, R17, R17
snf2_1:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   scalar_fail_1byte

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

sloop_1byte:
	CBZ   R20, found
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   snf3_1
	ANDW  R24, R21, R21
snf3_1:
	CMPW  R22, R21
	BNE   scalar_fail_1byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     sloop_1byte

scalar_fail_1byte:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $10, R17, R17
	ADD   $4, R17, R17
	CMP   R17, R25
	BGT   setup_2byte_mode

scalar_next_1byte:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, scalar_1byte
	B     not_found

// ============================================================================
// 2-BYTE MODE SETUP: Restart search using 2-byte filtering from current position
// ============================================================================

setup_2byte_mode:
	// Reload rare2 from stack (R4/R5 may have been clobbered)
	MOVBU rare2+32(FP), R4        // R4 = rare2 byte
	MOVD  off2+40(FP), R5         // R5 = off2

	// Compute mask and target for rare2
	ORRW  $0x20, R4, R17
	SUBW  $97, R17, R17
	CMPW  $26, R17
	BCS   not_letter2
	MOVW  $0xDF, R21              // rare2 mask for letter
	ANDW  R24, R4, R22            // rare2 target (uppercase) - use R24 not immediate
	B     setup_rare2_done
not_letter2:
	MOVW  $0xFF, R21              // rare2 mask = 0xFF
	MOVW  R4, R22                 // rare2 target = byte itself
setup_rare2_done:
	VDUP  R21, V2.B16             // V2 = rare2 mask
	VDUP  R22, V3.B16             // V3 = rare2 target

	// Restart search from beginning in 2-byte mode
	// This is simpler and correct - we only cutover after many failures
	// so re-scanning a small portion is acceptable
	ADD   R3, R0, R10             // R10 = search at off1 (start over)
	MOVD  R10, R11                // R11 = original searchPtr start
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	B     loop64_2byte_entry

// ============================================================================
// 2-BYTE MODE: Filter on BOTH rare1 AND rare2 (consistent 17 GB/s)
// R10 points to haystack + off1 + search_offset (we search at off1 position)
// ============================================================================

loop64_2byte_entry:
	CMP   $64, R12
	BLT   loop16_2byte_entry

loop64_2byte:
	// Load 64 bytes at off1 position (where R10 points)
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	SUB   $64, R12, R12

	// Check rare1 matches first
	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VAND  V0.B16, V18.B16, V22.B16
	VAND  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Quick OR to check if any rare1 matches
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, check64_2byte_continue

	// We have rare1 matches - now load and check rare2 at off2 positions
	// off2 load position: current_ptr - 64 - off1 + off2
	SUB   $64, R10, R16           // back to start of this chunk (at off1)
	SUB   R3, R16, R16            // remove off1 to get haystack position
	ADD   R5, R16, R16            // add off2 to get off2 position
	
	VLD1  (R16), [V24.B16, V25.B16, V26.B16, V27.B16]

	VAND  V2.B16, V24.B16, V28.B16
	VAND  V2.B16, V25.B16, V29.B16
	VAND  V2.B16, V26.B16, V30.B16
	VAND  V2.B16, V27.B16, V31.B16
	VCMEQ V3.B16, V28.B16, V28.B16
	VCMEQ V3.B16, V29.B16, V29.B16
	VCMEQ V3.B16, V30.B16, V30.B16
	VCMEQ V3.B16, V31.B16, V31.B16

	// AND rare1 and rare2 results
	VAND  V20.B16, V28.B16, V20.B16
	VAND  V21.B16, V29.B16, V21.B16
	VAND  V22.B16, V30.B16, V22.B16
	VAND  V23.B16, V31.B16, V23.B16

	// Extract syndrome
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16

	// Check chunk 0
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, try64_2byte

	// Check chunk 1
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, try64_2byte

	// Check chunk 2
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, try64_2byte

	// Check chunk 3
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, try64_2byte

check64_2byte_continue:
	CMP   $64, R12
	BGE   loop64_2byte
	B     loop16_2byte_entry

try64_2byte:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15

	// Position = ptr_after_load - 64 + byte_offset - off1
	// This gives us the haystack position (start of needle candidate)
	SUB   $64, R10, R16
	ADD   R15, R16, R16
	SUB   R3, R16, R16            // adjust from off1 to start of needle

	// Check bounds
	SUB   R0, R16, R17            // position in haystack
	CMP   R9, R17
	BGT   clear64_2byte

	MOVD  R16, R8                 // R8 = candidate haystack ptr

	// Verify match
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf64a_2
	ANDW  R24, R17, R17
vnf64a_2:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   clear64_2byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf64b_2
	ANDW  R24, R17, R17
vnf64b_2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   clear64_2byte

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop64_2byte:
	CBZ   R20, found_2byte
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf64c_2
	ANDW  R24, R21, R21
vnf64c_2:
	CMPW  R22, R21
	BNE   clear64_2byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop64_2byte

found_2byte:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear64_2byte:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try64_2byte

	ADD   $16, R14, R14
	CMP   $64, R14
	BGE   check64_2byte_continue
	CMP   $16, R14
	BEQ   chunk1_64_2byte
	CMP   $32, R14
	BEQ   chunk2_64_2byte
	CMP   $48, R14
	BEQ   chunk3_64_2byte
	B     check64_2byte_continue

chunk1_64_2byte:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try64_2byte
	ADD   $16, R14, R14
chunk2_64_2byte:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try64_2byte
	ADD   $16, R14, R14
chunk3_64_2byte:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try64_2byte
	B     check64_2byte_continue

// ============================================================================
// 16-BYTE 2-BYTE PATH
// ============================================================================

loop16_2byte_entry:
	CMP   $16, R12
	BLT   scalar_2byte_entry

loop16_2byte:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	// Check rare1 first (at current position)
	VAND  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VADDP V20.D2, V20.D2, V20.D2
	VMOV  V20.D[0], R13
	CBZ   R13, check16_2byte_continue

	// Load rare2 position: current_ptr - 16 - off1 + off2
	SUB   $16, R10, R16
	SUB   R3, R16, R16
	ADD   R5, R16, R16
	VLD1  (R16), [V24.B16]

	VAND  V2.B16, V24.B16, V28.B16
	VCMEQ V3.B16, V28.B16, V28.B16

	// AND and extract syndrome
	VAND  V20.B16, V28.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, check16_2byte_continue

try16_2byte:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	// Position = ptr - 16 + byte_offset - off1
	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R3, R16, R16

	SUB   R0, R16, R17
	CMP   R9, R17
	BGT   clear16_2byte

	MOVD  R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf16a_2
	ANDW  R24, R17, R17
vnf16a_2:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   clear16_2byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf16b_2
	ANDW  R24, R17, R17
vnf16b_2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   clear16_2byte

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop16_2byte:
	CBZ   R20, found_2byte
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf16c_2
	ANDW  R24, R21, R21
vnf16c_2:
	CMPW  R22, R21
	BNE   clear16_2byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop16_2byte

clear16_2byte:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try16_2byte

check16_2byte_continue:
	CMP   $16, R12
	BGE   loop16_2byte

// ============================================================================
// SCALAR 2-BYTE PATH
// R10 = current position at off1, R21/R22 = rare2 mask/target
// ============================================================================

scalar_2byte_entry:
	CMP   $0, R12
	BLE   not_found

scalar_2byte:
	// Check rare1 at current position (R10 points to off1 position)
	MOVBU (R10), R13
	ANDW  R26, R13, R14           // R26 = rare1 mask
	CMPW  R27, R14                // R27 = rare1 target
	BNE   scalar_next_2byte

	// Check rare2 at off2 position: current_ptr - off1 + off2
	SUB   R3, R10, R16            // remove off1
	ADD   R5, R16, R16            // add off2
	MOVBU (R16), R14
	// Extract rare2 mask/target from V2/V3 (may have been clobbered in verify)
	VMOV  V2.B[0], R21            // R21 = rare2 mask from V2
	VMOV  V3.B[0], R22            // R22 = rare2 target from V3
	ANDW  R21, R14, R14           // R21 = rare2 mask
	CMPW  R22, R14                // R22 = rare2 target
	BNE   scalar_next_2byte

	// Calculate haystack position = current_ptr - off1
	SUB   R3, R10, R16
	SUB   R0, R16, R17
	CMP   R9, R17
	BGT   scalar_next_2byte

	MOVD  R16, R8

	// Verify
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf1_2
	ANDW  R24, R17, R17
snf1_2:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   scalar_next_2byte

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf2_2
	ANDW  R24, R17, R17
snf2_2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   scalar_next_2byte

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

sloop_2byte:
	CBZ   R20, found_2byte
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   snf3_2
	ANDW  R24, R21, R21
snf3_2:
	CMPW  R22, R21
	BNE   scalar_next_2byte
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     sloop_2byte

scalar_next_2byte:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, scalar_2byte
	B     not_found

// ============================================================================
// COMMON RETURN PATHS
// ============================================================================

found:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+64(FP)
	RET

found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+64(FP)
	RET
