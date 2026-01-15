//go:build !noasm && arm64

// Hand-optimized ARM64 NEON assembly for substring search kernels
// Targets Go stdlib performance: 9-instruction hot loop using VLD1.P + SUBS pattern
//
// Go ARM64 register conventions:
// R0-R17: general purpose (R0-R7 for args/returns)
// R18: platform register (RESERVED)
// R19-R26: callee-saved
// R27 (g): goroutine pointer (RESERVED)
// R28: reserved
// R29 (FP): frame pointer (RESERVED)
// R30: link register
// RSP: stack pointer

#include "textflag.h"

// Magic constant for syndrome extraction (2 bits per byte)
// 0x40100401 = ((1<<0) + (4<<8) + (16<<16) + (64<<24))
#define SYNDROME_MAGIC $0x40100401

// func indexExact1Byte(haystack string, needle string, off1 int) uint64
TEXT ·indexExact1Byte(SB), NOSPLIT, $0-48
	MOVD  haystack+0(FP), R0      // R0 = haystack ptr
	MOVD  haystack_len+8(FP), R1  // R1 = haystack len
	MOVD  needle+16(FP), R2       // R2 = needle ptr
	MOVD  needle_len+24(FP), R3   // R3 = needle len
	MOVD  off1+32(FP), R4         // R4 = off1

	// Early exits
	SUBS  R3, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   not_found_exact1
	CBZ   R3, found_zero_exact1

	// Load target byte from needle[off1]
	MOVBU (R2)(R4), R5            // R5 = target byte

	// Setup
	ADD   $1, R9, R10             // R10 = remaining = searchLen + 1
	ADD   R4, R0, R11             // R11 = searchPtr = haystack + off1
	MOVD  R11, R12                // R12 = searchStart (for position calc)
	MOVD  ZR, R13                 // R13 = failure count

	// Broadcast target byte
	VMOV  R5, V0.B16

	// Magic constant for syndrome
	MOVD  SYNDROME_MAGIC, R14
	VMOV  R14, V5.S4

	CMP   $64, R10
	BLT   loop32_exact1_entry

// ============================================================================
// 64-BYTE LOOP: Process 64 bytes per iteration (simpler, no pipelining)
// ============================================================================
loop64_exact1:
	VLD1.P 64(R11), [V1.B16, V2.B16, V3.B16, V4.B16]
	SUBS   $64, R10, R10
	
	// Compare all 4 chunks
	VCMEQ  V0.B16, V1.B16, V16.B16
	VCMEQ  V0.B16, V2.B16, V17.B16
	VCMEQ  V0.B16, V3.B16, V18.B16
	VCMEQ  V0.B16, V4.B16, V19.B16
	
	// Quick check: any match?
	VORR   V16.B16, V17.B16, V6.B16
	VORR   V18.B16, V19.B16, V7.B16
	VORR   V6.B16, V7.B16, V6.B16
	VADDP  V6.D2, V6.D2, V6.D2
	VMOV   V6.D[0], R15
	
	BLS    end64_check_exact1         // Exit if no more data
	CBZ    R15, loop64_exact1         // No match, continue

end64_check_exact1:
	CBZ    R15, loop32_exact1_entry   // No match in this chunk

end64_exact1:
	// Extract syndromes from V16-V19
	VAND   V5.B16, V16.B16, V16.B16
	VAND   V5.B16, V17.B16, V17.B16
	VAND   V5.B16, V18.B16, V18.B16
	VAND   V5.B16, V19.B16, V19.B16
	MOVD   $0, R16                     // chunk offset

process_chunk64_exact1:
	// Check each chunk
	CMP    $0, R16
	BEQ    chunk64_0_exact1
	CMP    $16, R16
	BEQ    chunk64_1_exact1
	CMP    $32, R16
	BEQ    chunk64_2_exact1
	B      chunk64_3_exact1

chunk64_0_exact1:
	VADDP  V16.B16, V16.B16, V6.B16
	B      extract64_exact1
chunk64_1_exact1:
	VADDP  V17.B16, V17.B16, V6.B16
	B      extract64_exact1
chunk64_2_exact1:
	VADDP  V18.B16, V18.B16, V6.B16
	B      extract64_exact1
chunk64_3_exact1:
	VADDP  V19.B16, V19.B16, V6.B16

extract64_exact1:
	VADDP  V6.B16, V6.B16, V6.B16
	VMOV   V6.S[0], R15
	CBZ    R15, next_chunk64_exact1

process_match64_exact1:
	RBIT   R15, R17
	CLZ    R17, R17
	LSR    $1, R17, R17
	
	SUB    $64, R11, R19
	ADD    R16, R19, R19
	ADD    R17, R19, R19
	SUB    R12, R19, R19
	
	CMP    R9, R19
	BGT    clear64_exact1
	
	// Verify match
	ADD    R0, R19, R8
	MOVD   R8, R20
	MOVD   R2, R21
	MOVD   R3, R22

verify64_exact1:
	CMP    $16, R22
	BLT    verify_tail64_exact1
	VLD1   (R20), [V10.B16]
	VLD1   (R21), [V11.B16]
	VEOR   V10.B16, V11.B16, V12.B16
	WORD   $0x6e30a98c
	FMOVS  F12, R6
	CBNZW  R6, fail64_exact1
	ADD    $16, R20
	ADD    $16, R21
	SUBS   $16, R22, R22
	BGT    verify64_exact1
	MOVD   R19, R17
	B      found_exact1

verify_tail64_exact1:
	CMP    $0, R22
	BLE    found64_match_exact1
	VLD1   (R20), [V10.B16]
	VLD1   (R21), [V11.B16]
	VEOR   V10.B16, V11.B16, V12.B16
	MOVD   $tail_mask_table<>(SB), R6
	ADD    R22<<4, R6, R6
	VLD1   (R6), [V13.B16]
	VAND   V13.B16, V12.B16, V12.B16
	WORD   $0x6e30a98c
	FMOVS  F12, R6
	CBNZW  R6, fail64_exact1

found64_match_exact1:
	MOVD   R19, R17
	B      found_exact1

fail64_exact1:
	// Threshold = 32 + (bytes_scanned >> 3)
	SUB    R12, R11, R20
	LSR    $3, R20, R20
	ADD    $32, R20
	ADD    $1, R13
	CMP    R20, R13
	BGE    exceeded64_exact1

clear64_exact1:
	ADD    $1, R17, R20
	LSL    $1, R20, R20
	MOVD   $1, R21
	LSL    R20, R21, R20
	SUB    $1, R20
	BIC    R20, R15, R15
	CBNZ   R15, process_match64_exact1

next_chunk64_exact1:
	ADD    $16, R16
	CMP    $64, R16
	BLT    process_chunk64_exact1
	// All chunks exhausted, try next 64-byte iteration
	CMP    $64, R10
	BGE    loop64_exact1
	B      loop32_exact1_entry

exceeded64_exact1:
	MOVD   $0x8000000000000000, R20   // exceeded flag (bit 63)
	ADD    R19, R20, R0              // add position
	MOVD   R0, ret+40(FP)
	RET

loop32_exact1_entry:
	CMP   $32, R10
	BLT   loop16_exact1

// ============================================================================
// FALLBACK 32-BYTE LOOP: Standard pattern for small remainders
// ============================================================================
loop32_exact1:
	VLD1.P 32(R11), [V1.B16, V2.B16]
	SUBS   $32, R10, R10
	VCMEQ  V0.B16, V1.B16, V3.B16
	VCMEQ  V0.B16, V2.B16, V4.B16
	BLS    end32_exact1
	VORR   V4.B16, V3.B16, V6.B16
	VADDP  V6.D2, V6.D2, V6.D2
	VMOV   V6.D[0], R15
	CBNZ   R15, end32_exact1
	CMP    $32, R10
	BGE    loop32_exact1
	// R10 < 32 and no match, fall through to end32_exact1

end32_exact1:
	VORR  V4.B16, V3.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R15
	CBZ   R15, loop16_exact1

	// Extract syndromes
	VAND  V5.B16, V3.B16, V3.B16
	VAND  V5.B16, V4.B16, V4.B16
	VADDP V4.B16, V3.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.D[0], R15

process_syndrome32_exact1:
	CBZ   R15, loop16_exact1

	// Find position
	RBIT  R15, R16
	CLZ   R16, R16
	LSR   $1, R16, R16

	// Calculate position in haystack
	SUB   $32, R11, R17
	ADD   R16, R17, R17
	SUB   R12, R17, R17

	CMP   R9, R17
	BGT   clear_bit32_exact1

	// Verify
	ADD   R0, R17, R8
	MOVD  R8, R19
	MOVD  R2, R20
	MOVD  R3, R21

verify32_exact1:
	CMP   $16, R21
	BLT   verify_tail32_exact1
	VLD1  (R19), [V10.B16]
	VLD1  (R20), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	WORD  $0x6e30a98c              // VUMAXV V12.B16, V12
	FMOVS F12, R6
	CBNZW R6, fail32_exact1
	ADD   $16, R19
	ADD   $16, R20
	SUBS  $16, R21, R21
	BGT   verify32_exact1
	B     found_exact1

verify_tail32_exact1:
	CMP   $0, R21
	BLE   found_exact1
	VLD1  (R19), [V10.B16]
	VLD1  (R20), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	MOVD  $tail_mask_table<>(SB), R6
	ADD   R21<<4, R6, R6
	VLD1  (R6), [V13.B16]
	VAND  V13.B16, V12.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBZW  R6, found_exact1

fail32_exact1:
	// Threshold = 32 + (bytes_scanned >> 3)
	SUB   R12, R11, R19
	LSR   $3, R19, R19
	ADD   $32, R19
	ADD   $1, R13
	CMP   R19, R13
	BGE   exceeded_exact1

clear_bit32_exact1:
	ADD   $1, R16, R19
	LSL   $1, R19, R19
	MOVD  $1, R20
	LSL   R19, R20, R19
	SUB   $1, R19
	BIC   R19, R15, R15
	CBNZ  R15, process_syndrome32_exact1
	// No more matches in this 32-byte chunk - fall through to 16-byte or scalar loop

loop16_exact1:
	// Use signed comparison to handle negative R10 after SUBS overflow
	CMP   $15, R10
	BLE   scalar_exact1               // Branch if R10 <= 15 (signed)

loop16_inner_exact1:
	VLD1.P 16(R11), [V1.B16]
	SUBS   $16, R10, R10
	VCMEQ  V0.B16, V1.B16, V3.B16
	VAND   V5.B16, V3.B16, V3.B16
	VADDP  V3.B16, V3.B16, V3.B16
	VADDP  V3.B16, V3.B16, V3.B16
	VMOV   V3.S[0], R15
	BLS    end16_exact1
	CBZ    R15, loop16_inner_exact1

end16_exact1:
	CBZ   R15, scalar_exact1

process16_exact1:
	RBIT  R15, R16
	CLZ   R16, R16
	LSR   $1, R16, R16

	SUB   $16, R11, R17
	ADD   R16, R17, R17
	SUB   R12, R17, R17

	CMP   R9, R17
	BGT   clear16_exact1

	ADD   R0, R17, R8
	MOVD  R8, R19
	MOVD  R2, R20
	MOVD  R3, R21

verify16_exact1:
	CMP   $16, R21
	BLT   verify_tail16_exact1
	VLD1  (R19), [V10.B16]
	VLD1  (R20), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBNZW R6, fail16_exact1
	ADD   $16, R19
	ADD   $16, R20
	SUBS  $16, R21, R21
	BGT   verify16_exact1
	B     found_exact1

verify_tail16_exact1:
	CMP   $0, R21
	BLE   found_exact1
	VLD1  (R19), [V10.B16]
	VLD1  (R20), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	MOVD  $tail_mask_table<>(SB), R6
	ADD   R21<<4, R6, R6
	VLD1  (R6), [V13.B16]
	VAND  V13.B16, V12.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBZW  R6, found_exact1

fail16_exact1:
	// Threshold = 32 + (bytes_scanned >> 3)
	SUB   R12, R11, R19
	LSR   $3, R19, R19
	ADD   $32, R19
	ADD   $1, R13
	CMP   R19, R13
	BGE   exceeded_exact1

clear16_exact1:
	ADD   $1, R16, R19
	LSL   $1, R19, R19
	MOVD  $1, R20
	LSL   R19, R20, R19
	SUB   $1, R19
	BIC   R19, R15, R15
	CBNZ  R15, process16_exact1
	CMP   $16, R10
	BGE   loop16_inner_exact1

scalar_exact1:
	CMP   $0, R10
	BLE   not_found_exact1

scalar_loop_exact1:
	MOVBU (R11), R15
	CMP   R5, R15
	BNE   scalar_next_exact1

	SUB   R12, R11, R17
	CMP   R9, R17
	BGT   scalar_next_exact1

	// Verify
	ADD   R0, R17, R8
	MOVD  R8, R19
	MOVD  R2, R20
	MOVD  R3, R21

scalar_verify_exact1:
	MOVBU (R19), R6
	MOVBU (R20), R7
	CMP   R6, R7
	BNE   scalar_fail_exact1
	ADD   $1, R19
	ADD   $1, R20
	SUBS  $1, R21, R21
	BGT   scalar_verify_exact1
	B     found_exact1

scalar_fail_exact1:
	// Threshold = 32 + (bytes_scanned >> 3)
	// More lenient than 16 + (bytes >> 4) to handle pathological small inputs
	SUB   R12, R11, R19
	LSR   $3, R19, R19
	ADD   $32, R19
	ADD   $1, R13
	CMP   R19, R13
	BGE   exceeded_exact1

scalar_next_exact1:
	ADD   $1, R11
	SUBS  $1, R10, R10
	BGT   scalar_loop_exact1

not_found_exact1:
	MOVD  $-1, R0
	MOVD  R0, ret+40(FP)
	RET

found_zero_exact1:
	MOVD  ZR, R0
	MOVD  R0, ret+40(FP)
	RET

found_exact1:
	MOVD  R17, R0
	MOVD  R0, ret+40(FP)
	RET

exceeded_exact1:
	MOVD  $0x8000000000000000, R19   // exceeded flag (bit 63)
	ADD   R17, R19, R0              // add position
	MOVD  R0, ret+40(FP)
	RET

// func indexExact2Byte(haystack string, needle string, off1 int, off2Delta int) uint64
TEXT ·indexExact2Byte(SB), NOSPLIT, $0-56
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVD  needle+16(FP), R2
	MOVD  needle_len+24(FP), R3
	MOVD  off1+32(FP), R4
	MOVD  off2_delta+40(FP), R5

	SUBS  R3, R1, R9
	BLT   not_found_exact2
	CBZ   R3, found_zero_exact2

	// Load target bytes
	ADD   R4, R2, R6
	MOVBU (R6), R7              // R7 = rare1
	MOVBU (R6)(R5), R8          // R8 = rare2

	ADD   $1, R9, R10           // remaining
	ADD   R4, R0, R11           // searchPtr
	MOVD  R11, R12              // searchStart
	MOVD  ZR, R13               // failures

	VMOV  R7, V0.B16
	VMOV  R8, V1.B16

	MOVD  SYNDROME_MAGIC, R14
	VMOV  R14, V5.S4

	CMP   $64, R10
	BLT   loop16_exact2

loop64_exact2:
	// Load 64 bytes for rare1
	VLD1.P 64(R11), [V16.B16, V17.B16, V18.B16, V19.B16]

	// Load 64 bytes at rare2 offset
	SUB   $64, R11, R14
	ADD   R5, R14, R14
	VLD1  (R14), [V20.B16, V21.B16, V22.B16, V23.B16]

	SUBS  $64, R10, R10

	// Compare
	VCMEQ V0.B16, V16.B16, V24.B16
	VCMEQ V0.B16, V17.B16, V25.B16
	VCMEQ V0.B16, V18.B16, V26.B16
	VCMEQ V0.B16, V19.B16, V27.B16

	VCMEQ V1.B16, V20.B16, V28.B16
	VCMEQ V1.B16, V21.B16, V29.B16
	VCMEQ V1.B16, V22.B16, V30.B16
	VCMEQ V1.B16, V23.B16, V31.B16

	// AND both
	VAND  V24.B16, V28.B16, V24.B16
	VAND  V25.B16, V29.B16, V25.B16
	VAND  V26.B16, V30.B16, V26.B16
	VAND  V27.B16, V31.B16, V27.B16

	// Quick check
	VORR  V24.B16, V25.B16, V6.B16
	VORR  V26.B16, V27.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R15

	BLS   end64_exact2
	CBZ   R15, loop64_exact2

end64_exact2:
	CBZ   R15, loop16_exact2

	// Process chunks 0-3
	MOVD  $0, R16

process_chunk64_exact2:
	CMP   $0, R16
	BEQ   chunk0_exact2
	CMP   $16, R16
	BEQ   chunk1_exact2
	CMP   $32, R16
	BEQ   chunk2_exact2
	B     chunk3_exact2

chunk0_exact2:
	VMOV  V24.B16, V6.B16
	B     extract64_exact2
chunk1_exact2:
	VMOV  V25.B16, V6.B16
	B     extract64_exact2
chunk2_exact2:
	VMOV  V26.B16, V6.B16
	B     extract64_exact2
chunk3_exact2:
	VMOV  V27.B16, V6.B16

extract64_exact2:
	VAND  V5.B16, V6.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R15
	CBZ   R15, next_chunk64_exact2

process_match64_exact2:
	RBIT  R15, R17
	CLZ   R17, R17
	LSR   $1, R17, R17

	SUB   $64, R11, R19
	ADD   R16, R19, R19
	ADD   R17, R19, R19
	SUB   R12, R19, R19

	CMP   R9, R19
	BGT   clear64_exact2

	// Verify - use R20-R22, R6 only (not R8 which holds rare2!)
	ADD   R0, R19, R20        // R20 = haystack + position
	MOVD  R2, R21             // R21 = needle
	MOVD  R3, R22             // R22 = needle_len

verify64_exact2:
	CMP   $16, R22
	BLT   verify_tail64_exact2
	VLD1  (R20), [V10.B16]
	VLD1  (R21), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBNZW R6, fail64_exact2
	ADD   $16, R20
	ADD   $16, R21
	SUBS  $16, R22, R22
	BGT   verify64_exact2
	MOVD  R19, R0
	MOVD  R0, ret+48(FP)
	RET

verify_tail64_exact2:
	CMP   $0, R22
	BLE   found64_exact2
	VLD1  (R20), [V10.B16]
	VLD1  (R21), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	MOVD  $tail_mask_table<>(SB), R6
	ADD   R22<<4, R6, R6
	VLD1  (R6), [V13.B16]
	VAND  V13.B16, V12.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBNZW R6, fail64_exact2

found64_exact2:
	MOVD  R19, R0
	MOVD  R0, ret+48(FP)
	RET

fail64_exact2:
	SUB   R12, R11, R20
	LSR   $3, R20, R20
	ADD   $32, R20
	ADD   $1, R13
	CMP   R20, R13
	BGE   exceeded64_exact2

clear64_exact2:
	ADD   $1, R17, R20
	LSL   $1, R20, R20
	MOVD  $1, R21
	LSL   R20, R21, R20
	SUB   $1, R20
	BIC   R20, R15, R15
	CBNZ  R15, process_match64_exact2

next_chunk64_exact2:
	ADD   $16, R16
	CMP   $64, R16
	BLT   process_chunk64_exact2
	CMP   $64, R10
	BGE   loop64_exact2

loop16_exact2:
	CMP   $16, R10
	BLT   scalar_exact2

loop16_inner_exact2:
	VLD1  (R11), [V16.B16]
	ADD   R5, R11, R14
	VLD1  (R14), [V17.B16]
	ADD   $16, R11
	SUBS  $16, R10, R10

	VCMEQ V0.B16, V16.B16, V19.B16
	VCMEQ V1.B16, V17.B16, V20.B16
	VAND  V19.B16, V20.B16, V19.B16

	VAND  V5.B16, V19.B16, V19.B16
	VADDP V19.B16, V19.B16, V19.B16
	VADDP V19.B16, V19.B16, V19.B16
	VMOV  V19.S[0], R15

	BLS   end16_exact2
	CBZ   R15, loop16_inner_exact2

end16_exact2:
	CBZ   R15, scalar_exact2

process16_exact2:
	RBIT  R15, R17
	CLZ   R17, R17
	LSR   $1, R17, R17

	SUB   $16, R11, R19
	ADD   R17, R19, R19
	SUB   R12, R19, R19

	CMP   R9, R19
	BGT   clear16_exact2

	// Verify - use R20-R22, R6 only (not R8 which holds rare2!)
	ADD   R0, R19, R20        // R20 = haystack + position
	MOVD  R2, R21             // R21 = needle
	MOVD  R3, R22             // R22 = needle_len

verify16_exact2:
	CMP   $16, R22
	BLT   verify_tail16_exact2
	VLD1  (R20), [V10.B16]
	VLD1  (R21), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBNZW R6, fail16_exact2
	ADD   $16, R20
	ADD   $16, R21
	SUBS  $16, R22, R22
	BGT   verify16_exact2
	MOVD  R19, R0
	MOVD  R0, ret+48(FP)
	RET

verify_tail16_exact2:
	CMP   $0, R22
	BLE   found16_exact2
	VLD1  (R20), [V10.B16]
	VLD1  (R21), [V11.B16]
	VEOR  V10.B16, V11.B16, V12.B16
	MOVD  $tail_mask_table<>(SB), R6
	ADD   R22<<4, R6, R6
	VLD1  (R6), [V13.B16]
	VAND  V13.B16, V12.B16, V12.B16
	WORD  $0x6e30a98c
	FMOVS F12, R6
	CBNZW R6, fail16_exact2

found16_exact2:
	MOVD  R19, R0
	MOVD  R0, ret+48(FP)
	RET

fail16_exact2:
	SUB   R12, R11, R20
	LSR   $3, R20, R20
	ADD   $32, R20
	ADD   $1, R13
	CMP   R20, R13
	BGE   exceeded16_exact2

clear16_exact2:
	ADD   $1, R17, R20
	LSL   $1, R20, R20
	MOVD  $1, R21
	LSL   R20, R21, R20
	SUB   $1, R20
	BIC   R20, R15, R15
	CBNZ  R15, process16_exact2
	CMP   $16, R10
	BGE   loop16_inner_exact2

scalar_exact2:
	CMP   $0, R10
	BLE   not_found_exact2

scalar_loop_exact2:
	MOVBU (R11), R15
	ADD   R5, R11, R14
	MOVBU (R14), R16

	CMP   R7, R15
	BNE   scalar_next_exact2
	CMP   R8, R16
	BNE   scalar_next_exact2

	SUB   R12, R11, R19
	CMP   R9, R19
	BGT   scalar_next_exact2

	// Verify - use R20-R22, R6, R14 only (not R8 which holds rare2!)
	ADD   R0, R19, R20        // R20 = haystack + position
	MOVD  R2, R21             // R21 = needle
	MOVD  R3, R22             // R22 = needle_len

scalar_verify_exact2:
	MOVBU (R20), R6
	MOVBU (R21), R14
	CMP   R6, R14
	BNE   scalar_fail_exact2
	ADD   $1, R20
	ADD   $1, R21
	SUBS  $1, R22, R22
	BGT   scalar_verify_exact2
	MOVD  R19, R0
	MOVD  R0, ret+48(FP)
	RET

scalar_fail_exact2:
	SUB   R12, R11, R20
	LSR   $3, R20, R20
	ADD   $32, R20
	ADD   $1, R13
	CMP   R20, R13
	BGE   exceeded_scalar_exact2

scalar_next_exact2:
	ADD   $1, R11
	SUBS  $1, R10, R10
	BGT   scalar_loop_exact2

not_found_exact2:
	MOVD  $-1, R0
	MOVD  R0, ret+48(FP)
	RET

found_zero_exact2:
	MOVD  ZR, R0
	MOVD  R0, ret+48(FP)
	RET

exceeded64_exact2:
exceeded16_exact2:
exceeded_scalar_exact2:
	MOVD  $0x8000000000000000, R20   // exceeded flag (bit 63)
	ADD   R19, R20, R0              // add position
	MOVD  R0, ret+48(FP)
	RET

// ============================================================================
// HAND-ROLLED FOLD FUNCTIONS - 128-byte loops for optimal throughput
// ============================================================================

// func indexFold1Byte(haystack string, needle string, off1 int) uint64
//
// Returns:
//   - Position if found
//   - 0xFFFFFFFFFFFFFFFF (-1) if not found
//   - 0x8000000000000000 + position if exceeded threshold (resume from position)
//
// Register allocation (matches ascii_fold_neon.s pattern):
//   R0  = haystack ptr (input)
//   R1  = haystack len (input)
//   R2  = needle ptr (input)
//   R3  = needle len (input)
//   R4  = off1 (input)
//   R9  = searchLen = haystack_len - needle_len
//   R10 = searchPtr (post-incremented by VLD1.P)
//   R11 = searchStart (for candidate offset calc)
//   R12 = remaining bytes to search
//   R13 = syndrome result / temp
//   R14 = chunk offset within 64-byte block
//   R15 = bit position temp
//   R16 = candidate position temp
//   R17 = temp for bit clearing
//   R19 = remaining needle len during verify / temp
//   R20 = block offset (64 = first block, 0 = second block in 128B mode)
//   R21 = haystack candidate ptr during verify
//   R22 = needle ptr during verify
//   R23 = temp during verify / threshold calc
//   R24 = tail_mask_table ptr (callee-saved, set once)
//   R25 = failure count (callee-saved)
//   R26 = scalar mask (0x20 for letters, 0x00 for non-letters)
//   R5 = scalar target (rare byte, lowercase if letter) [kept after setup, off1 remains in R4]
//
// Vector registers:
//   V0  = rare1 mask broadcast (0x20 or 0x00)
//   V1  = rare1 target broadcast
//   V4  = 159 (-97 as unsigned) for letter detection
//   V5  = syndrome magic constant
//   V7  = 26 (letter range check)
//   V8  = 32 (0x20 for case folding)
//   V16-V19 = first 64 bytes loaded
//   V20-V23 = compare results for first 64 bytes
//   V24-V27 = second 64 bytes loaded
//   V28-V31 = compare results for second 64 bytes
//   V6, V9-V12 = reduction temporaries

TEXT ·indexFold1Byte(SB), NOSPLIT, $0-48
	MOVD  haystack+0(FP), R0      // R0 = haystack ptr
	MOVD  haystack_len+8(FP), R1  // R1 = haystack len
	MOVD  needle+16(FP), R2       // R2 = needle ptr
	MOVD  needle_len+24(FP), R3   // R3 = needle len
	MOVD  off1+32(FP), R4         // R4 = off1

	// Early exits
	SUBS  R3, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   fold1_not_found
	CBZ   R3, fold1_found_zero

	// Load rare byte from needle[off1]
	ADD   R2, R4, R8              // R8 = needle + off1
	MOVBU (R8), R5                // R5 = rare1 byte (from normalized needle)

	// Compute mask and target for rare1
	// For letters: OR haystack with 0x20 to force lowercase, compare to lowercase target
	// For non-letters: mask with 0x00 (identity), compare exact
	// R5 = rare byte, will be kept as target
	SUBW  $97, R5, R8             // R8 = rare1 - 'a'
	CMPW  $26, R8
	BCS   fold1_not_letter
	MOVW  $0x20, R26              // mask = 0x20 (OR to force lowercase)
	B     fold1_setup
fold1_not_letter:
	MOVW  $0x00, R26              // mask = 0x00 (OR with 0 = no change)

fold1_setup:
	// R5 = target byte (rare byte from normalized needle)
	VDUP  R26, V0.B16             // V0 = rare1 mask broadcast
	VDUP  R5, V1.B16              // V1 = rare1 target broadcast

	// Syndrome magic constant for position extraction
	MOVD  $0x4010040140100401, R8
	VMOV  R8, V5.D[0]
	VMOV  R8, V5.D[1]

	// Constants for vectorized verification
	WORD  $0x4f04e7e4             // VMOVI $159, V4.B16 (-97 as unsigned)
	WORD  $0x4f00e747             // VMOVI $26, V7.B16
	WORD  $0x4f01e408             // VMOVI $32, V8.B16
	MOVD  $tail_mask_table<>(SB), R24  // R24 = tail mask table

	// Setup pointers
	ADD   R4, R0, R10             // R10 = searchPtr = haystack + off1
	MOVD  R10, R11                // R11 = searchStart
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	// Initialize failure counter
	MOVD  ZR, R25                 // R25 = failure count = 0

	// Dispatch based on letter/non-letter and size
	CBZ   R26, fold1_dispatch_nonletter

	// Letter path: check size threshold
	CMP   $768, R12               // Threshold for 128B loop
	BGE   fold1_loop128
	CMP   $32, R12
	BLT   fold1_loop16_entry

// ============================================================================
// 32-BYTE LOOP (letter path, medium inputs)
// ============================================================================
fold1_loop32:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12

	// Case-fold and compare
	VORR  V0.B16, V16.B16, V20.B16
	VORR  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16

	// Quick check: any matches?
	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13

	BLT   fold1_end32
	CBZ   R13, fold1_loop32

fold1_end32:
	CBZ   R13, fold1_loop16_entry

	// Extract syndromes
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16

	// Check chunk 0
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $128, R14               // Mark as 32-byte mode (128 = chunk0)
	CBNZ  R13, fold1_try32

	// Check chunk 1
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14               // 128 + 16 = chunk 1
	CBNZ  R13, fold1_try32

	// No matches, continue
	CMP   $32, R12
	BGE   fold1_loop32
	B     fold1_loop16_entry

fold1_try32:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	AND   $0x7F, R14, R17         // Extract actual chunk offset
	ADD   R17, R15, R15

	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16           // R16 = position in searchable range

	CMP   R9, R16
	BGT   fold1_clear32

	// Verify the match
	ADD   R0, R16, R8             // R8 = &haystack[candidate]
	B     fold1_verify

fold1_clear32:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBNZ  R13, fold1_try32

	// Move to chunk 1 if in chunk 0
	CMP   $128, R14
	BNE   fold1_continue32
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, fold1_try32

fold1_continue32:
	CMP   $32, R12
	BGE   fold1_loop32
	B     fold1_loop16_entry

// ============================================================================
// 128-BYTE LOOP (letter path, large inputs ≥768B)
// ============================================================================
fold1_loop128:
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	VLD1.P 64(R10), [V24.B16, V25.B16, V26.B16, V27.B16]
	SUB   $128, R12, R12

	// Process first 64 bytes
	VORR  V0.B16, V16.B16, V20.B16
	VORR  V0.B16, V17.B16, V21.B16
	VORR  V0.B16, V18.B16, V22.B16
	VORR  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Process second 64 bytes
	VORR  V0.B16, V24.B16, V28.B16
	VORR  V0.B16, V25.B16, V29.B16
	VORR  V0.B16, V26.B16, V30.B16
	VORR  V0.B16, V27.B16, V31.B16
	VCMEQ V1.B16, V28.B16, V28.B16
	VCMEQ V1.B16, V29.B16, V29.B16
	VCMEQ V1.B16, V30.B16, V30.B16
	VCMEQ V1.B16, V31.B16, V31.B16

	// Combine all 8 chunks for quick check
	VORR  V20.B16, V21.B16, V9.B16
	VORR  V22.B16, V23.B16, V10.B16
	VORR  V28.B16, V29.B16, V11.B16
	VORR  V30.B16, V31.B16, V12.B16
	VORR  V9.B16, V10.B16, V9.B16
	VORR  V11.B16, V12.B16, V11.B16
	VORR  V9.B16, V11.B16, V9.B16

	VADDP V9.D2, V9.D2, V9.D2
	VMOV  V9.D[0], R13

	CMP   $128, R12
	BLT   fold1_end128
	CBZ   R13, fold1_loop128

fold1_end128:
	CBZ   R13, fold1_loop32

	// Check first 64 bytes
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, fold1_first64

	// Check second 64 bytes
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, fold1_second64
	CMP   $128, R12
	BGE   fold1_loop128
	B     fold1_loop32

fold1_first64:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R20                // block offset = 64 (first block)
	B     fold1_check_chunks

fold1_second64:
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  ZR, R20                 // block offset = 0 (second block)

fold1_check_chunks:
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, fold1_try128

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, fold1_try128

	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, fold1_try128

	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, fold1_try128

	// Check if we need second 64 block
	CBNZ  R20, fold1_check_second64_after
	CMP   $128, R12
	BGE   fold1_loop128
	B     fold1_loop32

fold1_check_second64_after:
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, fold1_continue128
	B     fold1_second64

fold1_continue128:
	CMP   $128, R12
	BGE   fold1_loop128
	B     fold1_loop32

fold1_try128:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15
	SUB   R20, R15, R15
	ADD   $64, R15, R15

	SUB   $128, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   fold1_clear128

	ADD   R0, R16, R8
	B     fold1_verify

fold1_clear128:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold1_try128

	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   fold1_next_chunk
	CBNZ  R20, fold1_check_second64_after
	B     fold1_continue128

fold1_next_chunk:
	CMP   $16, R14
	BEQ   fold1_chunk1
	CMP   $32, R14
	BEQ   fold1_chunk2
	CMP   $48, R14
	BEQ   fold1_chunk3
	B     fold1_continue128

fold1_chunk1:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, fold1_try128
	ADD   $16, R14, R14
fold1_chunk2:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, fold1_try128
	ADD   $16, R14, R14
fold1_chunk3:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, fold1_try128
	CBNZ  R20, fold1_check_second64_after
	B     fold1_continue128

// ============================================================================
// NON-LETTER PATH (skips VORR for 5-op loop)
// ============================================================================
fold1_dispatch_nonletter:
	CMP   $768, R12
	BGE   fold1_loop128_nl
	CMP   $32, R12
	BLT   fold1_loop16_nl_entry

fold1_loop32_nl:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12

	// Direct compare (no case folding)
	VCMEQ V1.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V17.B16, V21.B16

	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13

	BLT   fold1_end32_nl
	CBZ   R13, fold1_loop32_nl

fold1_end32_nl:
	CBZ   R13, fold1_loop16_nl_entry

	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16

	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $128, R14
	CBNZ  R13, fold1_try32_nl

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, fold1_try32_nl

	CMP   $32, R12
	BGE   fold1_loop32_nl
	B     fold1_loop16_nl_entry

fold1_try32_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	AND   $0x7F, R14, R17
	ADD   R17, R15, R15

	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   fold1_clear32_nl

	ADD   R0, R16, R8
	B     fold1_verify

fold1_clear32_nl:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBNZ  R13, fold1_try32_nl

	CMP   $128, R14
	BNE   fold1_continue32_nl
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, fold1_try32_nl

fold1_continue32_nl:
	CMP   $32, R12
	BGE   fold1_loop32_nl
	B     fold1_loop16_nl_entry

// 128-byte non-letter loop
fold1_loop128_nl:
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	VLD1.P 64(R10), [V24.B16, V25.B16, V26.B16, V27.B16]
	SUB   $128, R12, R12

	VCMEQ V1.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V18.B16, V22.B16
	VCMEQ V1.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V24.B16, V28.B16
	VCMEQ V1.B16, V25.B16, V29.B16
	VCMEQ V1.B16, V26.B16, V30.B16
	VCMEQ V1.B16, V27.B16, V31.B16

	VORR  V20.B16, V21.B16, V9.B16
	VORR  V22.B16, V23.B16, V10.B16
	VORR  V28.B16, V29.B16, V11.B16
	VORR  V30.B16, V31.B16, V12.B16
	VORR  V9.B16, V10.B16, V9.B16
	VORR  V11.B16, V12.B16, V11.B16
	VORR  V9.B16, V11.B16, V9.B16

	VADDP V9.D2, V9.D2, V9.D2
	VMOV  V9.D[0], R13

	CMP   $128, R12
	BLT   fold1_end128_nl
	CBZ   R13, fold1_loop128_nl

fold1_end128_nl:
	CBZ   R13, fold1_loop32_nl

	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, fold1_first64_nl

	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, fold1_second64_nl
	CMP   $128, R12
	BGE   fold1_loop128_nl
	B     fold1_loop32_nl

fold1_first64_nl:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R20
	B     fold1_check_chunks_nl

fold1_second64_nl:
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  ZR, R20

fold1_check_chunks_nl:
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, fold1_try128_nl

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, fold1_try128_nl

	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, fold1_try128_nl

	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, fold1_try128_nl

	CBNZ  R20, fold1_check_second64_nl_after
	CMP   $128, R12
	BGE   fold1_loop128_nl
	B     fold1_loop32_nl

fold1_check_second64_nl_after:
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, fold1_continue128_nl
	B     fold1_second64_nl

fold1_continue128_nl:
	CMP   $128, R12
	BGE   fold1_loop128_nl
	B     fold1_loop32_nl

fold1_try128_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15
	SUB   R20, R15, R15
	ADD   $64, R15, R15

	SUB   $128, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   fold1_clear128_nl

	ADD   R0, R16, R8
	B     fold1_verify

fold1_clear128_nl:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold1_try128_nl

	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   fold1_next_chunk_nl
	CBNZ  R20, fold1_check_second64_nl_after
	B     fold1_continue128_nl

fold1_next_chunk_nl:
	CMP   $16, R14
	BEQ   fold1_chunk1_nl
	CMP   $32, R14
	BEQ   fold1_chunk2_nl
	CMP   $48, R14
	BEQ   fold1_chunk3_nl
	B     fold1_continue128_nl

fold1_chunk1_nl:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, fold1_try128_nl
	ADD   $16, R14, R14
fold1_chunk2_nl:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, fold1_try128_nl
	ADD   $16, R14, R14
fold1_chunk3_nl:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, fold1_try128_nl
	CBNZ  R20, fold1_check_second64_nl_after
	B     fold1_continue128_nl

// ============================================================================
// 16-BYTE LOOPS
// ============================================================================
fold1_loop16_entry:
	CMP   $16, R12
	BLT   fold1_scalar_entry

fold1_loop16:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VORR  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, fold1_check16_continue

fold1_try16:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   fold1_clear16

	ADD   R0, R16, R8
	MOVD  $0x100, R14             // Mark as 16-byte path
	B     fold1_verify

fold1_clear16:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold1_try16

fold1_check16_continue:
	CMP   $16, R12
	BGE   fold1_loop16

fold1_scalar_entry:
	CMP   $0, R12
	BLE   fold1_not_found

fold1_scalar:
	MOVBU (R10), R13
	ORRW  R26, R13, R14
	CMPW  R5, R14
	BNE   fold1_scalar_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   fold1_scalar_next

	ADD   R0, R16, R8
	B     fold1_verify_scalar

fold1_scalar_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, fold1_scalar
	B     fold1_not_found

// 16-byte non-letter path
fold1_loop16_nl_entry:
	CMP   $16, R12
	BLT   fold1_scalar_nl_entry

fold1_loop16_nl:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VCMEQ V1.B16, V16.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, fold1_check16_nl_continue

fold1_try16_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   fold1_clear16_nl

	ADD   R0, R16, R8
	MOVD  $0x100, R14
	B     fold1_verify

fold1_clear16_nl:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold1_try16_nl

fold1_check16_nl_continue:
	CMP   $16, R12
	BGE   fold1_loop16_nl

fold1_scalar_nl_entry:
	CMP   $0, R12
	BLE   fold1_not_found

fold1_scalar_nl:
	MOVBU (R10), R13
	CMPW  R5, R13
	BNE   fold1_scalar_nl_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   fold1_scalar_nl_next

	ADD   R0, R16, R8
	B     fold1_verify_scalar_nl

fold1_scalar_nl_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, fold1_scalar_nl
	B     fold1_not_found

// ============================================================================
// SCALAR VERIFICATION (separate paths to avoid syndrome-clearing logic)
// ============================================================================
fold1_verify_scalar:
	MOVD  R3, R19                 // R19 = remaining needle length
	MOVD  R8, R21                 // R21 = haystack candidate ptr
	MOVD  R2, R22                 // R22 = needle ptr

fold1_scalar_vloop:
	SUBS  $16, R19, R23
	BLT   fold1_scalar_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V13.B16
	VADD  V4.B16, V13.B16, V13.B16
	WORD  $0x6e2d34ed               // VCMHI V13.B16, V7.B16, V13.B16
	VAND  V14.B16, V13.B16, V13.B16
	VAND  V8.B16, V13.B16, V13.B16
	VEOR  V13.B16, V12.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, fold1_scalar_vloop
	B     fold1_scalar_verify_fail

fold1_scalar_vtail:
	CMP   $1, R19
	BLT   fold1_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V15.B16
	VADD  V4.B16, V15.B16, V15.B16
	WORD  $0x6e2f34ef               // VCMHI V15.B16, V7.B16, V15.B16
	VAND  V14.B16, V15.B16, V15.B16
	VAND  V8.B16, V15.B16, V15.B16
	VEOR  V15.B16, V12.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, fold1_scalar_verify_fail
	B     fold1_found

fold1_scalar_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   fold1_exceeded
	B     fold1_scalar_next

fold1_verify_scalar_nl:
	MOVD  R3, R19
	MOVD  R8, R21
	MOVD  R2, R22

fold1_scalar_nl_vloop:
	SUBS  $16, R19, R23
	BLT   fold1_scalar_nl_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V13.B16
	VADD  V4.B16, V13.B16, V13.B16
	WORD  $0x6e2d34ed               // VCMHI V13.B16, V7.B16, V13.B16
	VAND  V14.B16, V13.B16, V13.B16
	VAND  V8.B16, V13.B16, V13.B16
	VEOR  V13.B16, V12.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, fold1_scalar_nl_vloop
	B     fold1_scalar_nl_verify_fail

fold1_scalar_nl_vtail:
	CMP   $1, R19
	BLT   fold1_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V15.B16
	VADD  V4.B16, V15.B16, V15.B16
	WORD  $0x6e2f34ef               // VCMHI V15.B16, V7.B16, V15.B16
	VAND  V14.B16, V15.B16, V15.B16
	VAND  V8.B16, V15.B16, V15.B16
	VEOR  V15.B16, V12.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, fold1_scalar_nl_verify_fail
	B     fold1_found

fold1_scalar_nl_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   fold1_exceeded
	B     fold1_scalar_nl_next

// ============================================================================
// SIMD VERIFICATION (for 16/32/128-byte loop paths)
// ============================================================================
fold1_verify:
	MOVD  R3, R19                 // R19 = remaining needle length
	MOVD  R8, R21                 // R21 = haystack candidate ptr
	MOVD  R2, R22                 // R22 = needle ptr

fold1_vloop:
	SUBS  $16, R19, R23
	BLT   fold1_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	// Case-insensitive compare: XOR + check if diff is 0x20 for letters
	VEOR  V10.B16, V11.B16, V12.B16 // V12 = XOR diff
	VCMEQ V8.B16, V12.B16, V14.B16  // V14 = (XOR == 0x20)
	VORR  V8.B16, V10.B16, V13.B16  // V13 = h | 0x20 (force lowercase)
	VADD  V4.B16, V13.B16, V13.B16  // V13 = (h|0x20) + 159 (-97)
	WORD  $0x6e2d34ed               // VCMHI V13.B16, V7.B16, V13.B16 (is letter: <26)
	VAND  V14.B16, V13.B16, V13.B16 // Both conditions: XOR==0x20 && is_letter
	VAND  V8.B16, V13.B16, V13.B16  // V13 = mask ? 0x20 : 0
	VEOR  V13.B16, V12.B16, V10.B16 // Mask out case difference
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10 (any non-zero?)
	FMOVS F10, R23
	CBZW  R23, fold1_vloop
	B     fold1_verify_fail

fold1_vtail:
	CMP   $1, R19
	BLT   fold1_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V15.B16
	VADD  V4.B16, V15.B16, V15.B16
	WORD  $0x6e2f34ef               // VCMHI V15.B16, V7.B16, V15.B16
	VAND  V14.B16, V15.B16, V15.B16
	VAND  V8.B16, V15.B16, V15.B16
	VEOR  V15.B16, V12.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16 // Mask out bytes beyond needle
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, fold1_verify_fail
	B     fold1_found

fold1_verify_fail:
	// Increment failure counter and check threshold
	ADD   $1, R25, R25
	SUB   R11, R10, R17           // bytes_scanned
	LSR   $3, R17, R17            // >> 3 (allow 1 failure per 8 bytes)
	ADD   $32, R17, R17           // threshold = 32 + (bytes_scanned >> 3)
	CMP   R17, R25
	BGT   fold1_exceeded

	// Clear bit and continue - use R14 to determine which loop
	CMP   $0x100, R14
	BEQ   fold1_clear16_from_verify
	CMP   $64, R14
	BLT   fold1_clear128_from_verify
	B     fold1_clear32_from_verify

fold1_clear16_from_verify:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBZ   R26, fold1_clear16_nl_from_verify
	CBNZ  R13, fold1_try16
	B     fold1_check16_continue

fold1_clear16_nl_from_verify:
	CBNZ  R13, fold1_try16_nl
	B     fold1_check16_nl_continue

fold1_clear128_from_verify:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBZ   R26, fold1_try128_nl_retry
	CBNZ  R13, fold1_try128
	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   fold1_next_chunk
	CBNZ  R20, fold1_check_second64_after
	B     fold1_continue128

fold1_try128_nl_retry:
	CBNZ  R13, fold1_try128_nl
	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   fold1_next_chunk_nl
	CBNZ  R20, fold1_check_second64_nl_after
	B     fold1_continue128_nl

fold1_clear32_from_verify:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBZ   R26, fold1_try32_nl_retry
	CBNZ  R13, fold1_try32
	CMP   $128, R14
	BNE   fold1_continue32
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, fold1_try32
	B     fold1_continue32

fold1_try32_nl_retry:
	CBNZ  R13, fold1_try32_nl
	CMP   $128, R14
	BNE   fold1_continue32_nl
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, fold1_try32_nl
	B     fold1_continue32_nl

// ============================================================================
// EXIT PATHS
// ============================================================================
fold1_exceeded:
	MOVD  $0x8000000000000000, R17   // exceeded flag (bit 63)
	ADD   R16, R17, R0              // add position
	MOVD  R0, ret+40(FP)
	RET

fold1_not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+40(FP)
	RET

fold1_found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+40(FP)
	RET

fold1_found:
	MOVD  R16, R0
	MOVD  R0, ret+40(FP)
	RET

// ============================================================================
// indexFold2Byte - Case-insensitive 2-byte filter with pre-normalized needle
//
// func indexFold2Byte(haystack string, needle string, off1 int, off2_delta int) uint64
//
// Returns:
//   - Position if found
//   - 0xFFFFFFFFFFFFFFFF (-1) if not found
//   - 0x8000000000000000 + position if exceeded threshold
//
// Register allocation:
//   R0  = haystack ptr
//   R1  = haystack len
//   R2  = needle ptr
//   R3  = needle len
//   R4  = off1
//   R5  = off2_delta
//   R6  = rare1 byte (from normalized needle)
//   R7  = rare2 byte (from normalized needle)
//   R8  = rare1 mask (0x20 for letter, 0x00 for non-letter)
//   R9  = searchLen = haystack_len - needle_len
//   R10 = searchPtr (post-incremented by VLD1.P)
//   R11 = searchStart
//   R12 = remaining bytes
//   R13 = syndrome result
//   R14 = path marker / chunk offset
//   R15 = bit position
//   R16 = candidate position
//   R24 = tail_mask_table ptr
//   R25 = failure count
//   R26 = rare2 mask (0x20 for letter, 0x00 for non-letter)
//
// Vector registers:
//   V0  = rare1 mask broadcast
//   V1  = rare1 target broadcast
//   V2  = rare2 mask broadcast
//   V3  = rare2 target broadcast
//   V4  = 159 (-97 as unsigned) for letter detection in verify
//   V5  = syndrome magic constant
//   V7  = 26 (letter range check)
//   V8  = 32 (0x20 for case folding)
// ============================================================================

TEXT ·indexFold2Byte(SB), NOSPLIT, $0-56
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVD  needle+16(FP), R2
	MOVD  needle_len+24(FP), R3
	MOVD  off1+32(FP), R4
	MOVD  off2_delta+40(FP), R5

	// Early exits
	SUBS  R3, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   fold2_not_found
	CBZ   R3, fold2_found_zero

	// Load rare bytes from normalized needle[off1] and needle[off1+off2_delta]
	ADD   R2, R4, R17             // R17 = needle + off1
	MOVBU (R17), R6               // R6 = rare1 byte
	ADD   R17, R5, R17            // R17 = needle + off1 + off2_delta
	MOVBU (R17), R7               // R7 = rare2 byte

	// Compute masks for rare1 and rare2
	// For letters: OR haystack with 0x20 to force lowercase, compare to lowercase target
	// For non-letters: OR with 0x00 (identity)
	SUBW  $97, R6, R17            // R17 = rare1 - 'a'
	CMPW  $26, R17
	BCS   fold2_rare1_not_letter
	MOVW  $0x20, R8               // rare1 mask = 0x20
	B     fold2_check_rare2
fold2_rare1_not_letter:
	MOVW  $0x00, R8               // rare1 mask = 0x00

fold2_check_rare2:
	SUBW  $97, R7, R17            // R17 = rare2 - 'a'
	CMPW  $26, R17
	BCS   fold2_rare2_not_letter
	MOVW  $0x20, R26              // rare2 mask = 0x20
	B     fold2_setup
fold2_rare2_not_letter:
	MOVW  $0x00, R26              // rare2 mask = 0x00

fold2_setup:
	// Broadcast masks and targets
	VDUP  R8, V0.B16              // V0 = rare1 mask
	VDUP  R6, V1.B16              // V1 = rare1 target
	VDUP  R26, V2.B16             // V2 = rare2 mask
	VDUP  R7, V3.B16              // V3 = rare2 target

	// Syndrome magic constant
	MOVD  $0x4010040140100401, R17
	VMOV  R17, V5.D[0]
	VMOV  R17, V5.D[1]

	// Constants for verification
	WORD  $0x4f04e7e4             // VMOVI $159, V4.B16 (-97 as unsigned)
	WORD  $0x4f00e747             // VMOVI $26, V7.B16
	WORD  $0x4f01e408             // VMOVI $32, V8.B16
	MOVD  $tail_mask_table<>(SB), R24

	// Setup pointers
	ADD   R4, R0, R10             // R10 = searchPtr = haystack + off1
	MOVD  R10, R11                // R11 = searchStart
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	// Initialize failure counter
	MOVD  ZR, R25                 // R25 = failure count = 0

	CMP   $64, R12
	BLT   fold2_loop16_entry

// ============================================================================
// 64-BYTE LOOP: Process 64 bytes per iteration
// ============================================================================
fold2_loop64:
	// Load 64 bytes at rare1 position
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]

	// Load 64 bytes at rare2 position (R10-64+off2_delta)
	SUB   $64, R10, R14
	ADD   R5, R14, R14
	VLD1  (R14), [V24.B16, V25.B16, V26.B16, V27.B16]

	SUB   $64, R12, R12

	// Case-fold and compare rare1
	VORR  V0.B16, V16.B16, V20.B16
	VORR  V0.B16, V17.B16, V21.B16
	VORR  V0.B16, V18.B16, V22.B16
	VORR  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Case-fold and compare rare2
	VORR  V2.B16, V24.B16, V28.B16
	VORR  V2.B16, V25.B16, V29.B16
	VORR  V2.B16, V26.B16, V30.B16
	VORR  V2.B16, V27.B16, V31.B16
	VCMEQ V3.B16, V28.B16, V28.B16
	VCMEQ V3.B16, V29.B16, V29.B16
	VCMEQ V3.B16, V30.B16, V30.B16
	VCMEQ V3.B16, V31.B16, V31.B16

	// AND both results
	VAND  V20.B16, V28.B16, V20.B16
	VAND  V21.B16, V29.B16, V21.B16
	VAND  V22.B16, V30.B16, V22.B16
	VAND  V23.B16, V31.B16, V23.B16

	// Quick check: any match?
	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13

	CMP   $64, R12
	BLT   fold2_end64
	CBZ   R13, fold2_loop64

fold2_end64:
	CBZ   R13, fold2_loop16_entry

	// Extract syndromes
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16

	// Check chunks 0-3
	MOVD  $0, R14                 // chunk offset

fold2_check_chunk64:
	CMP   $0, R14
	BEQ   fold2_chunk64_0
	CMP   $16, R14
	BEQ   fold2_chunk64_1
	CMP   $32, R14
	BEQ   fold2_chunk64_2
	B     fold2_chunk64_3

fold2_chunk64_0:
	VADDP V20.B16, V20.B16, V6.B16
	B     fold2_extract64
fold2_chunk64_1:
	VADDP V21.B16, V21.B16, V6.B16
	B     fold2_extract64
fold2_chunk64_2:
	VADDP V22.B16, V22.B16, V6.B16
	B     fold2_extract64
fold2_chunk64_3:
	VADDP V23.B16, V23.B16, V6.B16

fold2_extract64:
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBZ   R13, fold2_next_chunk64

fold2_try64:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $64, R10, R16
	ADD   R14, R16, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16           // R16 = candidate position

	CMP   R9, R16
	BGT   fold2_clear64

	// Verify match
	ADD   R0, R16, R17            // R17 = &haystack[candidate]
	B     fold2_verify

fold2_clear64:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold2_try64

fold2_next_chunk64:
	ADD   $16, R14
	CMP   $64, R14
	BLT   fold2_check_chunk64
	CMP   $64, R12
	BGE   fold2_loop64

// ============================================================================
// 16-BYTE LOOP
// ============================================================================
fold2_loop16_entry:
	CMP   $16, R12
	BLT   fold2_scalar_entry

fold2_loop16:
	// Load 16 bytes at rare1 position
	VLD1  (R10), [V16.B16]
	// Load 16 bytes at rare2 position
	ADD   R5, R10, R14
	VLD1  (R14), [V17.B16]
	ADD   $16, R10
	SUB   $16, R12, R12

	// Case-fold and compare
	VORR  V0.B16, V16.B16, V20.B16
	VORR  V2.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V3.B16, V21.B16, V21.B16
	VAND  V20.B16, V21.B16, V20.B16

	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13

	CMP   $16, R12
	BLT   fold2_end16
	CBZ   R13, fold2_loop16

fold2_end16:
	CBZ   R13, fold2_scalar_entry

fold2_try16:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   fold2_clear16

	ADD   R0, R16, R17
	MOVD  $0x100, R14             // Mark as 16-byte path
	B     fold2_verify

fold2_clear16:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold2_try16
	CMP   $16, R12
	BGE   fold2_loop16

// ============================================================================
// SCALAR LOOP
// ============================================================================
fold2_scalar_entry:
	CMP   $0, R12
	BLE   fold2_not_found

fold2_scalar:
	// Load bytes at rare1 and rare2 positions
	MOVBU (R10), R13
	ADD   R5, R10, R14
	MOVBU (R14), R14

	// Case-fold and compare rare1
	ORRW  R8, R13, R15
	CMPW  R6, R15
	BNE   fold2_scalar_next

	// Case-fold and compare rare2
	ORRW  R26, R14, R15
	CMPW  R7, R15
	BNE   fold2_scalar_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   fold2_scalar_next

	ADD   R0, R16, R17
	B     fold2_verify_scalar

fold2_scalar_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, fold2_scalar
	B     fold2_not_found

// ============================================================================
// SCALAR VERIFICATION (separate path to avoid syndrome-clearing logic)
// ============================================================================
fold2_verify_scalar:
	MOVD  R3, R19                 // R19 = remaining needle length
	MOVD  R17, R21                // R21 = haystack candidate ptr
	MOVD  R2, R22                 // R22 = needle ptr

fold2_scalar_vloop:
	SUBS  $16, R19, R23
	BLT   fold2_scalar_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	// Case-insensitive compare: XOR + check if diff is 0x20 for letters
	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V13.B16
	VADD  V4.B16, V13.B16, V13.B16
	WORD  $0x6e2d34ed               // VCMHI V13.B16, V7.B16, V13.B16
	VAND  V14.B16, V13.B16, V13.B16
	VAND  V8.B16, V13.B16, V13.B16
	VEOR  V13.B16, V12.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, fold2_scalar_vloop
	B     fold2_scalar_verify_fail

fold2_scalar_vtail:
	CMP   $1, R19
	BLT   fold2_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V15.B16
	VADD  V4.B16, V15.B16, V15.B16
	WORD  $0x6e2f34ef               // VCMHI V15.B16, V7.B16, V15.B16
	VAND  V14.B16, V15.B16, V15.B16
	VAND  V8.B16, V15.B16, V15.B16
	VEOR  V15.B16, V12.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, fold2_scalar_verify_fail
	B     fold2_found

fold2_scalar_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   fold2_exceeded
	B     fold2_scalar_next

// ============================================================================
// SIMD VERIFICATION (for 16/64-byte loop paths)
// ============================================================================
fold2_verify:
	MOVD  R3, R19                 // R19 = remaining needle length
	MOVD  R17, R21                // R21 = haystack candidate ptr
	MOVD  R2, R22                 // R22 = needle ptr

fold2_vloop:
	SUBS  $16, R19, R23
	BLT   fold2_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V13.B16
	VADD  V4.B16, V13.B16, V13.B16
	WORD  $0x6e2d34ed               // VCMHI V13.B16, V7.B16, V13.B16
	VAND  V14.B16, V13.B16, V13.B16
	VAND  V8.B16, V13.B16, V13.B16
	VEOR  V13.B16, V12.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, fold2_vloop
	B     fold2_verify_fail

fold2_vtail:
	CMP   $1, R19
	BLT   fold2_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VEOR  V10.B16, V11.B16, V12.B16
	VCMEQ V8.B16, V12.B16, V14.B16
	VORR  V8.B16, V10.B16, V15.B16
	VADD  V4.B16, V15.B16, V15.B16
	WORD  $0x6e2f34ef               // VCMHI V15.B16, V7.B16, V15.B16
	VAND  V14.B16, V15.B16, V15.B16
	VAND  V8.B16, V15.B16, V15.B16
	VEOR  V15.B16, V12.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, fold2_verify_fail
	B     fold2_found

fold2_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   fold2_exceeded

	// Clear bit and continue
	CMP   $0x100, R14
	BEQ   fold2_clear16_from_verify
	B     fold2_clear64_from_verify

fold2_clear16_from_verify:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold2_try16
	CMP   $16, R12
	BGE   fold2_loop16
	B     fold2_scalar_entry

fold2_clear64_from_verify:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, fold2_try64
	ADD   $16, R14
	CMP   $64, R14
	BLT   fold2_check_chunk64
	CMP   $64, R12
	BGE   fold2_loop64
	B     fold2_loop16_entry

// ============================================================================
// EXIT PATHS
// ============================================================================
fold2_exceeded:
	MOVD  $0x8000000000000000, R17
	ADD   R16, R17, R0
	MOVD  R0, ret+48(FP)
	RET

fold2_not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+48(FP)
	RET

fold2_found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+48(FP)
	RET

fold2_found:
	MOVD  R16, R0
	MOVD  R0, ret+48(FP)
	RET

// func indexFold1ByteRaw(haystack string, needle string, off1 int) uint64
//
// Same as indexFold1Byte but normalizes needle byte on-the-fly (uppercase→lowercase)
// and uses dual-normalize verification (normalizes both haystack AND needle).
//
// Returns:
//   - Position if found
//   - 0xFFFFFFFFFFFFFFFF (-1) if not found
//   - 0x8000000000000000 + position if exceeded threshold (resume from position)

TEXT ·indexFold1ByteRaw(SB), NOSPLIT, $0-48
	MOVD  haystack+0(FP), R0      // R0 = haystack ptr
	MOVD  haystack_len+8(FP), R1  // R1 = haystack len
	MOVD  needle+16(FP), R2       // R2 = needle ptr
	MOVD  needle_len+24(FP), R3   // R3 = needle len
	MOVD  off1+32(FP), R4         // R4 = off1

	// Early exits
	SUBS  R3, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   raw1_not_found
	CBZ   R3, raw1_found_zero

	// Load byte from needle[off1] and normalize (uppercase → lowercase)
	ADD   R2, R4, R8              // R8 = needle + off1
	MOVBU (R8), R5                // R5 = raw byte from needle
	SUBW  $65, R5, R8             // R8 = byte - 'A'
	ORRW  $32, R5, R6             // R6 = byte | 0x20 (lowercase)
	CMPW  $26, R8                 // if (byte - 'A') < 26, it's uppercase
	CSELW LO, R6, R5, R5          // R5 = normalized byte (lowercase if was uppercase)

	// Compute mask and target for rare1 (same as indexFold1Byte)
	// R5 = normalized byte (lowercase if letter), keep it as target
	SUBW  $97, R5, R8             // R8 = byte - 'a'
	CMPW  $26, R8
	BCS   raw1_not_letter
	MOVW  $0x20, R26              // mask = 0x20 (OR to force lowercase)
	B     raw1_setup
raw1_not_letter:
	MOVW  $0x00, R26              // mask = 0x00 (identity)

raw1_setup:
	// R5 = target byte (already holds normalized byte)
	VDUP  R26, V0.B16             // V0 = mask broadcast
	VDUP  R5, V1.B16              // V1 = target broadcast

	// Syndrome magic constant
	MOVD  $0x4010040140100401, R8
	VMOV  R8, V5.D[0]
	VMOV  R8, V5.D[1]

	// Constants for dual-normalize verification
	// V2 = 191 (-65 as unsigned), V3 = 26, V4 = 32 (0x20)
	WORD  $0x4f05e7e2             // VMOVI $191, V2.B16
	WORD  $0x4f00e743             // VMOVI $26, V3.B16
	WORD  $0x4f01e404             // VMOVI $32, V4.B16
	MOVD  $tail_mask_table<>(SB), R24  // R24 = tail mask table

	// Setup pointers
	ADD   R4, R0, R10             // R10 = searchPtr = haystack + off1
	MOVD  R10, R11                // R11 = searchStart
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	// Initialize failure counter
	MOVD  ZR, R25                 // R25 = failure count = 0

	// Dispatch based on letter/non-letter and size
	CBZ   R26, raw1_dispatch_nonletter

	// Letter path: check size threshold
	CMP   $768, R12
	BGE   raw1_loop128
	CMP   $32, R12
	BLT   raw1_loop16_entry

// ============================================================================
// 32-BYTE LOOP (letter path)
// ============================================================================
raw1_loop32:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12

	VORR  V0.B16, V16.B16, V20.B16
	VORR  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16

	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13

	BLT   raw1_end32
	CBZ   R13, raw1_loop32

raw1_end32:
	CBZ   R13, raw1_loop16_entry

	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16

	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $128, R14
	CBNZ  R13, raw1_try32

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, raw1_try32

	CMP   $32, R12
	BGE   raw1_loop32
	B     raw1_loop16_entry

raw1_try32:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	AND   $0x7F, R14, R17
	ADD   R17, R15, R15

	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw1_clear32

	ADD   R0, R16, R8
	B     raw1_verify

raw1_clear32:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBNZ  R13, raw1_try32

	CMP   $128, R14
	BNE   raw1_continue32
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, raw1_try32

raw1_continue32:
	CMP   $32, R12
	BGE   raw1_loop32
	B     raw1_loop16_entry

// ============================================================================
// 128-BYTE LOOP (letter path)
// ============================================================================
raw1_loop128:
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	VLD1.P 64(R10), [V24.B16, V25.B16, V26.B16, V27.B16]
	SUB   $128, R12, R12

	VORR  V0.B16, V16.B16, V20.B16
	VORR  V0.B16, V17.B16, V21.B16
	VORR  V0.B16, V18.B16, V22.B16
	VORR  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	VORR  V0.B16, V24.B16, V28.B16
	VORR  V0.B16, V25.B16, V29.B16
	VORR  V0.B16, V26.B16, V30.B16
	VORR  V0.B16, V27.B16, V31.B16
	VCMEQ V1.B16, V28.B16, V28.B16
	VCMEQ V1.B16, V29.B16, V29.B16
	VCMEQ V1.B16, V30.B16, V30.B16
	VCMEQ V1.B16, V31.B16, V31.B16

	VORR  V20.B16, V21.B16, V9.B16
	VORR  V22.B16, V23.B16, V10.B16
	VORR  V28.B16, V29.B16, V11.B16
	VORR  V30.B16, V31.B16, V12.B16
	VORR  V9.B16, V10.B16, V9.B16
	VORR  V11.B16, V12.B16, V11.B16
	VORR  V9.B16, V11.B16, V9.B16

	VADDP V9.D2, V9.D2, V9.D2
	VMOV  V9.D[0], R13

	CMP   $128, R12
	BLT   raw1_end128
	CBZ   R13, raw1_loop128

raw1_end128:
	CBZ   R13, raw1_loop32

	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, raw1_first64

	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, raw1_second64
	CMP   $128, R12
	BGE   raw1_loop128
	B     raw1_loop32

raw1_first64:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R20
	B     raw1_check_chunks

raw1_second64:
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  ZR, R20

raw1_check_chunks:
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, raw1_try128

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, raw1_try128

	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, raw1_try128

	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, raw1_try128

	CBNZ  R20, raw1_check_second64_after
	CMP   $128, R12
	BGE   raw1_loop128
	B     raw1_loop32

raw1_check_second64_after:
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, raw1_continue128
	B     raw1_second64

raw1_continue128:
	CMP   $128, R12
	BGE   raw1_loop128
	B     raw1_loop32

raw1_try128:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15
	SUB   R20, R15, R15
	ADD   $64, R15, R15

	SUB   $128, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw1_clear128

	ADD   R0, R16, R8
	B     raw1_verify

raw1_clear128:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw1_try128

	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   raw1_next_chunk
	CBNZ  R20, raw1_check_second64_after
	B     raw1_continue128

raw1_next_chunk:
	CMP   $16, R14
	BEQ   raw1_chunk1
	CMP   $32, R14
	BEQ   raw1_chunk2
	CMP   $48, R14
	BEQ   raw1_chunk3
	B     raw1_continue128

raw1_chunk1:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, raw1_try128
	ADD   $16, R14, R14
raw1_chunk2:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, raw1_try128
	ADD   $16, R14, R14
raw1_chunk3:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, raw1_try128
	CBNZ  R20, raw1_check_second64_after
	B     raw1_continue128

// ============================================================================
// NON-LETTER PATH (skips VORR for 5-op loop)
// ============================================================================
raw1_dispatch_nonletter:
	CMP   $768, R12
	BGE   raw1_loop128_nl
	CMP   $32, R12
	BLT   raw1_loop16_nl_entry

raw1_loop32_nl:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12

	VCMEQ V1.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V17.B16, V21.B16

	VORR  V20.B16, V21.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13

	BLT   raw1_end32_nl
	CBZ   R13, raw1_loop32_nl

raw1_end32_nl:
	CBZ   R13, raw1_loop16_nl_entry

	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16

	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $128, R14
	CBNZ  R13, raw1_try32_nl

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, raw1_try32_nl

	CMP   $32, R12
	BGE   raw1_loop32_nl
	B     raw1_loop16_nl_entry

raw1_try32_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	AND   $0x7F, R14, R17
	ADD   R17, R15, R15

	SUB   $32, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw1_clear32_nl

	ADD   R0, R16, R8
	B     raw1_verify

raw1_clear32_nl:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBNZ  R13, raw1_try32_nl

	CMP   $128, R14
	BNE   raw1_continue32_nl
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, raw1_try32_nl

raw1_continue32_nl:
	CMP   $32, R12
	BGE   raw1_loop32_nl
	B     raw1_loop16_nl_entry

// 128-byte non-letter loop
raw1_loop128_nl:
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]
	VLD1.P 64(R10), [V24.B16, V25.B16, V26.B16, V27.B16]
	SUB   $128, R12, R12

	VCMEQ V1.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V18.B16, V22.B16
	VCMEQ V1.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V24.B16, V28.B16
	VCMEQ V1.B16, V25.B16, V29.B16
	VCMEQ V1.B16, V26.B16, V30.B16
	VCMEQ V1.B16, V27.B16, V31.B16

	VORR  V20.B16, V21.B16, V9.B16
	VORR  V22.B16, V23.B16, V10.B16
	VORR  V28.B16, V29.B16, V11.B16
	VORR  V30.B16, V31.B16, V12.B16
	VORR  V9.B16, V10.B16, V9.B16
	VORR  V11.B16, V12.B16, V11.B16
	VORR  V9.B16, V11.B16, V9.B16

	VADDP V9.D2, V9.D2, V9.D2
	VMOV  V9.D[0], R13

	CMP   $128, R12
	BLT   raw1_end128_nl
	CBZ   R13, raw1_loop128_nl

raw1_end128_nl:
	CBZ   R13, raw1_loop32_nl

	VORR  V20.B16, V21.B16, V6.B16
	VORR  V22.B16, V23.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, raw1_first64_nl

	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBNZ  R13, raw1_second64_nl
	CMP   $128, R12
	BGE   raw1_loop128_nl
	B     raw1_loop32_nl

raw1_first64_nl:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  $64, R20
	B     raw1_check_chunks_nl

raw1_second64_nl:
	VMOV  V28.B16, V20.B16
	VMOV  V29.B16, V21.B16
	VMOV  V30.B16, V22.B16
	VMOV  V31.B16, V23.B16
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16
	MOVD  ZR, R20

raw1_check_chunks_nl:
	VADDP V20.B16, V20.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  ZR, R14
	CBNZ  R13, raw1_try128_nl

	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $16, R14
	CBNZ  R13, raw1_try128_nl

	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $32, R14
	CBNZ  R13, raw1_try128_nl

	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $48, R14
	CBNZ  R13, raw1_try128_nl

	CBNZ  R20, raw1_check_second64_nl_after
	CMP   $128, R12
	BGE   raw1_loop128_nl
	B     raw1_loop32_nl

raw1_check_second64_nl_after:
	VORR  V28.B16, V29.B16, V6.B16
	VORR  V30.B16, V31.B16, V9.B16
	VORR  V6.B16, V9.B16, V6.B16
	VADDP V6.D2, V6.D2, V6.D2
	VMOV  V6.D[0], R13
	CBZ   R13, raw1_continue128_nl
	B     raw1_second64_nl

raw1_continue128_nl:
	CMP   $128, R12
	BGE   raw1_loop128_nl
	B     raw1_loop32_nl

raw1_try128_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15
	ADD   R14, R15, R15
	SUB   R20, R15, R15
	ADD   $64, R15, R15

	SUB   $128, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw1_clear128_nl

	ADD   R0, R16, R8
	B     raw1_verify

raw1_clear128_nl:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw1_try128_nl

	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   raw1_next_chunk_nl
	CBNZ  R20, raw1_check_second64_nl_after
	B     raw1_continue128_nl

raw1_next_chunk_nl:
	CMP   $16, R14
	BEQ   raw1_chunk1_nl
	CMP   $32, R14
	BEQ   raw1_chunk2_nl
	CMP   $48, R14
	BEQ   raw1_chunk3_nl
	B     raw1_continue128_nl

raw1_chunk1_nl:
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, raw1_try128_nl
	ADD   $16, R14, R14
raw1_chunk2_nl:
	VADDP V22.B16, V22.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, raw1_try128_nl
	ADD   $16, R14, R14
raw1_chunk3_nl:
	VADDP V23.B16, V23.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	CBNZ  R13, raw1_try128_nl
	CBNZ  R20, raw1_check_second64_nl_after
	B     raw1_continue128_nl

// ============================================================================
// 16-BYTE LOOPS
// ============================================================================
raw1_loop16_entry:
	CMP   $16, R12
	BLT   raw1_scalar_entry

raw1_loop16:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VORR  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, raw1_check16_continue

raw1_try16:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw1_clear16

	ADD   R0, R16, R8
	MOVD  $0x100, R14
	B     raw1_verify

raw1_clear16:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw1_try16

raw1_check16_continue:
	CMP   $16, R12
	BGE   raw1_loop16

raw1_scalar_entry:
	CMP   $0, R12
	BLE   raw1_not_found

raw1_scalar:
	MOVBU (R10), R13
	ORRW  R26, R13, R14
	CMPW  R5, R14
	BNE   raw1_scalar_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   raw1_scalar_next

	ADD   R0, R16, R8
	B     raw1_verify_scalar

raw1_scalar_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, raw1_scalar
	B     raw1_not_found

// 16-byte non-letter path
raw1_loop16_nl_entry:
	CMP   $16, R12
	BLT   raw1_scalar_nl_entry

raw1_loop16_nl:
	VLD1.P 16(R10), [V16.B16]
	SUB   $16, R12, R12

	VCMEQ V1.B16, V16.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13
	CBZ   R13, raw1_check16_nl_continue

raw1_try16_nl:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw1_clear16_nl

	ADD   R0, R16, R8
	MOVD  $0x100, R14
	B     raw1_verify

raw1_clear16_nl:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw1_try16_nl

raw1_check16_nl_continue:
	CMP   $16, R12
	BGE   raw1_loop16_nl

raw1_scalar_nl_entry:
	CMP   $0, R12
	BLE   raw1_not_found

raw1_scalar_nl:
	MOVBU (R10), R13
	CMPW  R5, R13
	BNE   raw1_scalar_nl_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   raw1_scalar_nl_next

	ADD   R0, R16, R8
	B     raw1_verify_scalar_nl

raw1_scalar_nl_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, raw1_scalar_nl
	B     raw1_not_found

// ============================================================================
// SCALAR VERIFICATION (separate paths to avoid syndrome-clearing logic)
// Dual-normalizes BOTH haystack AND needle (for raw needle input)
// ============================================================================
raw1_verify_scalar:
	MOVD  R3, R19                 // R19 = remaining needle length
	MOVD  R8, R21                 // R21 = haystack candidate ptr
	MOVD  R2, R22                 // R22 = needle ptr

raw1_scalar_vloop:
	SUBS  $16, R19, R23
	BLT   raw1_scalar_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VADD  V2.B16, V10.B16, V16.B16
	VADD  V2.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V3.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V3.B16, V17.B16
	VAND  V4.B16, V16.B16, V16.B16
	VAND  V4.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, raw1_scalar_vloop
	B     raw1_scalar_verify_fail

raw1_scalar_vtail:
	CMP   $1, R19
	BLT   raw1_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VADD  V2.B16, V10.B16, V16.B16
	VADD  V2.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V3.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V3.B16, V17.B16
	VAND  V4.B16, V16.B16, V16.B16
	VAND  V4.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, raw1_scalar_verify_fail
	B     raw1_found

raw1_scalar_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   raw1_exceeded
	B     raw1_scalar_next

raw1_verify_scalar_nl:
	MOVD  R3, R19
	MOVD  R8, R21
	MOVD  R2, R22

raw1_scalar_nl_vloop:
	SUBS  $16, R19, R23
	BLT   raw1_scalar_nl_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VADD  V2.B16, V10.B16, V16.B16
	VADD  V2.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V3.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V3.B16, V17.B16
	VAND  V4.B16, V16.B16, V16.B16
	VAND  V4.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, raw1_scalar_nl_vloop
	B     raw1_scalar_nl_verify_fail

raw1_scalar_nl_vtail:
	CMP   $1, R19
	BLT   raw1_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VADD  V2.B16, V10.B16, V16.B16
	VADD  V2.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V3.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V3.B16, V17.B16
	VAND  V4.B16, V16.B16, V16.B16
	VAND  V4.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, raw1_scalar_nl_verify_fail
	B     raw1_found

raw1_scalar_nl_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   raw1_exceeded
	B     raw1_scalar_nl_next

// ============================================================================
// SIMD VERIFICATION (for 16/32/128-byte loop paths)
// Dual-normalizes BOTH haystack AND needle (for raw needle input)
// Uses V2=191, V3=26, V4=32 for letter detection
// ============================================================================
raw1_verify:
	MOVD  R3, R19                 // R19 = remaining needle length
	MOVD  R8, R21                 // R21 = haystack candidate ptr
	MOVD  R2, R22                 // R22 = needle ptr

raw1_vloop:
	SUBS  $16, R19, R23
	BLT   raw1_vtail

	VLD1.P 16(R21), [V10.B16]     // Load haystack
	VLD1.P 16(R22), [V11.B16]     // Load needle (raw)
	MOVD   R23, R19

	// Dual normalize: both haystack and needle
	VADD  V2.B16, V10.B16, V16.B16  // V16 = h + 191 (=-65 unsigned)
	VADD  V2.B16, V11.B16, V17.B16  // V17 = n + 191
	WORD  $0x6e303470               // VCMHI V16.B16, V3.B16, V16.B16 (is h letter?)
	WORD  $0x6e313471               // VCMHI V17.B16, V3.B16, V17.B16 (is n letter?)
	VAND  V4.B16, V16.B16, V16.B16  // V16 = h_is_letter ? 0x20 : 0
	VAND  V4.B16, V17.B16, V17.B16  // V17 = n_is_letter ? 0x20 : 0
	VORR  V10.B16, V16.B16, V10.B16 // V10 = h | mask (normalized)
	VORR  V11.B16, V17.B16, V11.B16 // V11 = n | mask (normalized)
	VEOR  V10.B16, V11.B16, V10.B16 // V10 = diff (0 if equal)
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, raw1_vloop
	B     raw1_verify_fail

raw1_vtail:
	CMP   $1, R19
	BLT   raw1_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	// Dual normalize
	VADD  V2.B16, V10.B16, V16.B16
	VADD  V2.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V3.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V3.B16, V17.B16
	VAND  V4.B16, V16.B16, V16.B16
	VAND  V4.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16 // Mask out bytes beyond needle
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, raw1_verify_fail
	B     raw1_found

raw1_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   raw1_exceeded

	// Clear bit and continue - use R14 to determine which loop
	CMP   $0x100, R14
	BEQ   raw1_clear16_from_verify
	CMP   $64, R14
	BLT   raw1_clear128_from_verify
	B     raw1_clear32_from_verify

raw1_clear16_from_verify:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBZ   R26, raw1_clear16_nl_from_verify
	CBNZ  R13, raw1_try16
	B     raw1_check16_continue

raw1_clear16_nl_from_verify:
	CBNZ  R13, raw1_try16_nl
	B     raw1_check16_nl_continue

raw1_clear128_from_verify:
	ADD   $1, R15, R17
	SUB   R14, R17, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17, R17
	BIC   R17, R13, R13
	CBZ   R26, raw1_try128_nl_retry
	CBNZ  R13, raw1_try128
	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   raw1_next_chunk
	CBNZ  R20, raw1_check_second64_after
	B     raw1_continue128

raw1_try128_nl_retry:
	CBNZ  R13, raw1_try128_nl
	ADD   $16, R14, R14
	CMP   $64, R14
	BLT   raw1_next_chunk_nl
	CBNZ  R20, raw1_check_second64_nl_after
	B     raw1_continue128_nl

raw1_clear32_from_verify:
	AND   $0x7F, R14, R17
	ADD   $1, R15, R20
	SUB   R17, R20, R20
	LSL   $1, R20, R20
	MOVD  $1, R19
	LSL   R20, R19, R20
	SUB   $1, R20, R20
	BIC   R20, R13, R13
	CBZ   R26, raw1_try32_nl_retry
	CBNZ  R13, raw1_try32
	CMP   $128, R14
	BNE   raw1_continue32
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, raw1_try32
	B     raw1_continue32

raw1_try32_nl_retry:
	CBNZ  R13, raw1_try32_nl
	CMP   $128, R14
	BNE   raw1_continue32_nl
	VADDP V21.B16, V21.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.S[0], R13
	MOVD  $144, R14
	CBNZ  R13, raw1_try32_nl
	B     raw1_continue32_nl

// ============================================================================
// EXIT PATHS
// ============================================================================
raw1_exceeded:
	MOVD  $0x8000000000000000, R17   // exceeded flag (bit 63)
	ADD   R16, R17, R0              // add position
	MOVD  R0, ret+40(FP)
	RET

raw1_not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+40(FP)
	RET

raw1_found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+40(FP)
	RET

raw1_found:
	MOVD  R16, R0
	MOVD  R0, ret+40(FP)
	RET

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


// ============================================================================
// indexFold2ByteRaw - Case-insensitive 2-byte filter with raw needle
//
// func indexFold2ByteRaw(haystack string, needle string, off1 int, off2_delta int) uint64
//
// Same as indexFold2Byte but normalizes needle bytes on-the-fly and uses
// dual-normalize verification (normalizes both haystack AND needle).
//
// Returns:
//   - Position if found
//   - 0xFFFFFFFFFFFFFFFF (-1) if not found
//   - 0x8000000000000000 + position if exceeded threshold
// ============================================================================

TEXT ·indexFold2ByteRaw(SB), NOSPLIT, $0-56
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVD  needle+16(FP), R2
	MOVD  needle_len+24(FP), R3
	MOVD  off1+32(FP), R4
	MOVD  off2_delta+40(FP), R5

	// Early exits
	SUBS  R3, R1, R9              // R9 = searchLen = haystack_len - needle_len
	BLT   raw2_not_found
	CBZ   R3, raw2_found_zero

	// Load and normalize rare bytes from raw needle
	// needle[off1] and needle[off1+off2_delta]
	ADD   R2, R4, R17             // R17 = needle + off1
	MOVBU (R17), R6               // R6 = raw rare1 byte
	ADD   R17, R5, R17            // R17 = needle + off1 + off2_delta
	MOVBU (R17), R7               // R7 = raw rare2 byte

	// Normalize rare1 (uppercase → lowercase if letter)
	SUBW  $65, R6, R17            // R17 = rare1 - 'A'
	ORRW  $32, R6, R8             // R8 = rare1 | 0x20
	CMPW  $26, R17
	CSELW LO, R8, R6, R6          // R6 = normalized rare1

	// Normalize rare2 (uppercase → lowercase if letter)
	SUBW  $65, R7, R17            // R17 = rare2 - 'A'
	ORRW  $32, R7, R8             // R8 = rare2 | 0x20
	CMPW  $26, R17
	CSELW LO, R8, R7, R7          // R7 = normalized rare2

	// Compute masks for rare1 and rare2 (same as fold2)
	SUBW  $97, R6, R17            // R17 = rare1 - 'a'
	CMPW  $26, R17
	BCS   raw2_rare1_not_letter
	MOVW  $0x20, R8               // rare1 mask = 0x20
	B     raw2_check_rare2
raw2_rare1_not_letter:
	MOVW  $0x00, R8               // rare1 mask = 0x00

raw2_check_rare2:
	SUBW  $97, R7, R17            // R17 = rare2 - 'a'
	CMPW  $26, R17
	BCS   raw2_rare2_not_letter
	MOVW  $0x20, R26              // rare2 mask = 0x20
	B     raw2_setup
raw2_rare2_not_letter:
	MOVW  $0x00, R26              // rare2 mask = 0x00

raw2_setup:
	// Broadcast masks and targets
	VDUP  R8, V0.B16              // V0 = rare1 mask
	VDUP  R6, V1.B16              // V1 = rare1 target
	VDUP  R26, V2.B16             // V2 = rare2 mask (also used in verify)
	VDUP  R7, V3.B16              // V3 = rare2 target (also used in verify)

	// Syndrome magic constant
	MOVD  $0x4010040140100401, R17
	VMOV  R17, V5.D[0]
	VMOV  R17, V5.D[1]

	// Constants for dual-normalize verification
	// V6 = 191 (-65 as unsigned), V7 = 26, V8 = 32 (0x20)
	WORD  $0x4f05e7e6             // VMOVI $191, V6.B16
	WORD  $0x4f00e747             // VMOVI $26, V7.B16
	WORD  $0x4f01e408             // VMOVI $32, V8.B16
	MOVD  $tail_mask_table<>(SB), R24

	// Setup pointers
	ADD   R4, R0, R10             // R10 = searchPtr = haystack + off1
	MOVD  R10, R11                // R11 = searchStart
	ADD   $1, R9, R12             // R12 = remaining = searchLen + 1

	// Initialize failure counter
	MOVD  ZR, R25                 // R25 = failure count = 0

	CMP   $64, R12
	BLT   raw2_loop16_entry

// ============================================================================
// 64-BYTE LOOP
// ============================================================================
raw2_loop64:
	// Load 64 bytes at rare1 position
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]

	// Load 64 bytes at rare2 position
	SUB   $64, R10, R14
	ADD   R5, R14, R14
	VLD1  (R14), [V24.B16, V25.B16, V26.B16, V27.B16]

	SUB   $64, R12, R12

	// Case-fold and compare rare1
	VORR  V0.B16, V16.B16, V20.B16
	VORR  V0.B16, V17.B16, V21.B16
	VORR  V0.B16, V18.B16, V22.B16
	VORR  V0.B16, V19.B16, V23.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// Case-fold and compare rare2
	VORR  V2.B16, V24.B16, V28.B16
	VORR  V2.B16, V25.B16, V29.B16
	VORR  V2.B16, V26.B16, V30.B16
	VORR  V2.B16, V27.B16, V31.B16
	VCMEQ V3.B16, V28.B16, V28.B16
	VCMEQ V3.B16, V29.B16, V29.B16
	VCMEQ V3.B16, V30.B16, V30.B16
	VCMEQ V3.B16, V31.B16, V31.B16

	// AND both results
	VAND  V20.B16, V28.B16, V20.B16
	VAND  V21.B16, V29.B16, V21.B16
	VAND  V22.B16, V30.B16, V22.B16
	VAND  V23.B16, V31.B16, V23.B16

	// Quick check
	VORR  V20.B16, V21.B16, V9.B16
	VORR  V22.B16, V23.B16, V10.B16
	VORR  V9.B16, V10.B16, V9.B16
	VADDP V9.D2, V9.D2, V9.D2
	VMOV  V9.D[0], R13

	CMP   $64, R12
	BLT   raw2_end64
	CBZ   R13, raw2_loop64

raw2_end64:
	CBZ   R13, raw2_loop16_entry

	// Extract syndromes
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16

	MOVD  $0, R14

raw2_check_chunk64:
	CMP   $0, R14
	BEQ   raw2_chunk64_0
	CMP   $16, R14
	BEQ   raw2_chunk64_1
	CMP   $32, R14
	BEQ   raw2_chunk64_2
	B     raw2_chunk64_3

raw2_chunk64_0:
	VADDP V20.B16, V20.B16, V9.B16
	B     raw2_extract64
raw2_chunk64_1:
	VADDP V21.B16, V21.B16, V9.B16
	B     raw2_extract64
raw2_chunk64_2:
	VADDP V22.B16, V22.B16, V9.B16
	B     raw2_extract64
raw2_chunk64_3:
	VADDP V23.B16, V23.B16, V9.B16

raw2_extract64:
	VADDP V9.B16, V9.B16, V9.B16
	VMOV  V9.S[0], R13
	CBZ   R13, raw2_next_chunk64

raw2_try64:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $64, R10, R16
	ADD   R14, R16, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw2_clear64

	ADD   R0, R16, R17
	B     raw2_verify

raw2_clear64:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw2_try64

raw2_next_chunk64:
	ADD   $16, R14
	CMP   $64, R14
	BLT   raw2_check_chunk64
	CMP   $64, R12
	BGE   raw2_loop64

// ============================================================================
// 16-BYTE LOOP
// ============================================================================
raw2_loop16_entry:
	CMP   $16, R12
	BLT   raw2_scalar_entry

raw2_loop16:
	VLD1  (R10), [V16.B16]
	ADD   R5, R10, R14
	VLD1  (R14), [V17.B16]
	ADD   $16, R10
	SUB   $16, R12, R12

	VORR  V0.B16, V16.B16, V20.B16
	VORR  V2.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V3.B16, V21.B16, V21.B16
	VAND  V20.B16, V21.B16, V20.B16

	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.S[0], R13

	CMP   $16, R12
	BLT   raw2_end16
	CBZ   R13, raw2_loop16

raw2_end16:
	CBZ   R13, raw2_scalar_entry

raw2_try16:
	RBIT  R13, R15
	CLZ   R15, R15
	LSR   $1, R15, R15

	SUB   $16, R10, R16
	ADD   R15, R16, R16
	SUB   R11, R16, R16

	CMP   R9, R16
	BGT   raw2_clear16

	ADD   R0, R16, R17
	MOVD  $0x100, R14
	B     raw2_verify

raw2_clear16:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw2_try16
	CMP   $16, R12
	BGE   raw2_loop16

// ============================================================================
// SCALAR LOOP
// ============================================================================
raw2_scalar_entry:
	CMP   $0, R12
	BLE   raw2_not_found

raw2_scalar:
	MOVBU (R10), R13
	ADD   R5, R10, R14
	MOVBU (R14), R14

	ORRW  R8, R13, R15
	CMPW  R6, R15
	BNE   raw2_scalar_next

	ORRW  R26, R14, R15
	CMPW  R7, R15
	BNE   raw2_scalar_next

	SUB   R11, R10, R16
	CMP   R9, R16
	BGT   raw2_scalar_next

	ADD   R0, R16, R17
	B     raw2_verify_scalar

raw2_scalar_next:
	ADD   $1, R10
	SUB   $1, R12
	CBNZ  R12, raw2_scalar
	B     raw2_not_found

// ============================================================================
// SCALAR VERIFICATION (dual-normalize)
// ============================================================================
raw2_verify_scalar:
	MOVD  R3, R19
	MOVD  R17, R21
	MOVD  R2, R22

raw2_scalar_vloop:
	SUBS  $16, R19, R23
	BLT   raw2_scalar_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	// Dual normalize
	VADD  V6.B16, V10.B16, V16.B16
	VADD  V6.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V7.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V7.B16, V17.B16
	VAND  V8.B16, V16.B16, V16.B16
	VAND  V8.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, raw2_scalar_vloop
	B     raw2_scalar_verify_fail

raw2_scalar_vtail:
	CMP   $1, R19
	BLT   raw2_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VADD  V6.B16, V10.B16, V16.B16
	VADD  V6.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V7.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V7.B16, V17.B16
	VAND  V8.B16, V16.B16, V16.B16
	VAND  V8.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, raw2_scalar_verify_fail
	B     raw2_found

raw2_scalar_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   raw2_exceeded
	B     raw2_scalar_next

// ============================================================================
// SIMD VERIFICATION (dual-normalize)
// ============================================================================
raw2_verify:
	MOVD  R3, R19
	MOVD  R17, R21
	MOVD  R2, R22

raw2_vloop:
	SUBS  $16, R19, R23
	BLT   raw2_vtail

	VLD1.P 16(R21), [V10.B16]
	VLD1.P 16(R22), [V11.B16]
	MOVD   R23, R19

	VADD  V6.B16, V10.B16, V16.B16
	VADD  V6.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V7.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V7.B16, V17.B16
	VAND  V8.B16, V16.B16, V16.B16
	VAND  V8.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBZW  R23, raw2_vloop
	B     raw2_verify_fail

raw2_vtail:
	CMP   $1, R19
	BLT   raw2_found

	VLD1  (R21), [V10.B16]
	VLD1  (R22), [V11.B16]
	WORD  $0x3cf37b0d               // LDR Q13, [R24, R19, LSL #4]

	VADD  V6.B16, V10.B16, V16.B16
	VADD  V6.B16, V11.B16, V17.B16
	WORD  $0x6e303470               // VCMHI V16.B16, V7.B16, V16.B16
	WORD  $0x6e313471               // VCMHI V17.B16, V7.B16, V17.B16
	VAND  V8.B16, V16.B16, V16.B16
	VAND  V8.B16, V17.B16, V17.B16
	VORR  V10.B16, V16.B16, V10.B16
	VORR  V11.B16, V17.B16, V11.B16
	VEOR  V10.B16, V11.B16, V10.B16
	VAND  V13.B16, V10.B16, V10.B16
	WORD  $0x6e30a94a               // VUMAXV V10.B16, V10
	FMOVS F10, R23
	CBNZW R23, raw2_verify_fail
	B     raw2_found

raw2_verify_fail:
	ADD   $1, R25, R25
	SUB   R11, R10, R17
	LSR   $3, R17, R17
	ADD   $32, R17, R17
	CMP   R17, R25
	BGT   raw2_exceeded

	CMP   $0x100, R14
	BEQ   raw2_clear16_from_verify
	B     raw2_clear64_from_verify

raw2_clear16_from_verify:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw2_try16
	CMP   $16, R12
	BGE   raw2_loop16
	B     raw2_scalar_entry

raw2_clear64_from_verify:
	ADD   $1, R15, R17
	LSL   $1, R17, R17
	MOVD  $1, R19
	LSL   R17, R19, R17
	SUB   $1, R17
	BIC   R17, R13, R13
	CBNZ  R13, raw2_try64
	ADD   $16, R14
	CMP   $64, R14
	BLT   raw2_check_chunk64
	CMP   $64, R12
	BGE   raw2_loop64
	B     raw2_loop16_entry

// ============================================================================
// EXIT PATHS
// ============================================================================
raw2_exceeded:
	MOVD  $0x8000000000000000, R17
	ADD   R16, R17, R0
	MOVD  R0, ret+48(FP)
	RET

raw2_not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+48(FP)
	RET

raw2_found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+48(FP)
	RET

raw2_found:
	MOVD  R16, R0
	MOVD  R0, ret+48(FP)
	RET
