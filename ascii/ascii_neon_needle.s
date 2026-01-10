//go:build !noasm && arm64

// Adaptive NEON case-insensitive substring search
// 
// Strategy:
// 1. Start with 1-byte fast path (high throughput, ~80-90% of strings.Index)
// 2. Track verification failures in R25
// 3. When failures > 4 + (bytes_scanned >> 8), cut over to 2-byte mode
// 4. 2-byte mode filters on both rare1 AND rare2 (consistent, ~50% of pure scan)
//
// Performance characteristics (vs case-sensitive strings.Index):
// - Pure scan (no match): ~80-90% of strings.Index speed
// - High false-positive: 6-10x faster than strings.Index
//
// The >> 8 threshold (1 failure per 256 bytes) was empirically determined
// to be optimal - more conservative (>>10) hurts pure scan, more aggressive
// (>>7) triggers unnecessary cutovers.

#include "textflag.h"

// func indexFoldNeedleNEON(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleNEON(SB), NOSPLIT, $0-72
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

// ============================================================================
// HYBRID 1-BYTE FAST PATH:
// - Small inputs (<2KB): Use 32-byte tight loop for better speculation overlap
// - Large inputs (≥2KB): Use 128-byte loop for lower per-byte overhead
// ============================================================================

	// Check if rare1 is a non-letter (R26==0xFF) - skip VAND for 5-op loop vs 7-op
	// 0xDF vs 0xFF differ at bit 5; if set, it's non-letter
	TSTW  $0x20, R26
	BNE   dispatch_nonletter

	CMP   $768, R12               // Threshold: 768B (tuned for Graviton)
	BGE   loop128_1byte           // Large input: use 128-byte loop
	CMP   $32, R12
	BLT   loop16_1byte_entry

loop32_main:
	// Tight loop matching Go's structure for speculation overlap
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12           // Decrement early for better speculation
	
	// Case-fold and compare (only 4 vector ops)
	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	
	// Combine and check (3 ops before VMOV)
	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13            // Stall point - but loop is tight enough
	
	// Branch: continue if no matches and more data
	BLT   end32_main              // R12 < 0 means we're done with 32-byte chunks
	CBZ   R13, loop32_main        // No matches, continue tight loop

end32_main:
	// Either found matches (R13 != 0) or exhausted 32-byte chunks
	CBZ   R13, loop16_1byte_entry // No matches, fall through to smaller paths
	
	// Process matches - extract syndrome for each chunk
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	
	// Check chunk 0
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $128, R14               // chunk offset = 0, but use 128 to mark 32-byte mode
	CBNZ  R13, try32_main
	
	// Check chunk 1
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14               // chunk offset = 16, but use 144 (128+16) to mark 32-byte mode
	CBNZ  R13, try32_main
	
	// No matches (shouldn't happen), continue
	CMP   $32, R12
	BGE   loop32_main
	B     loop16_1byte_entry

try32_main:
	// R13 = syndrome, R14 = chunk offset encoded as 128+offset (128=chunk0, 144=chunk1)
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15            // bit position -> byte position
	AND   $0x7F, R14, R17         // extract actual chunk offset (0 or 16)
	ADD   R17, R15, R15           // add chunk offset
	
	// Calculate position in haystack
	SUB   $32, R10, R16           // ptr before load (already advanced by 32)
	ADD   R15, R16, R16           // ptr to match
	SUB   R11, R16, R16           // offset from searchPtr start
	
	CMP   R9, R16
	BGT   clear32_main
	
	// Verify the match
	ADD   R0, R16, R8             // R8 = &haystack[candidate]
	B     verify_match_1byte

clear32_main:
	// Clear this bit and try next
	AND   $0x7F, R14, R17         // extract actual chunk offset (0 or 16)
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBNZ  R13, try32_main
	
	// Move to chunk 1 if we were in chunk 0 (R14 == 128 means chunk 0)
	CMP   $128, R14
	BNE   continue32_main
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14               // 128 + 16 = chunk 1
	CBNZ  R13, try32_main

continue32_main:
	CMP   $32, R12
	BGE   loop32_main
	B     loop16_1byte_entry

// ============================================================================
// 128-BYTE 1-BYTE PATH (for large inputs ≥2KB - lower per-byte overhead)
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
	// We have potential matches or exhausted large chunks
	CBZ   R13, loop32_main        // No matches, fall through to 32-byte loop
	
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

	// No matches, continue with appropriate loop
	CMP   $128, R12
	BGE   loop128_1byte
	B     loop32_main

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
	B     loop32_main

check_second64_after_first:
	// We were in first 64, now check second 64
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, continue_128_check
	B     end128_second64_1byte

continue_128_check:
	CMP   $128, R12
	BGE   loop128_1byte
	B     loop32_main

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
	BGT   clear_128_1byte

	// Verify the match
	ADD   R0, R16, R8             // R8 = &haystack[candidate]
	B     verify_match_1byte

clear_128_1byte:
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
exhausted_first64_1byte:
	// Exhausted this block - check if we need second 64 bytes
	VMOV  V4.D[0], R17
	CBNZ  R17, check_second64_after_first
	B     continue_128_check

check_next_chunk_1byte:
	CMP   $16, R14
	BEQ   chunk1_1byte
	CMP   $32, R14
	BEQ   chunk2_1byte
	CMP   $48, R14
	BEQ   chunk3_1byte
	B     continue_128_check

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
	B     exhausted_first64_1byte

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

	// Check threshold: failures > 4 + (bytes_scanned >> 8)
	// bytes_scanned = original_remaining - current_remaining
	// >> 8 means allow ~1 extra failure per 256 bytes scanned
	// Empirically optimal: balances pure scan (36.7 GB/s) and high-FP (17.4 GB/s)
	SUB   R11, R10, R17           // bytes_scanned = current_ptr - start_ptr
	LSR   $8, R17, R17            // bytes_scanned >> 8
	ADD   $4, R17, R17            // threshold = 4 + (bytes_scanned >> 8)
	CMP   R17, R25
	BGT   setup_2byte_mode        // Too many failures, switch to 2-byte

	// Check if we're in non-letter mode (R26 == 0xFF, bit 5 set)
	TSTW  $0x20, R26
	BNE   verify_fail_nl

	// Continue 1-byte search - check which loop we came from
	// V4.D[0] != 0 means we were in 128-byte loop (first 64 block)
	// V4.D[0] == 0 could be 128-byte (second 64) or 32-byte
	// Use R14 >= 0 (chunk offset from 128-byte) vs clear32_main state
	// Simplest: if R12 + scanned >= 2KB, we were in 128-byte mode
	CMP   $64, R14               // If R14 < 64, we were processing 128-byte chunks
	BLT   clear_128_1byte
	B     clear32_main

verify_fail_nl:
	// Non-letter path: dispatch based on R14 encoding
	// R14 = 0x100: 16-byte/scalar mode
	// R14 >= 128 (but < 0x100): 32-byte mode (128=chunk0, 144=chunk1)
	// R14 < 64: 128-byte mode  
	CMP   $0x100, R14
	BEQ   clear16_nl
	CMP   $64, R14
	BLT   clear_128_nl
	B     clear32_nl

// ============================================================================
// 16-BYTE 1-BYTE PATH (for remainder < 32 bytes)
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
// NON-LETTER FAST PATH: Skip VAND when rare1 is not a letter (mask=0xFF)
// For non-letters, VAND with 0xFF is a no-op. This gives us a 5-op loop
// matching Go's case-sensitive search exactly.
// ============================================================================

dispatch_nonletter:
	CMP   $768, R12
	BGE   loop128_nl
	CMP   $32, R12
	BLT   loop16_nl_entry

loop32_nl:
	// 5-op tight loop: VLD1 → SUBS → 2×VCMEQ → VORR → VADDP → VMOV
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12
	
	// Direct compare (no VAND needed - mask is 0xFF)
	VCMEQ V1.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V17.B16, V21.B16
	
	// Combine and check
	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	
	BLT   end32_nl
	CBZ   R13, loop32_nl

end32_nl:
	CBZ   R13, loop16_nl_entry
	
	// Extract syndrome for each chunk
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	
	// Check chunk 0
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $128, R14               // 128 = chunk 0 marker for 32-byte mode
	CBNZ  R13, try32_nl
	
	// Check chunk 1
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14               // 144 = chunk 1 marker (128+16)
	CBNZ  R13, try32_nl
	
	CMP   $32, R12
	BGE   loop32_nl
	B     loop16_nl_entry

try32_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	AND   $0x7F, R14, R17
	ADD   R17, R15, R15
	
	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16
	
	CMP   R9, R16
	BGT   clear32_nl
	
	ADD   R0, R16, R8
	B     verify_match_1byte      // Reuse letter path verification

clear32_nl:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBNZ  R13, try32_nl
	
	CMP   $128, R14
	BNE   continue32_nl
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, try32_nl

continue32_nl:
	CMP   $32, R12
	BGE   loop32_nl
	B     loop16_nl_entry

// 128-byte non-letter loop
loop128_nl:
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	VLD1.P 64(R10), [V24.B16, V25.B16, V26.B16, V27.B16]
	SUB   $128, R12, R12

	// Direct compare - no VAND
	VCMEQ V1.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V18.B16, V22.B16
	VCMEQ V1.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V24.B16, V28.B16
	VCMEQ V1.B16, V25.B16, V29.B16
	VCMEQ V1.B16, V26.B16, V30.B16
	VCMEQ V1.B16, V27.B16, V31.B16

	// Combine all 8 chunks
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V7.B16
	VORR  V28.B16, V29.B16, V8.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V7.B16, V6.B16
	VORR  V8.B16, V9.B16, V8.B16
	VORR  V6.B16, V8.B16, V6.B16

	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	
	CMP   $128, R12
	BLT   end128_nl
	CBZ   R13, loop128_nl

end128_nl:
	CBZ   R13, loop32_nl
	
	// Check first 64 bytes
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, end128_first64_nl

	// Check second 64 bytes
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, end128_second64_nl

	CMP   $128, R12
	BGE   loop128_nl
	B     loop32_nl

end128_first64_nl:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R17
	VMOV  R17, V4.D[0]
	B     check_chunks_nl

end128_second64_nl:
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	VMOV  ZR, V4.D[0]
	B     check_chunks_nl

check_chunks_nl:
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, try_match_nl

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, try_match_nl

	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, try_match_nl

	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, try_match_nl

	VMOV  V4.D[0], R17
	CBNZ  R17, check_second64_after_first_nl
	CMP   $128, R12
	BGE   loop128_nl
	B     loop32_nl

check_second64_after_first_nl:
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, continue_128_check_nl
	B     end128_second64_nl

continue_128_check_nl:
	CMP   $128, R12
	BGE   loop128_nl
	B     loop32_nl

try_match_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15
	VMOV  V4.D[0], R17
	SUB   R17, R15, R15
	ADD   $64, R15, R15

	SUB   $128, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear_128_nl

	ADD   R0, R16, R8
	B     verify_match_1byte

clear_128_nl:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try_match_nl

	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   check_next_chunk_nl
	VMOV  V4.D[0], R17
	CBNZ  R17, check_second64_after_first_nl
	B     continue_128_check_nl

check_next_chunk_nl:
	CMP   $16, R14
	BEQ   chunk1_nl
	CMP   $32, R14
	BEQ   chunk2_nl
	CMP   $48, R14
	BEQ   chunk3_nl
	B     continue_128_check_nl

chunk1_nl:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try_match_nl
	ADD   $16, R14, R14
chunk2_nl:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try_match_nl
	ADD   $16, R14, R14
chunk3_nl:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, try_match_nl
	VMOV  V4.D[0], R17
	CBNZ  R17, check_second64_after_first_nl
	B     continue_128_check_nl

// 16-byte non-letter loop
loop16_nl_entry:
	CMP   $16, R12
	BLT   scalar_nl_entry

loop16_nl:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VCMEQ V1.B16, V16.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, check16_nl_continue

try16_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear16_nl

	ADD   R0, R16, R8
	MOVD  $0x100, R14             // Mark as 16-byte non-letter path
	B     verify_match_1byte

clear16_nl:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try16_nl

check16_nl_continue:
	CMP   $16, R12
	BGE   loop16_nl

// Scalar non-letter path
scalar_nl_entry:
	CMP   $0, R12
	BLE   not_found

scalar_nl:
	MOVBU (R10), R13
	CMPW  R27, R13                // Direct compare (no mask needed)
	BNE   scalar_next_nl

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   scalar_next_nl

	ADD   R0, R16, R8

	// Inline verification for scalar non-letter
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf_nl_1
	ANDW  R24, R17, R17
snf_nl_1:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   scalar_next_nl

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf_nl_2
	ANDW  R24, R17, R17
snf_nl_2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   scalar_next_nl

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

sloop_nl:
	CBZ   R20, found
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   snf_nl_3
	ANDW  R24, R21, R21
snf_nl_3:
	CMPW  R22, R21
	BNE   scalar_next_nl
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     sloop_nl

scalar_next_nl:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, scalar_nl
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

	// Setup vectorized verification constants (like NEON-64B)
	// V4 = 159 (-97 as unsigned), V7 = 26, V8 = 32
	WORD  $0x4f04e7e4             // VMOVI $159, V4.B16 (for case-fold: byte + 159 = byte - 97)
	WORD  $0x4f00e747             // VMOVI $26, V7.B16
	WORD  $0x4f01e408             // VMOVI $32, V8.B16

	// Setup tail_mask_table pointer and bit-clear constant
	MOVD  $tail_mask_table<>(SB), R16  // R16 = tail mask table
	MOVW  $15, R15                     // R15 = 0xF for clearing syndrome bits

	// Restart search from beginning in 2-byte mode
	// This is simpler and correct - we only cutover after many failures
	// so re-scanning a small portion is acceptable
	ADD   R3, R0, R10             // R10 = search at off1 (start over)
	MOVD  R10, R11                // R11 = original searchPtr start
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	B     loop64_2byte_entry

// ============================================================================
// 2-BYTE MODE: Filter on BOTH rare1 AND rare2 (consistent 17 GB/s)
// Optimized to match NEON-64B performance:
// 1. Load rare1 AND rare2 together upfront (not conditionally)
// 2. Use SHRN $4 + FMOVD for syndrome extraction (1 vs 3 instructions)
// 3. Use vectorized XOR+UMAXV for verification (16 bytes/iter vs 1)
// 4. Use tail_mask_table for remainder handling
// ============================================================================

loop64_2byte_entry:
	CMP   $64, R12
	BLT   loop16_2byte_entry

loop64_2byte:
	// Save position for later (R17 = position in search)
	SUB   R11, R10, R17

	// Calculate both load positions upfront
	// R10 points to off1 position, we also need off2 position
	SUB   R3, R10, R23            // R23 = haystack position (R10 - off1)
	ADD   R5, R23, R23            // R23 = off2 position (haystack + off2)

	// Load BOTH rare1 and rare2 positions unconditionally (Gap #2 fix)
	VLD1  (R10), [V16.B16, V17.B16, V18.B16, V19.B16]   // rare1 data
	VLD1  (R23), [V24.B16, V25.B16, V26.B16, V27.B16]   // rare2 data
	ADD   $64, R10, R10
	SUB   $64, R12, R12

	// Check rare1 matches
	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VAND  V0.B16, V18.B16, V22.B16
	VAND  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Check rare2 matches
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

	// Quick check if any matches (using UMAXV like NEON-64B)
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	WORD  $0x6e30a8c6               // VUMAXV V6.B16, V6
	FMOVS F6, R13
	CBZW  R13, check64_2byte_continue

	// Extract syndromes using SHRN $4 + FMOVD (Gap #1 fix)
	// This packs 16 match bytes into 8 nibbles in the low 64 bits
	WORD  $0x0f0c8694               // VSHRN $4, V20.H8, V20.B8
	FMOVD F20, R13
	CBNZ  R13, try64_chunk0_2byte

chunk1_syndrome_2byte:
	WORD  $0x0f0c86b5               // VSHRN $4, V21.H8, V21.B8
	FMOVD F21, R13
	CBNZ  R13, try64_chunk1_2byte

chunk2_syndrome_2byte:
	WORD  $0x0f0c86d6               // VSHRN $4, V22.H8, V22.B8
	FMOVD F22, R13
	CBNZ  R13, try64_chunk2_2byte

chunk3_syndrome_2byte:
	WORD  $0x0f0c86f7               // VSHRN $4, V23.H8, V23.B8
	FMOVD F23, R13
	CBNZ  R13, try64_chunk3_2byte
	B     check64_2byte_continue

try64_chunk0_2byte:
	MOVD  ZR, R14
	B     try64_2byte
try64_chunk1_2byte:
	MOVD  $16, R14
	B     try64_2byte
try64_chunk2_2byte:
	MOVD  $32, R14
	B     try64_2byte
try64_chunk3_2byte:
	MOVD  $48, R14

try64_2byte:
	// R13 = syndrome, R14 = chunk offset, R17 = search position
	RBIT  R13, R19
	CLZ   R19, R19
	AND   $60, R19, R20            // R20 = (clz & 0x3c) for clearing - PRESERVED
	LSR   $2, R19, R19             // R19 = byte offset in chunk
	ADD   R14, R19, R19            // R19 = byte offset in 64-byte block

	// Position = haystack + search_position + byte_offset
	// R17 = position relative to R11 (start), R11 = haystack + off1
	// Haystack position = R11 - off1 + R17 + R19 = R0 + R17 + R19
	ADD   R17, R0, R8
	ADD   R19, R8, R8              // R8 = candidate haystack ptr

	// Check bounds
	SUB   R0, R8, R23              // position in haystack
	CMP   R9, R23
	BGT   clear64_2byte

	// Vectorized verification (Gap #3 fix)
	// Load haystack candidate and needle, XOR, apply case-folding, check non-zero
	// Note: R20 must be preserved for syndrome clearing, use R21/R22 for ptrs
	MOVD  R7, R19                  // R19 = remaining needle length
	MOVD  R8, R21                  // R21 = haystack candidate ptr
	MOVD  R6, R22                  // R22 = needle ptr

vloop64_2byte:
	SUBS  $16, R19, R23            // R23 = remaining - 16
	BLT   vtail64_2byte

	// Load 16 bytes from haystack and needle
	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	// Vectorized case-insensitive compare:
	// 1. XOR haystack with needle to find differences
	// 2. For letters: add 159 (= -97 unsigned), if < 26, mask with 0x20
	// 3. XOR result masks out case differences for letters
	VADD  V4.B16, V10.B16, V12.B16  // V12 = haystack + 159 (= haystack - 97)
	VEOR  V10.B16, V11.B16, V10.B16 // V10 = haystack XOR needle (differences)
	WORD  $0x6e2c34ec               // VCMHI V12.B16, V7.B16, V12.B16 (26 > (h-97)? = is letter?)
	VAND  V8.B16, V12.B16, V12.B16  // V12 = is_letter ? 0x20 : 0
	VEOR  V12.B16, V10.B16, V10.B16 // V10 = diff with case masked out
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10 (any non-zero?)
	FMOVS F10, R23
	CBZW  R23, vloop64_2byte
	B     clear64_2byte            // mismatch

vtail64_2byte:
	// Handle 1-15 remaining bytes using tail_mask_table (Gap #4 fix)
	CMP   $1, R19
	BLT   found_2byte              // R19 <= 0 means we matched everything

	// Load with tail mask
	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37a0d               // FMOVQ (R16)(R19<<4), F13  // ldr q13, [x16, x19, lsl #4]

	// Same case-insensitive compare
	VADD  V4.B16, V10.B16, V12.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e2c34ec               // VCMHI V12.B16, V7.B16, V12.B16
	VAND  V8.B16, V12.B16, V12.B16
	VEOR  V12.B16, V10.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16  // mask out bytes beyond needle
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, clear64_2byte

found_2byte:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear64_2byte:
	// Clear the bit we just tried and continue
	LSL   R20, R15, R20            // R20 = 0xF << (clz & 0x3c)
	BIC   R20, R13, R13
	CBNZ  R13, try64_2byte

	// Move to next chunk
	ADD   $16, R14, R14
	CMP   $16, R14
	BEQ   chunk1_syndrome_2byte
	CMP   $32, R14
	BEQ   chunk2_syndrome_2byte
	CMP   $48, R14
	BEQ   chunk3_syndrome_2byte
	// R14 >= 64: all chunks exhausted, continue to next 64-byte block
	B     check64_2byte_continue

check64_2byte_continue:
	CMP   $64, R12
	BGE   loop64_2byte
	B     loop16_2byte_entry

// ============================================================================
// 16-BYTE 2-BYTE PATH (optimized with SHRN + vectorized verification)
// ============================================================================

loop16_2byte_entry:
	CMP   $16, R12
	BLT   scalar_2byte_entry

loop16_2byte:
	// Save position for later
	SUB   R11, R10, R17

	// Calculate both load positions
	SUB   R3, R10, R23            // R23 = haystack position
	ADD   R5, R23, R23            // R23 = off2 position

	// Load BOTH rare1 and rare2 unconditionally
	VLD1  (R10), [V16.B16]        // rare1 data
	VLD1  (R23), [V24.B16]        // rare2 data
	ADD   $16, R10, R10
	SUB   $16, R12, R12

	// Check rare1 matches
	VAND  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16

	// Check rare2 matches
	VAND  V2.B16, V24.B16, V28.B16
	VCMEQ V3.B16, V28.B16, V28.B16

	// AND results
	VAND  V20.B16, V28.B16, V20.B16

	// Quick check using UMAXV
	WORD  $0x6e30aa94               // VUMAXV V20.B16, V20
	FMOVS F20, R13
	CBZW  R13, check16_2byte_continue

	// Reload match vector (UMAXV clobbered it) and extract syndrome
	VAND  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V20.B16, V28.B16, V20.B16
	WORD  $0x0f0c8694               // VSHRN $4, V20.H8, V20.B8
	FMOVD F20, R13
	CBZ   R13, check16_2byte_continue

try16_2byte:
	RBIT  R13, R19
	CLZ   R19, R19
	AND   $60, R19, R20            // R20 = (clz & 0x3c) for clearing
	LSR   $2, R19, R19             // R19 = byte offset

	// Position = haystack + search_position + byte_offset
	ADD   R17, R0, R8
	ADD   R19, R8, R8

	// Check bounds
	SUB   R0, R8, R23
	CMP   R9, R23
	BGT   clear16_2byte

	// Vectorized verification (same as 64-byte path)
	MOVD  R7, R19                  // R19 = remaining needle length
	MOVD  R8, R21                  // R21 = haystack candidate ptr (use R21, R20 is clz mask)
	MOVD  R6, R22                  // R22 = needle ptr

vloop16_2byte:
	SUBS  $16, R19, R23
	BLT   vtail16_2byte

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VADD  V4.B16, V10.B16, V12.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e2c34ec               // VCMHI V12.B16, V7.B16, V12.B16
	VAND  V8.B16, V12.B16, V12.B16
	VEOR  V12.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, vloop16_2byte
	B     clear16_2byte

vtail16_2byte:
	CMP   $1, R19
	BLT   found_2byte

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37a0d               // FMOVQ (R16)(R19<<4), F13

	VADD  V4.B16, V10.B16, V12.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e2c34ec               // VCMHI V12.B16, V7.B16, V12.B16
	VAND  V8.B16, V12.B16, V12.B16
	VEOR  V12.B16, V10.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, clear16_2byte
	B     found_2byte

clear16_2byte:
	LSL   R20, R15, R20
	BIC   R20, R13, R13
	CBNZ  R13, try16_2byte

check16_2byte_continue:
	CMP   $16, R12
	BGE   loop16_2byte

// ============================================================================
// SCALAR 2-BYTE PATH (with vectorized verification)
// R10 = current position at off1
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
	SUB   R3, R10, R17            // R17 = haystack position
	ADD   R5, R17, R23            // R23 = off2 position
	MOVBU (R23), R14
	// Extract rare2 mask/target from V2/V3
	VMOV  V2.B[0], R21
	VMOV  V3.B[0], R22
	ANDW  R21, R14, R14
	CMPW  R22, R14
	BNE   scalar_next_2byte

	// Check bounds
	SUB   R0, R17, R23
	CMP   R9, R23
	BGT   scalar_next_2byte

	MOVD  R17, R8                 // R8 = candidate haystack ptr

	// Vectorized verification
	MOVD  R7, R19                 // R19 = remaining needle length
	MOVD  R8, R21                 // R21 = haystack candidate ptr
	MOVD  R6, R22                 // R22 = needle ptr

vloop_scalar_2byte:
	SUBS  $16, R19, R23
	BLT   vtail_scalar_2byte

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VADD  V4.B16, V10.B16, V12.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e2c34ec               // VCMHI V12.B16, V7.B16, V12.B16
	VAND  V8.B16, V12.B16, V12.B16
	VEOR  V12.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, vloop_scalar_2byte
	B     scalar_next_2byte

vtail_scalar_2byte:
	CMP   $1, R19
	BLT   found_2byte

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37a0d               // FMOVQ (R16)(R19<<4), F13

	VADD  V4.B16, V10.B16, V12.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e2c34ec               // VCMHI V12.B16, V7.B16, V12.B16
	VAND  V8.B16, V12.B16, V12.B16
	VEOR  V12.B16, V10.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, scalar_next_2byte
	B     found_2byte

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

// ============================================================================
// TAIL MASK TABLE for vectorized verification
// Entry N (0-15) has first N bytes as 0xFF, rest as 0x00
// Used for masking partial vectors in tail processing
// ============================================================================
DATA tail_mask_table<>+0x00(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x08(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x10(SB)/1, $0xff
DATA tail_mask_table<>+0x11(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x19(SB)/4, $0x00000000
DATA tail_mask_table<>+0x1d(SB)/2, $0x0000
DATA tail_mask_table<>+0x1f(SB)/1, $0x00
DATA tail_mask_table<>+0x20(SB)/1, $0xff
DATA tail_mask_table<>+0x21(SB)/1, $0xff
DATA tail_mask_table<>+0x22(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x2a(SB)/4, $0x00000000
DATA tail_mask_table<>+0x2e(SB)/2, $0x0000
DATA tail_mask_table<>+0x30(SB)/1, $0xff
DATA tail_mask_table<>+0x31(SB)/1, $0xff
DATA tail_mask_table<>+0x32(SB)/1, $0xff
DATA tail_mask_table<>+0x33(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x3b(SB)/4, $0x00000000
DATA tail_mask_table<>+0x3f(SB)/1, $0x00
DATA tail_mask_table<>+0x40(SB)/1, $0xff
DATA tail_mask_table<>+0x41(SB)/1, $0xff
DATA tail_mask_table<>+0x42(SB)/1, $0xff
DATA tail_mask_table<>+0x43(SB)/1, $0xff
DATA tail_mask_table<>+0x44(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x4c(SB)/4, $0x00000000
DATA tail_mask_table<>+0x50(SB)/1, $0xff
DATA tail_mask_table<>+0x51(SB)/1, $0xff
DATA tail_mask_table<>+0x52(SB)/1, $0xff
DATA tail_mask_table<>+0x53(SB)/1, $0xff
DATA tail_mask_table<>+0x54(SB)/1, $0xff
DATA tail_mask_table<>+0x55(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x5d(SB)/2, $0x0000
DATA tail_mask_table<>+0x5f(SB)/1, $0x00
DATA tail_mask_table<>+0x60(SB)/1, $0xff
DATA tail_mask_table<>+0x61(SB)/1, $0xff
DATA tail_mask_table<>+0x62(SB)/1, $0xff
DATA tail_mask_table<>+0x63(SB)/1, $0xff
DATA tail_mask_table<>+0x64(SB)/1, $0xff
DATA tail_mask_table<>+0x65(SB)/1, $0xff
DATA tail_mask_table<>+0x66(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x6e(SB)/2, $0x0000
DATA tail_mask_table<>+0x70(SB)/1, $0xff
DATA tail_mask_table<>+0x71(SB)/1, $0xff
DATA tail_mask_table<>+0x72(SB)/1, $0xff
DATA tail_mask_table<>+0x73(SB)/1, $0xff
DATA tail_mask_table<>+0x74(SB)/1, $0xff
DATA tail_mask_table<>+0x75(SB)/1, $0xff
DATA tail_mask_table<>+0x76(SB)/1, $0xff
DATA tail_mask_table<>+0x77(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x7f(SB)/1, $0x00
DATA tail_mask_table<>+0x80(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0x88(SB)/8, $0x0000000000000000
DATA tail_mask_table<>+0x90(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0x98(SB)/8, $0x00000000000000ff
DATA tail_mask_table<>+0xa0(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0xa8(SB)/8, $0x000000000000ffff
DATA tail_mask_table<>+0xb0(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0xb8(SB)/8, $0x0000000000ffffff
DATA tail_mask_table<>+0xc0(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0xc8(SB)/8, $0x00000000ffffffff
DATA tail_mask_table<>+0xd0(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0xd8(SB)/8, $0x000000ffffffffff
DATA tail_mask_table<>+0xe0(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0xe8(SB)/8, $0x0000ffffffffffff
DATA tail_mask_table<>+0xf0(SB)/8, $0xffffffffffffffff
DATA tail_mask_table<>+0xf8(SB)/8, $0x00ffffffffffffff
GLOBL tail_mask_table<>(SB), (RODATA|NOPTR), $256
