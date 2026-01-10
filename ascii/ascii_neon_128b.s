//go:build !noasm && arm64

// 64-byte per iteration NEON with interleaved loads/compute
// Key insight: Graviton 4 has 4 NEON pipes - we can do 4 ops in parallel
// By loading 64 bytes and processing in parallel, we hide latency better

#include "textflag.h"

// func indexFoldNeedleNeon128(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleNeon128(SB), NOSPLIT, $0-72
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVBU rare1+16(FP), R2
	MOVD  off1+24(FP), R3
	MOVD  norm_needle+48(FP), R6
	MOVD  needle_len+56(FP), R7

	SUBS  R7, R1, R9
	BLT   not_found
	CBZ   R7, found_zero

	// Compute mask and target for rare1
	ORRW  $0x20, R2, R10
	SUBW  $97, R10, R10
	CMPW  $26, R10
	BCS   not_letter
	MOVW  $0xDF, R4
	ANDW  $0xDF, R2, R5
	B     setup
not_letter:
	MOVW  $0xFF, R4
	MOVW  R2, R5
setup:
	VDUP  R4, V0.B16              // mask
	VDUP  R5, V1.B16              // target

	// Magic constant
	MOVD  $0x4010040140100401, R10
	VMOV  R10, V5.D[0]
	VMOV  R10, V5.D[1]

	// Setup pointers
	ADD   R3, R0, R10             // searchPtr = haystack + off1
	MOVD  R10, R11                // save original
	ADD   $1, R9, R12             // remaining = searchLen + 1

	// Need at least 128 bytes for main loop
	CMP   $128, R12
	BLT   loop64_entry

loop128:
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

	// Process second 64 bytes (chunks 4-7) - reuse V16-V19 for results
	VAND  V0.B16, V24.B16, V28.B16
	VAND  V0.B16, V25.B16, V29.B16
	VAND  V0.B16, V26.B16, V30.B16
	VAND  V0.B16, V27.B16, V31.B16
	VCMEQ V1.B16, V28.B16, V28.B16
	VCMEQ V1.B16, V29.B16, V29.B16
	VCMEQ V1.B16, V30.B16, V30.B16
	VCMEQ V1.B16, V31.B16, V31.B16

	// Combine all 8 chunks for quick check
	VORR  V20.B16, V21.B16, V24.B16
	VORR  V22.B16, V23.B16, V25.B16
	VORR  V28.B16, V29.B16, V26.B16
	VORR  V30.B16, V31.B16, V27.B16
	VORR  V24.B16, V25.B16, V24.B16
	VORR  V26.B16, V27.B16, V26.B16
	VORR  V24.B16, V26.B16, V26.B16

	// Early exit check
	CMP   $128, R12
	BLT   end128                  // Not enough for next iteration
	// Fast reduce to check if any matches
	VADDP V26.D2, V26.D2, V26.D2
	VMOV  V26.D[0], R13
	CBZ   R13, loop128            // No matches, continue

end128:
	// Check first 64 bytes (chunks 0-3)
	VORR  V20.B16, V21.B16, V24.B16
	VORR  V22.B16, V23.B16, V25.B16
	VORR  V24.B16, V25.B16, V26.B16
	VADDP V26.D2, V26.D2, V26.D2
	VMOV  V26.D[0], R13
	CBNZ  R13, end128_first64

	// Check second 64 bytes (chunks 4-7)
	VORR  V28.B16, V29.B16, V24.B16
	VORR  V30.B16, V31.B16, V25.B16
	VORR  V24.B16, V25.B16, V26.B16
	VADDP V26.D2, V26.D2, V26.D2
	VMOV  V26.D[0], R13
	CBNZ  R13, end128_second64

	// No matches, try next iteration or fall through
	CMP   $128, R12
	BGE   loop128
	B     loop64_entry

end128_first64:
	// Process syndrome for first 64 bytes
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R8                 // block offset within 128-byte load
	B     check_chunks_0to3

end128_second64:
	// Process syndrome for second 64 bytes
	// Move V28-V31 to V20-V23 for unified handling
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $0, R8                  // block offset (second 64 is at end)
	B     check_chunks_0to3

check_chunks_0to3:
	// Check chunk 0
	VADDP V20.B16, V20.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  ZR, R14                 // chunk offset = 0
	CBNZ  R13, try_match128

	// Check chunk 1
	VADDP V21.B16, V21.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  $16, R14
	CBNZ  R13, try_match128

	// Check chunk 2
	VADDP V22.B16, V22.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  $32, R14
	CBNZ  R13, try_match128

	// Check chunk 3
	VADDP V23.B16, V23.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  $48, R14
	CBNZ  R13, try_match128

	// No matches in this 64-byte block
	// If we were in first 64, check second 64
	CBNZ  R8, end128_second64_direct
	// Otherwise continue to smaller loops
	CMP   $128, R12
	BGE   loop128
	B     loop64_entry

end128_second64_direct:
	// We were in first 64, now check second 64
	VORR  V28.B16, V29.B16, V24.B16
	VORR  V30.B16, V31.B16, V25.B16
	VORR  V24.B16, V25.B16, V26.B16
	VADDP V26.D2, V26.D2, V26.D2
	VMOV  V26.D[0], R13
	CBZ   R13, loop128_continue
	B     end128_second64

loop128_continue:
	CMP   $128, R12
	BGE   loop128
	B     loop64_entry

try_match128:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15            // bit position -> byte position
	ADD   R14, R15, R15           // add chunk offset
	SUB   R8, R15, R15            // adjust for block offset (0 or 64)
	ADD   $64, R15, R15           // adjust since second load was +64 from first

	// Calculate position in haystack
	SUB   $128, R10, R16          // ptr before both loads
	ADD   R15, R16, R16           // ptr to match
	SUB   R11, R16, R16           // offset from searchPtr

	CMP   R9, R16
	BGT   clear128

	// Verify
	ADD   R0, R16, R8             // &haystack[candidate]
	B     verify_match128

clear128:
	// Clear bit and try next position
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try_match128

	// Move to next chunk
	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   check_next_chunk128
	// Exhausted this 64-byte block
	CBNZ  R8, end128_second64_direct
	B     loop128_continue

check_next_chunk128:
	CMP   $16, R14
	BEQ   check_chunk1_128
	CMP   $32, R14
	BEQ   check_chunk2_128
	CMP   $48, R14
	BEQ   check_chunk3_128
	B     loop128_continue

check_chunk1_128:
	VADDP V21.B16, V21.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	CBNZ  R13, try_match128
	ADD   $16, R14, R14
check_chunk2_128:
	VADDP V22.B16, V22.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	CBNZ  R13, try_match128
	ADD   $16, R14, R14
check_chunk3_128:
	VADDP V23.B16, V23.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	CBNZ  R13, try_match128
	B     loop128_continue

verify_match128:
	// Quick first byte check
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf128_1
	ANDW  $0xDF, R17, R17
vnf128_1:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   clear128

	// Quick last byte check
	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf128_2
	ANDW  $0xDF, R17, R17
vnf128_2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   clear128

	// Full verify
	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop128:
	CBZ   R20, found128
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf128_3
	ANDW  $0xDF, R21, R21
vnf128_3:
	CMPW  R22, R21
	BNE   clear128
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop128

found128:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

loop64_entry:
	// Need at least 64 bytes for this loop
	CMP   $64, R12
	BLT   loop32_entry

loop64:
	// Load 64 bytes (4 x 16-byte vectors)
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	SUB   $64, R12, R12

	// Process all 4 chunks with interleaved ops for better pipelining
	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V0.B16, V18.B16, V22.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VAND  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Combine results: OR all 4 chunks
	VORR  V20.B16, V21.B16, V24.B16
	VORR  V22.B16, V23.B16, V25.B16
	VORR  V24.B16, V25.B16, V26.B16

	// Early exit check
	CMP   $64, R12
	BLT   end64                   // Not enough for next iteration
	// Fast reduce to check if any matches
	VADDP V26.D2, V26.D2, V26.D2
	VMOV  V26.D[0], R13
	CBZ   R13, loop64             // No matches, continue

end64:
	// Compute syndromes for each chunk
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16

	// Check chunk 0
	VADDP V20.B16, V20.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  ZR, R14                 // chunk offset = 0
	CBNZ  R13, try_match64

	// Check chunk 1
	VADDP V21.B16, V21.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  $16, R14
	CBNZ  R13, try_match64

	// Check chunk 2
	VADDP V22.B16, V22.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  $32, R14
	CBNZ  R13, try_match64

	// Check chunk 3
	VADDP V23.B16, V23.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	MOVD  $48, R14
	CBNZ  R13, try_match64

	// No matches in any chunk, check if we can continue
	CMP   $64, R12
	BGE   loop64
	B     loop32_entry

try_match64:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15            // bit position -> byte position
	ADD   R14, R15, R15           // add chunk offset

	// Calculate position in haystack
	SUB   $64, R10, R16           // ptr before last load
	ADD   R15, R16, R16           // ptr to match
	SUB   R11, R16, R16           // offset from searchPtr

	CMP   R9, R16
	BGT   clear64

	// Verify - R16 is already the haystack-relative offset
	ADD   R0, R16, R8             // &haystack[candidate]

	// Quick first byte check
	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf1
	ANDW  $0xDF, R17, R17
vnf1:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   clear64

	// Quick last byte check
	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf2
	ANDW  $0xDF, R17, R17
vnf2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   clear64

	// Full verify
	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop64:
	CBZ   R20, found64
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf3
	ANDW  $0xDF, R21, R21
vnf3:
	CMPW  R22, R21
	BNE   clear64
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop64

found64:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear64:
	// Clear bit and try next position in same chunk
	ADD   $1, R15, R17
	SUB   R14, R17, R17           // position within chunk
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try_match64

	// Move to next chunk
	ADD   $16, R14, R14
	CMP   $16, R14
	BEQ   check_chunk1
	CMP   $32, R14
	BEQ   check_chunk2
	CMP   $48, R14
	BEQ   check_chunk3
	B     after_chunks64

check_chunk1:
	VADDP V21.B16, V21.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	CBNZ  R13, try_match64
	ADD   $16, R14, R14
check_chunk2:
	VADDP V22.B16, V22.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	CBNZ  R13, try_match64
	ADD   $16, R14, R14
check_chunk3:
	VADDP V23.B16, V23.B16, V26.B16
	VADDP V26.B16, V26.B16, V26.B16
	VMOV  V26.D[0], R13
	CBNZ  R13, try_match64

after_chunks64:
	CMP   $64, R12
	BGE   loop64

loop32_entry:
	CMP   $32, R12
	BLT   loop16_entry

loop32:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUB   $32, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16

	VORR  V20.B16, V21.B16, V22.B16
	CMP   $32, R12
	BLT   end32
	WORD  $0x4ef6bad6             // addp v22.2d, v22.2d, v22.2d
	VMOV  V22.D[0], R13
	CBZ   R13, loop32

end32:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16

	VADDP V20.B16, V20.B16, V22.B16
	VADDP V22.B16, V22.B16, V22.B16
	VMOV  V22.D[0], R13
	MOVD  ZR, R14
	CBNZ  R13, try_match32

	VADDP V21.B16, V21.B16, V22.B16
	VADDP V22.B16, V22.B16, V22.B16
	VMOV  V22.D[0], R13
	MOVD  $16, R14
	CBNZ  R13, try_match32
	B     loop16_entry

try_match32:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15

	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear32

	ADD   R0, R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf32a
	ANDW  $0xDF, R17, R17
vnf32a:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   clear32

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf32b
	ANDW  $0xDF, R17, R17
vnf32b:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   clear32

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop32:
	CBZ   R20, found32
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf32c
	ANDW  $0xDF, R21, R21
vnf32c:
	CMPW  R22, R21
	BNE   clear32
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop32

found32:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear32:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try_match32

	CMP   $0, R14
	BNE   loop16_entry
	VADDP V21.B16, V21.B16, V22.B16
	VADDP V22.B16, V22.B16, V22.B16
	VMOV  V22.D[0], R13
	MOVD  $16, R14
	CBNZ  R13, try_match32

loop16_entry:
	CMP   $16, R12
	BLT   scalar_entry

loop16:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.D[0], R13
	CBZ   R13, check16_continue

try16:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   clear16

	ADD   R0, R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf16a
	ANDW  $0xDF, R17, R17
vnf16a:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   clear16

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   vnf16b
	ANDW  $0xDF, R17, R17
vnf16b:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   clear16

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

vloop16:
	CBZ   R20, found16
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   vnf16c
	ANDW  $0xDF, R21, R21
vnf16c:
	CMPW  R22, R21
	BNE   clear16
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     vloop16

found16:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear16:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, try16

check16_continue:
	CMP   $16, R12
	BGE   loop16

scalar_entry:
	CMP   $0, R12
	BLE   not_found

scalar:
	MOVBU (R10), R13
	ANDW  R4, R13, R14
	CMPW  R5, R14
	BNE   scalar_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   scalar_next

	ADD   R0, R16, R8

	MOVBU (R8), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf1
	ANDW  $0xDF, R17, R17
snf1:
	MOVBU (R6), R19
	CMPW  R19, R17
	BNE   scalar_next

	ADD   R7, R8, R17
	SUB   $1, R17
	MOVBU (R17), R17
	SUBW  $97, R17, R19
	CMPW  $26, R19
	BCS   snf2
	ANDW  $0xDF, R17, R17
snf2:
	ADD   R7, R6, R19
	SUB   $1, R19
	MOVBU (R19), R19
	CMPW  R19, R17
	BNE   scalar_next

	MOVD  R8, R17
	MOVD  R6, R19
	MOVD  R7, R20

sloop:
	CBZ   R20, founds
	MOVBU (R17), R21
	MOVBU (R19), R22
	SUBW  $97, R21, R23
	CMPW  $26, R23
	BCS   snf3
	ANDW  $0xDF, R21, R21
snf3:
	CMPW  R22, R21
	BNE   scalar_next
	ADD   $1, R17
	ADD   $1, R19
	SUB   $1, R20
	B     sloop

founds:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

scalar_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, scalar

not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+64(FP)
	RET

found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+64(FP)
	RET
