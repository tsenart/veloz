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

TEXT ·indexFold2Byte(SB), 0, $96-56
	MOVD haystack+0(FP), R0
	MOVD haystack_len+8(FP), R1
	MOVD needle+16(FP), R2
	MOVD needle_len+24(FP), R3
	MOVD off1+32(FP), R4
	MOVD off2_delta+40(FP), R5
	SUBS R3, R1, R9             // <--                                  // subs	x9, x1, x3
	BGE  LBB2_2                 // <--                                  // b.ge	.LBB2_2
	MOVD $-1, R0                // <--                                  // mov	x0, #-1
	MOVD R0, ret+48(FP)         // <--
	RET                         // <--                                  // ret

LBB2_2:
	MOVD  R3, R15                     // <--                                  // mov	x15, x3
	CBZ   R3, LBB2_107                // <--                                  // cbz	x3, .LBB2_107
	NOP                               // (skipped)                            // sub	sp, sp, #96
	ADD   R4, R2, R8                  // <--                                  // add	x8, x2, x4
	NOP                               // (skipped)                            // stp	x22, x21, [sp, #64]
	ADD   $1, R9, R21                 // <--                                  // add	x21, x9, #1
	WORD  $0x3940010a                 // MOVBU (R8), R10                      // ldrb	w10, [x8]
	WORD  $0x3865690d                 // MOVBU (R8)(R5), R13                  // ldrb	w13, [x8, x5]
	ADD   R4, R0, R17                 // <--                                  // add	x17, x0, x4
	MOVD  ZR, R16                     // <--                                  // mov	x16, xzr
	STP   (R21, R30), 8(RSP)          // <--                                  // stp	x21, x30, [sp, #8]
	SUBW  $97, R10, R8                // <--                                  // sub	w8, w10, #97
	SUBW  $97, R13, R11               // <--                                  // sub	w11, w13, #97
	VDUP  R10, V1.B16                 // <--                                  // dup	v1.16b, w10
	CMPW  $26, R8                     // <--                                  // cmp	w8, #26
	MOVW  $32, R8                     // <--                                  // mov	w8, #32
	VDUP  R13, V3.B16                 // <--                                  // dup	v3.16b, w13
	CSELW LO, R8, ZR, R12             // <--                                  // csel	w12, w8, wzr, lo
	CMPW  $26, R11                    // <--                                  // cmp	w11, #26
	NOP                               // (skipped)                            // stp	x26, x25, [sp, #32]
	CSELW LO, R8, ZR, R8              // <--                                  // csel	w8, w8, wzr, lo
	VDUP  R12, V0.B16                 // <--                                  // dup	v0.16b, w12
	CMP   $63, R9                     // <--                                  // cmp	x9, #63
	VDUP  R8, V2.B16                  // <--                                  // dup	v2.16b, w8
	NOP                               // (skipped)                            // stp	x24, x23, [sp, #48]
	NOP                               // (skipped)                            // stp	x20, x19, [sp, #80]
	STPW  (R8, R13), (RSP)            // <--                                  // stp	w8, w13, [sp]
	MOVD  R17, 24(RSP)                // <--                                  // str	x17, [sp, #24]
	BLT   LBB2_108                    // <--                                  // b.lt	.LBB2_108
	WORD  $0x4f05e7e4                 // VMOVI $191, V4.B16                   // movi	v4.16b, #191
	WORD  $0x4f00e745                 // VMOVI $26, V5.B16                    // movi	v5.16b, #26
	ADD   $16, R0, R4                 // <--                                  // add	x4, x0, #16
	WORD  $0x4f01e406                 // VMOVI $32, V6.B16                    // movi	v6.16b, #32
	ADD   $32, R0, R6                 // <--                                  // add	x6, x0, #32
	ADD   $48, R0, R7                 // <--                                  // add	x7, x0, #48
	MOVD  $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                               // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	MOVD  $-16, R20                   // <--                                  // mov	x20, #-16

LBB2_5:
	ADD   R5, R17, R8               // <--                                  // add	x8, x17, x5
	WORD  $0xad404227               // FLDPQ (R17), (F7, F16)               // ldp	q7, q16, [x17]
	WORD  $0xad414a31               // FLDPQ 32(R17), (F17, F18)            // ldp	q17, q18, [x17, #32]
	WORD  $0xad405113               // FLDPQ (R8), (F19, F20)               // ldp	q19, q20, [x8]
	WORD  $0xad415915               // FLDPQ 32(R8), (F21, F22)             // ldp	q21, q22, [x8, #32]
	VORR  V0.B16, V7.B16, V7.B16    // <--                                  // orr	v7.16b, v7.16b, v0.16b
	VORR  V0.B16, V16.B16, V16.B16  // <--                                  // orr	v16.16b, v16.16b, v0.16b
	VORR  V0.B16, V17.B16, V17.B16  // <--                                  // orr	v17.16b, v17.16b, v0.16b
	VORR  V0.B16, V18.B16, V18.B16  // <--                                  // orr	v18.16b, v18.16b, v0.16b
	VORR  V2.B16, V19.B16, V19.B16  // <--                                  // orr	v19.16b, v19.16b, v2.16b
	VORR  V2.B16, V20.B16, V20.B16  // <--                                  // orr	v20.16b, v20.16b, v2.16b
	VORR  V2.B16, V21.B16, V21.B16  // <--                                  // orr	v21.16b, v21.16b, v2.16b
	VORR  V2.B16, V22.B16, V22.B16  // <--                                  // orr	v22.16b, v22.16b, v2.16b
	VCMEQ V1.B16, V7.B16, V7.B16    // <--                                  // cmeq	v7.16b, v7.16b, v1.16b
	VCMEQ V1.B16, V16.B16, V16.B16  // <--                                  // cmeq	v16.16b, v16.16b, v1.16b
	VCMEQ V1.B16, V17.B16, V23.B16  // <--                                  // cmeq	v23.16b, v17.16b, v1.16b
	VCMEQ V1.B16, V18.B16, V24.B16  // <--                                  // cmeq	v24.16b, v18.16b, v1.16b
	VCMEQ V3.B16, V19.B16, V17.B16  // <--                                  // cmeq	v17.16b, v19.16b, v3.16b
	VCMEQ V3.B16, V20.B16, V19.B16  // <--                                  // cmeq	v19.16b, v20.16b, v3.16b
	VCMEQ V3.B16, V21.B16, V20.B16  // <--                                  // cmeq	v20.16b, v21.16b, v3.16b
	VCMEQ V3.B16, V22.B16, V21.B16  // <--                                  // cmeq	v21.16b, v22.16b, v3.16b
	VAND  V17.B16, V7.B16, V18.B16  // <--                                  // and	v18.16b, v7.16b, v17.16b
	VAND  V19.B16, V16.B16, V17.B16 // <--                                  // and	v17.16b, v16.16b, v19.16b
	VAND  V20.B16, V23.B16, V16.B16 // <--                                  // and	v16.16b, v23.16b, v20.16b
	VAND  V21.B16, V24.B16, V7.B16  // <--                                  // and	v7.16b, v24.16b, v21.16b
	VORR  V18.B16, V17.B16, V19.B16 // <--                                  // orr	v19.16b, v17.16b, v18.16b
	VORR  V7.B16, V16.B16, V20.B16  // <--                                  // orr	v20.16b, v16.16b, v7.16b
	VORR  V20.B16, V19.B16, V19.B16 // <--                                  // orr	v19.16b, v19.16b, v20.16b
	WORD  $0x4ef3be73               // VADDP V19.D2, V19.D2, V19.D2         // addp	v19.2d, v19.2d, v19.2d
	FMOVD F19, R8                   // <--                                  // fmov	x8, d19
	CBZ   R8, LBB2_106              // <--                                  // cbz	x8, .LBB2_106
	MOVD  8(RSP), R8                // <--                                  // ldr	x8, [sp, #8]
	WORD  $0x0f0c8652               // VSHRN $4, V18.H8, V18.B8             // shrn	v18.8b, v18.8h, #4
	CMP   $16, R15                  // <--                                  // cmp	x15, #16
	SUB   R21, R8, R8               // <--                                  // sub	x8, x8, x21
	LSR   $3, R8, R8                // <--                                  // lsr	x8, x8, #3
	FMOVD F18, R24                  // <--                                  // fmov	x24, d18
	ADD   $32, R8, R22              // <--                                  // add	x22, x8, #32
	MOVD  24(RSP), R8               // <--                                  // ldr	x8, [sp, #24]
	SUB   R8, R17, R23              // <--                                  // sub	x23, x17, x8
	BLT   LBB2_33                   // <--                                  // b.lt	.LBB2_33
	CBNZ  R24, LBB2_11              // <--                                  // cbnz	x24, .LBB2_11

LBB2_8:
	WORD  $0x0f0c8631   // VSHRN $4, V17.H8, V17.B8             // shrn	v17.8b, v17.8h, #4
	FMOVD F17, R24      // <--                                  // fmov	x24, d17
	CBZ   R24, LBB2_47  // <--                                  // cbz	x24, .LBB2_47
	ADD   $16, R23, R25 // <--                                  // add	x25, x23, #16
	JMP   LBB2_23       // <--                                  // b	.LBB2_23

LBB2_10:
	AND  $60, R25, R8 // <--                                  // and	x8, x25, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_8       // <--                                  // b.eq	.LBB2_8

LBB2_11:
	RBIT R24, R8         // <--                                  // rbit	x8, x24
	CLZ  R8, R25         // <--                                  // clz	x25, x8
	ADD  R25>>2, R23, R8 // <--                                  // add	x8, x23, x25, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BHI  LBB2_10         // <--                                  // b.hi	.LBB2_10
	SUB  R8, R1, R13     // <--                                  // sub	x13, x1, x8
	ADD  R8, R0, R30     // <--                                  // add	x30, x0, x8
	MOVD R15, R14        // <--                                  // mov	x14, x15
	CMP  $16, R13        // <--                                  // cmp	x13, #16
	MOVD R2, R26         // <--                                  // mov	x26, x2
	MOVD R15, R3         // <--                                  // mov	x3, x15
	BLT  LBB2_16         // <--                                  // b.lt	.LBB2_16

LBB2_13:
	WORD  $0x3cc107d2               // FMOVQ.P 16(R30), F18                 // ldr	q18, [x30], #16
	VADD  V4.B16, V18.B16, V19.B16  // <--                                  // add	v19.16b, v18.16b, v4.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VORR  V18.B16, V19.B16, V18.B16 // <--                                  // orr	v18.16b, v19.16b, v18.16b
	WORD  $0x3cc10753               // FMOVQ.P 16(R26), F19                 // ldr	q19, [x26], #16
	VEOR  V19.B16, V18.B16, V18.B16 // <--                                  // eor	v18.16b, v18.16b, v19.16b
	WORD  $0x6e30aa52               // VUMAXV V18.B16, V18                  // umaxv	b18, v18.16b
	FMOVS F18, R11                  // <--                                  // fmov	w11, s18
	CBNZW R11, LBB2_18              // <--                                  // cbnz	w11, .LBB2_18
	CMP   $32, R3                   // <--                                  // cmp	x3, #32
	SUB   $16, R3, R14              // <--                                  // sub	x14, x3, #16
	BLT   LBB2_16                   // <--                                  // b.lt	.LBB2_16
	CMP   $31, R13                  // <--                                  // cmp	x13, #31
	SUB   $16, R13, R13             // <--                                  // sub	x13, x13, #16
	MOVD  R14, R3                   // <--                                  // mov	x3, x14
	BGT   LBB2_13                   // <--                                  // b.gt	.LBB2_13

LBB2_16:
	CMP   $1, R14                   // <--                                  // cmp	x14, #1
	BLT   LBB2_171                  // <--                                  // b.lt	.LBB2_171
	WORD  $0x3dc003d2               // FMOVQ (R30), F18                     // ldr	q18, [x30]
	VADD  V4.B16, V18.B16, V19.B16  // <--                                  // add	v19.16b, v18.16b, v4.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VORR  V18.B16, V19.B16, V18.B16 // <--                                  // orr	v18.16b, v19.16b, v18.16b
	WORD  $0x3dc00353               // FMOVQ (R26), F19                     // ldr	q19, [x26]
	VEOR  V19.B16, V18.B16, V18.B16 // <--                                  // eor	v18.16b, v18.16b, v19.16b
	WORD  $0x3cee7a73               // FMOVQ (R19)(R14<<4), F19             // ldr	q19, [x19, x14, lsl #4]
	VAND  V19.B16, V18.B16, V18.B16 // <--                                  // and	v18.16b, v18.16b, v19.16b
	WORD  $0x6e30aa52               // VUMAXV V18.B16, V18                  // umaxv	b18, v18.16b
	FMOVS F18, R11                  // <--                                  // fmov	w11, s18
	CBZW  R11, LBB2_171             // <--                                  // cbz	w11, .LBB2_171

LBB2_18:
	CMP R22, R16     // <--                                  // cmp	x16, x22
	BGE LBB2_169     // <--                                  // b.ge	.LBB2_169
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1
	JMP LBB2_10      // <--                                  // b	.LBB2_10

LBB2_20:
	CMP  R22, R16                    // <--                                  // cmp	x16, x22
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	BGE  LBB2_169                    // <--                                  // b.ge	.LBB2_169
	ADD  $1, R16, R16                // <--                                  // add	x16, x16, #1

LBB2_22:
	AND  $60, R26, R8 // <--                                  // and	x8, x26, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_47      // <--                                  // b.eq	.LBB2_47

LBB2_23:
	RBIT R24, R8      // <--                                  // rbit	x8, x24
	CLZ  R8, R26      // <--                                  // clz	x26, x8
	LSR  $2, R26, R30 // <--                                  // lsr	x30, x26, #2
	ADD  R30, R25, R8 // <--                                  // add	x8, x25, x30
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BHI  LBB2_22      // <--                                  // b.hi	.LBB2_22
	SUB  R8, R1, R14  // <--                                  // sub	x14, x1, x8
	CMP  $16, R14     // <--                                  // cmp	x14, #16
	BLT  LBB2_30      // <--                                  // b.lt	.LBB2_30
	MOVD ZR, R13      // <--                                  // mov	x13, xzr
	ADD  R30, R4, R19 // <--                                  // add	x19, x4, x30
	MOVD R15, R3      // <--                                  // mov	x3, x15

LBB2_26:
	WORD  $0x3ced6a71               // FMOVQ (R19)(R13), F17                // ldr	q17, [x19, x13]
	VADD  V4.B16, V17.B16, V18.B16  // <--                                  // add	v18.16b, v17.16b, v4.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V17.B16, V18.B16, V17.B16 // <--                                  // orr	v17.16b, v18.16b, v17.16b
	WORD  $0x3ced6852               // FMOVQ (R2)(R13), F18                 // ldr	q18, [x2, x13]
	VEOR  V18.B16, V17.B16, V17.B16 // <--                                  // eor	v17.16b, v17.16b, v18.16b
	WORD  $0x6e30aa31               // VUMAXV V17.B16, V17                  // umaxv	b17, v17.16b
	FMOVS F17, R11                  // <--                                  // fmov	w11, s17
	CBNZW R11, LBB2_20              // <--                                  // cbnz	w11, .LBB2_20
	CMP   $32, R3                   // <--                                  // cmp	x3, #32
	SUB   $16, R3, R11              // <--                                  // sub	x11, x3, #16
	ADD   $16, R13, R13             // <--                                  // add	x13, x13, #16
	BLT   LBB2_29                   // <--                                  // b.lt	.LBB2_29
	CMP   $31, R14                  // <--                                  // cmp	x14, #31
	SUB   $16, R14, R14             // <--                                  // sub	x14, x14, #16
	MOVD  R11, R3                   // <--                                  // mov	x3, x11
	BGT   LBB2_26                   // <--                                  // b.gt	.LBB2_26

LBB2_29:
	ADD  R30, R4, R14                // <--                                  // add	x14, x4, x30
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	ADD  R13, R14, R14               // <--                                  // add	x14, x14, x13
	ADD  R13, R2, R13                // <--                                  // add	x13, x2, x13
	JMP  LBB2_31                     // <--                                  // b	.LBB2_31

LBB2_30:
	ADD  R8, R0, R14 // <--                                  // add	x14, x0, x8
	MOVD R15, R11    // <--                                  // mov	x11, x15
	MOVD R2, R13     // <--                                  // mov	x13, x2

LBB2_31:
	CMP   $1, R11                   // <--                                  // cmp	x11, #1
	BLT   LBB2_171                  // <--                                  // b.lt	.LBB2_171
	WORD  $0x3dc001d1               // FMOVQ (R14), F17                     // ldr	q17, [x14]
	VADD  V4.B16, V17.B16, V18.B16  // <--                                  // add	v18.16b, v17.16b, v4.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V17.B16, V18.B16, V17.B16 // <--                                  // orr	v17.16b, v18.16b, v17.16b
	WORD  $0x3dc001b2               // FMOVQ (R13), F18                     // ldr	q18, [x13]
	VEOR  V18.B16, V17.B16, V17.B16 // <--                                  // eor	v17.16b, v17.16b, v18.16b
	WORD  $0x3ceb7a72               // FMOVQ (R19)(R11<<4), F18             // ldr	q18, [x19, x11, lsl #4]
	VAND  V18.B16, V17.B16, V17.B16 // <--                                  // and	v17.16b, v17.16b, v18.16b
	WORD  $0x6e30aa31               // VUMAXV V17.B16, V17                  // umaxv	b17, v17.16b
	FMOVS F17, R11                  // <--                                  // fmov	w11, s17
	CBNZW R11, LBB2_20              // <--                                  // cbnz	w11, .LBB2_20
	JMP   LBB2_171                  // <--                                  // b	.LBB2_171

LBB2_33:
	CMP  $0, R15      // <--                                  // cmp	x15, #0
	BLE  LBB2_62      // <--                                  // b.le	.LBB2_62
	CBNZ R24, LBB2_44 // <--                                  // cbnz	x24, .LBB2_44

LBB2_35:
	WORD  $0x0f0c8631   // VSHRN $4, V17.H8, V17.B8             // shrn	v17.8b, v17.8h, #4
	FMOVD F17, R24      // <--                                  // fmov	x24, d17
	CBZ   R24, LBB2_77  // <--                                  // cbz	x24, .LBB2_77
	ADD   $16, R23, R13 // <--                                  // add	x13, x23, #16
	JMP   LBB2_38       // <--                                  // b	.LBB2_38

LBB2_37:
	AND  $60, R14, R8 // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_77      // <--                                  // b.eq	.LBB2_77

LBB2_38:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R14                   // <--                                  // clz	x14, x8
	ADD   R14>>2, R13, R8           // <--                                  // add	x8, x13, x14, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB2_37                   // <--                                  // b.hi	.LBB2_37
	WORD  $0x3ce86811               // FMOVQ (R0)(R8), F17                  // ldr	q17, [x0, x8]
	VADD  V4.B16, V17.B16, V18.B16  // <--                                  // add	v18.16b, v17.16b, v4.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V17.B16, V18.B16, V17.B16 // <--                                  // orr	v17.16b, v18.16b, v17.16b
	WORD  $0x3dc00052               // FMOVQ (R2), F18                      // ldr	q18, [x2]
	VEOR  V18.B16, V17.B16, V17.B16 // <--                                  // eor	v17.16b, v17.16b, v18.16b
	WORD  $0x3cef7a72               // FMOVQ (R19)(R15<<4), F18             // ldr	q18, [x19, x15, lsl #4]
	VAND  V18.B16, V17.B16, V17.B16 // <--                                  // and	v17.16b, v17.16b, v18.16b
	WORD  $0x6e30aa31               // VUMAXV V17.B16, V17                  // umaxv	b17, v17.16b
	FMOVS F17, R11                  // <--                                  // fmov	w11, s17
	CBZW  R11, LBB2_171             // <--                                  // cbz	w11, .LBB2_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BGE   LBB2_169                  // <--                                  // b.ge	.LBB2_169
	ADD   $1, R16, R16              // <--                                  // add	x16, x16, #1
	JMP   LBB2_37                   // <--                                  // b	.LBB2_37

LBB2_42:
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1

LBB2_43:
	AND  $60, R13, R8 // <--                                  // and	x8, x13, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_35      // <--                                  // b.eq	.LBB2_35

LBB2_44:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R13                   // <--                                  // clz	x13, x8
	ADD   R13>>2, R23, R8           // <--                                  // add	x8, x23, x13, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB2_43                   // <--                                  // b.hi	.LBB2_43
	WORD  $0x3ce86812               // FMOVQ (R0)(R8), F18                  // ldr	q18, [x0, x8]
	VADD  V4.B16, V18.B16, V19.B16  // <--                                  // add	v19.16b, v18.16b, v4.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VORR  V18.B16, V19.B16, V18.B16 // <--                                  // orr	v18.16b, v19.16b, v18.16b
	WORD  $0x3dc00053               // FMOVQ (R2), F19                      // ldr	q19, [x2]
	VEOR  V19.B16, V18.B16, V18.B16 // <--                                  // eor	v18.16b, v18.16b, v19.16b
	WORD  $0x3cef7a73               // FMOVQ (R19)(R15<<4), F19             // ldr	q19, [x19, x15, lsl #4]
	VAND  V19.B16, V18.B16, V18.B16 // <--                                  // and	v18.16b, v18.16b, v19.16b
	WORD  $0x6e30aa52               // VUMAXV V18.B16, V18                  // umaxv	b18, v18.16b
	FMOVS F18, R11                  // <--                                  // fmov	w11, s18
	CBZW  R11, LBB2_171             // <--                                  // cbz	w11, .LBB2_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BLT   LBB2_42                   // <--                                  // b.lt	.LBB2_42
	JMP   LBB2_169                  // <--                                  // b	.LBB2_169

LBB2_47:
	WORD  $0x0f0c8610   // VSHRN $4, V16.H8, V16.B8             // shrn	v16.8b, v16.8h, #4
	FMOVD F16, R24      // <--                                  // fmov	x24, d16
	CBZ   R24, LBB2_84  // <--                                  // cbz	x24, .LBB2_84
	ADD   $32, R23, R25 // <--                                  // add	x25, x23, #32
	JMP   LBB2_50       // <--                                  // b	.LBB2_50

LBB2_49:
	AND  $60, R26, R8 // <--                                  // and	x8, x26, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_84      // <--                                  // b.eq	.LBB2_84

LBB2_50:
	RBIT R24, R8      // <--                                  // rbit	x8, x24
	CLZ  R8, R26      // <--                                  // clz	x26, x8
	LSR  $2, R26, R30 // <--                                  // lsr	x30, x26, #2
	ADD  R30, R25, R8 // <--                                  // add	x8, x25, x30
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BHI  LBB2_49      // <--                                  // b.hi	.LBB2_49
	SUB  R8, R1, R14  // <--                                  // sub	x14, x1, x8
	CMP  $16, R14     // <--                                  // cmp	x14, #16
	BLT  LBB2_57      // <--                                  // b.lt	.LBB2_57
	MOVD ZR, R13      // <--                                  // mov	x13, xzr
	ADD  R30, R6, R19 // <--                                  // add	x19, x6, x30
	MOVD R15, R11     // <--                                  // mov	x11, x15

LBB2_53:
	WORD  $0x3ced6a70               // FMOVQ (R19)(R13), F16                // ldr	q16, [x19, x13]
	VADD  V4.B16, V16.B16, V17.B16  // <--                                  // add	v17.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VORR  V16.B16, V17.B16, V16.B16 // <--                                  // orr	v16.16b, v17.16b, v16.16b
	WORD  $0x3ced6851               // FMOVQ (R2)(R13), F17                 // ldr	q17, [x2, x13]
	VEOR  V17.B16, V16.B16, V16.B16 // <--                                  // eor	v16.16b, v16.16b, v17.16b
	WORD  $0x6e30aa10               // VUMAXV V16.B16, V16                  // umaxv	b16, v16.16b
	FMOVS F16, R3                   // <--                                  // fmov	w3, s16
	CBNZW R3, LBB2_60               // <--                                  // cbnz	w3, .LBB2_60
	CMP   $32, R11                  // <--                                  // cmp	x11, #32
	SUB   $16, R11, R3              // <--                                  // sub	x3, x11, #16
	ADD   $16, R13, R13             // <--                                  // add	x13, x13, #16
	BLT   LBB2_56                   // <--                                  // b.lt	.LBB2_56
	CMP   $31, R14                  // <--                                  // cmp	x14, #31
	SUB   $16, R14, R14             // <--                                  // sub	x14, x14, #16
	MOVD  R3, R11                   // <--                                  // mov	x11, x3
	BGT   LBB2_53                   // <--                                  // b.gt	.LBB2_53

LBB2_56:
	ADD  R30, R6, R11                // <--                                  // add	x11, x6, x30
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	ADD  R13, R11, R14               // <--                                  // add	x14, x11, x13
	ADD  R13, R2, R11                // <--                                  // add	x11, x2, x13
	JMP  LBB2_58                     // <--                                  // b	.LBB2_58

LBB2_57:
	ADD  R8, R0, R14 // <--                                  // add	x14, x0, x8
	MOVD R15, R3     // <--                                  // mov	x3, x15
	MOVD R2, R11     // <--                                  // mov	x11, x2

LBB2_58:
	CMP   $1, R3                    // <--                                  // cmp	x3, #1
	BLT   LBB2_171                  // <--                                  // b.lt	.LBB2_171
	WORD  $0x3dc001d0               // FMOVQ (R14), F16                     // ldr	q16, [x14]
	VADD  V4.B16, V16.B16, V17.B16  // <--                                  // add	v17.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VORR  V16.B16, V17.B16, V16.B16 // <--                                  // orr	v16.16b, v17.16b, v16.16b
	WORD  $0x3dc00171               // FMOVQ (R11), F17                     // ldr	q17, [x11]
	VEOR  V17.B16, V16.B16, V16.B16 // <--                                  // eor	v16.16b, v16.16b, v17.16b
	WORD  $0x3ce37a71               // FMOVQ (R19)(R3<<4), F17              // ldr	q17, [x19, x3, lsl #4]
	VAND  V17.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v17.16b
	WORD  $0x6e30aa10               // VUMAXV V16.B16, V16                  // umaxv	b16, v16.16b
	FMOVS F16, R11                  // <--                                  // fmov	w11, s16
	CBZW  R11, LBB2_171             // <--                                  // cbz	w11, .LBB2_171

LBB2_60:
	CMP  R22, R16                    // <--                                  // cmp	x16, x22
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	BGE  LBB2_169                    // <--                                  // b.ge	.LBB2_169
	ADD  $1, R16, R16                // <--                                  // add	x16, x16, #1
	JMP  LBB2_49                     // <--                                  // b	.LBB2_49

LBB2_62:
	CBZ R24, LBB2_65 // <--                                  // cbz	x24, .LBB2_65

LBB2_63:
	RBIT R24, R8         // <--                                  // rbit	x8, x24
	CLZ  R8, R11         // <--                                  // clz	x11, x8
	ADD  R11>>2, R23, R8 // <--                                  // add	x8, x23, x11, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB2_171        // <--                                  // b.ls	.LBB2_171
	AND  $60, R11, R8    // <--                                  // and	x8, x11, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24    // <--                                  // ands	x24, x8, x24
	BNE  LBB2_63         // <--                                  // b.ne	.LBB2_63

LBB2_65:
	WORD  $0x0f0c8631   // VSHRN $4, V17.H8, V17.B8             // shrn	v17.8b, v17.8h, #4
	FMOVD F17, R11      // <--                                  // fmov	x11, d17
	CBZ   R11, LBB2_69  // <--                                  // cbz	x11, .LBB2_69
	ADD   $16, R23, R13 // <--                                  // add	x13, x23, #16

LBB2_67:
	RBIT R11, R8         // <--                                  // rbit	x8, x11
	CLZ  R8, R14         // <--                                  // clz	x14, x8
	ADD  R14>>2, R13, R8 // <--                                  // add	x8, x13, x14, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB2_171        // <--                                  // b.ls	.LBB2_171
	AND  $60, R14, R8    // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R11, R8, R11    // <--                                  // ands	x11, x8, x11
	BNE  LBB2_67         // <--                                  // b.ne	.LBB2_67

LBB2_69:
	WORD  $0x0f0c8610   // VSHRN $4, V16.H8, V16.B8             // shrn	v16.8b, v16.8h, #4
	FMOVD F16, R11      // <--                                  // fmov	x11, d16
	CBZ   R11, LBB2_73  // <--                                  // cbz	x11, .LBB2_73
	ADD   $32, R23, R13 // <--                                  // add	x13, x23, #32

LBB2_71:
	RBIT R11, R8         // <--                                  // rbit	x8, x11
	CLZ  R8, R14         // <--                                  // clz	x14, x8
	ADD  R14>>2, R13, R8 // <--                                  // add	x8, x13, x14, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB2_171        // <--                                  // b.ls	.LBB2_171
	AND  $60, R14, R8    // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R11, R8, R11    // <--                                  // ands	x11, x8, x11
	BNE  LBB2_71         // <--                                  // b.ne	.LBB2_71

LBB2_73:
	WORD  $0x0f0c84e7   // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R11       // <--                                  // fmov	x11, d7
	CBZ   R11, LBB2_106 // <--                                  // cbz	x11, .LBB2_106
	ADD   $48, R23, R13 // <--                                  // add	x13, x23, #48

LBB2_75:
	RBIT R11, R8         // <--                                  // rbit	x8, x11
	CLZ  R8, R14         // <--                                  // clz	x14, x8
	ADD  R14>>2, R13, R8 // <--                                  // add	x8, x13, x14, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB2_171        // <--                                  // b.ls	.LBB2_171
	AND  $60, R14, R8    // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R11, R8, R11    // <--                                  // ands	x11, x8, x11
	BNE  LBB2_75         // <--                                  // b.ne	.LBB2_75
	JMP  LBB2_106        // <--                                  // b	.LBB2_106

LBB2_77:
	WORD  $0x0f0c8610   // VSHRN $4, V16.H8, V16.B8             // shrn	v16.8b, v16.8h, #4
	FMOVD F16, R24      // <--                                  // fmov	x24, d16
	CBZ   R24, LBB2_99  // <--                                  // cbz	x24, .LBB2_99
	ADD   $32, R23, R13 // <--                                  // add	x13, x23, #32
	JMP   LBB2_81       // <--                                  // b	.LBB2_81

LBB2_79:
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1

LBB2_80:
	AND  $60, R14, R8 // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_99      // <--                                  // b.eq	.LBB2_99

LBB2_81:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R14                   // <--                                  // clz	x14, x8
	ADD   R14>>2, R13, R8           // <--                                  // add	x8, x13, x14, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB2_80                   // <--                                  // b.hi	.LBB2_80
	WORD  $0x3ce86810               // FMOVQ (R0)(R8), F16                  // ldr	q16, [x0, x8]
	VADD  V4.B16, V16.B16, V17.B16  // <--                                  // add	v17.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VORR  V16.B16, V17.B16, V16.B16 // <--                                  // orr	v16.16b, v17.16b, v16.16b
	WORD  $0x3dc00051               // FMOVQ (R2), F17                      // ldr	q17, [x2]
	VEOR  V17.B16, V16.B16, V16.B16 // <--                                  // eor	v16.16b, v16.16b, v17.16b
	WORD  $0x3cef7a71               // FMOVQ (R19)(R15<<4), F17             // ldr	q17, [x19, x15, lsl #4]
	VAND  V17.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v17.16b
	WORD  $0x6e30aa10               // VUMAXV V16.B16, V16                  // umaxv	b16, v16.16b
	FMOVS F16, R11                  // <--                                  // fmov	w11, s16
	CBZW  R11, LBB2_171             // <--                                  // cbz	w11, .LBB2_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BLT   LBB2_79                   // <--                                  // b.lt	.LBB2_79
	JMP   LBB2_169                  // <--                                  // b	.LBB2_169

LBB2_84:
	WORD  $0x0f0c84e7   // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R24       // <--                                  // fmov	x24, d7
	CBZ   R24, LBB2_106 // <--                                  // cbz	x24, .LBB2_106
	ADD   $48, R23, R23 // <--                                  // add	x23, x23, #48
	JMP   LBB2_87       // <--                                  // b	.LBB2_87

LBB2_86:
	AND  $60, R25, R8 // <--                                  // and	x8, x25, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_106     // <--                                  // b.eq	.LBB2_106

LBB2_87:
	RBIT R24, R8      // <--                                  // rbit	x8, x24
	CLZ  R8, R25      // <--                                  // clz	x25, x8
	LSR  $2, R25, R26 // <--                                  // lsr	x26, x25, #2
	ADD  R26, R23, R8 // <--                                  // add	x8, x23, x26
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BHI  LBB2_86      // <--                                  // b.hi	.LBB2_86
	SUB  R8, R1, R14  // <--                                  // sub	x14, x1, x8
	CMP  $16, R14     // <--                                  // cmp	x14, #16
	BLT  LBB2_94      // <--                                  // b.lt	.LBB2_94
	MOVD ZR, R13      // <--                                  // mov	x13, xzr
	ADD  R26, R7, R19 // <--                                  // add	x19, x7, x26
	MOVD R15, R11     // <--                                  // mov	x11, x15

LBB2_90:
	WORD  $0x3ced6a67              // FMOVQ (R19)(R13), F7                 // ldr	q7, [x19, x13]
	VADD  V4.B16, V7.B16, V16.B16  // <--                                  // add	v16.16b, v7.16b, v4.16b
	WORD  $0x6e3034b0              // VCMHI V16.B16, V5.B16, V16.B16       // cmhi	v16.16b, v5.16b, v16.16b
	VAND  V6.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v6.16b
	VORR  V7.B16, V16.B16, V7.B16  // <--                                  // orr	v7.16b, v16.16b, v7.16b
	WORD  $0x3ced6850              // FMOVQ (R2)(R13), F16                 // ldr	q16, [x2, x13]
	VEOR  V16.B16, V7.B16, V7.B16  // <--                                  // eor	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7              // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R3                   // <--                                  // fmov	w3, s7
	CBNZW R3, LBB2_97              // <--                                  // cbnz	w3, .LBB2_97
	CMP   $32, R11                 // <--                                  // cmp	x11, #32
	SUB   $16, R11, R3             // <--                                  // sub	x3, x11, #16
	ADD   $16, R13, R13            // <--                                  // add	x13, x13, #16
	BLT   LBB2_93                  // <--                                  // b.lt	.LBB2_93
	CMP   $31, R14                 // <--                                  // cmp	x14, #31
	SUB   $16, R14, R14            // <--                                  // sub	x14, x14, #16
	MOVD  R3, R11                  // <--                                  // mov	x11, x3
	BGT   LBB2_90                  // <--                                  // b.gt	.LBB2_90

LBB2_93:
	ADD  R26, R7, R11                // <--                                  // add	x11, x7, x26
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	ADD  R13, R11, R14               // <--                                  // add	x14, x11, x13
	ADD  R13, R2, R11                // <--                                  // add	x11, x2, x13
	JMP  LBB2_95                     // <--                                  // b	.LBB2_95

LBB2_94:
	ADD  R8, R0, R14 // <--                                  // add	x14, x0, x8
	MOVD R15, R3     // <--                                  // mov	x3, x15
	MOVD R2, R11     // <--                                  // mov	x11, x2

LBB2_95:
	CMP   $1, R3                   // <--                                  // cmp	x3, #1
	BLT   LBB2_171                 // <--                                  // b.lt	.LBB2_171
	WORD  $0x3dc001c7              // FMOVQ (R14), F7                      // ldr	q7, [x14]
	VADD  V4.B16, V7.B16, V16.B16  // <--                                  // add	v16.16b, v7.16b, v4.16b
	WORD  $0x6e3034b0              // VCMHI V16.B16, V5.B16, V16.B16       // cmhi	v16.16b, v5.16b, v16.16b
	VAND  V6.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v6.16b
	VORR  V7.B16, V16.B16, V7.B16  // <--                                  // orr	v7.16b, v16.16b, v7.16b
	WORD  $0x3dc00170              // FMOVQ (R11), F16                     // ldr	q16, [x11]
	VEOR  V16.B16, V7.B16, V7.B16  // <--                                  // eor	v7.16b, v7.16b, v16.16b
	WORD  $0x3ce37a70              // FMOVQ (R19)(R3<<4), F16              // ldr	q16, [x19, x3, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7              // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                  // <--                                  // fmov	w11, s7
	CBZW  R11, LBB2_171            // <--                                  // cbz	w11, .LBB2_171

LBB2_97:
	CMP  R22, R16                    // <--                                  // cmp	x16, x22
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	BGE  LBB2_169                    // <--                                  // b.ge	.LBB2_169
	ADD  $1, R16, R16                // <--                                  // add	x16, x16, #1
	JMP  LBB2_86                     // <--                                  // b	.LBB2_86

LBB2_99:
	WORD  $0x0f0c84e7   // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R24       // <--                                  // fmov	x24, d7
	CBZ   R24, LBB2_106 // <--                                  // cbz	x24, .LBB2_106
	ADD   $48, R23, R13 // <--                                  // add	x13, x23, #48
	JMP   LBB2_103      // <--                                  // b	.LBB2_103

LBB2_101:
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1

LBB2_102:
	AND  $60, R14, R8 // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB2_106     // <--                                  // b.eq	.LBB2_106

LBB2_103:
	RBIT  R24, R8                  // <--                                  // rbit	x8, x24
	CLZ   R8, R14                  // <--                                  // clz	x14, x8
	ADD   R14>>2, R13, R8          // <--                                  // add	x8, x13, x14, lsr #2
	CMP   R9, R8                   // <--                                  // cmp	x8, x9
	BHI   LBB2_102                 // <--                                  // b.hi	.LBB2_102
	WORD  $0x3ce86807              // FMOVQ (R0)(R8), F7                   // ldr	q7, [x0, x8]
	VADD  V4.B16, V7.B16, V16.B16  // <--                                  // add	v16.16b, v7.16b, v4.16b
	WORD  $0x6e3034b0              // VCMHI V16.B16, V5.B16, V16.B16       // cmhi	v16.16b, v5.16b, v16.16b
	VAND  V6.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v6.16b
	VORR  V7.B16, V16.B16, V7.B16  // <--                                  // orr	v7.16b, v16.16b, v7.16b
	WORD  $0x3dc00050              // FMOVQ (R2), F16                      // ldr	q16, [x2]
	VEOR  V16.B16, V7.B16, V7.B16  // <--                                  // eor	v7.16b, v7.16b, v16.16b
	WORD  $0x3cef7a70              // FMOVQ (R19)(R15<<4), F16             // ldr	q16, [x19, x15, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7              // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                  // <--                                  // fmov	w11, s7
	CBZW  R11, LBB2_171            // <--                                  // cbz	w11, .LBB2_171
	CMP   R22, R16                 // <--                                  // cmp	x16, x22
	BLT   LBB2_101                 // <--                                  // b.lt	.LBB2_101
	JMP   LBB2_169                 // <--                                  // b	.LBB2_169

LBB2_106:
	SUB  $64, R21, R22 // <--                                  // sub	x22, x21, #64
	ADD  $64, R17, R17 // <--                                  // add	x17, x17, #64
	ADD  $64, R4, R4   // <--                                  // add	x4, x4, #64
	CMP  $127, R21     // <--                                  // cmp	x21, #127
	ADD  $64, R6, R6   // <--                                  // add	x6, x6, #64
	ADD  $64, R7, R7   // <--                                  // add	x7, x7, #64
	MOVD R22, R21      // <--                                  // mov	x21, x22
	BGT  LBB2_5        // <--                                  // b.gt	.LBB2_5
	JMP  LBB2_109      // <--                                  // b	.LBB2_109

LBB2_107:
	MOVD ZR, R0         // <--                                  // mov	x0, xzr
	MOVD R0, ret+48(FP) // <--
	RET                 // <--                                  // ret

LBB2_108:
	MOVD R21, R22 // <--                                  // mov	x22, x21

LBB2_109:
	CMP  $16, R15                    // <--                                  // cmp	x15, #16
	BLT  LBB2_112                    // <--                                  // b.lt	.LBB2_112
	CMP  $16, R22                    // <--                                  // cmp	x22, #16
	BLT  LBB2_143                    // <--                                  // b.lt	.LBB2_143
	WORD $0x4f05e7e4                 // VMOVI $191, V4.B16                   // movi	v4.16b, #191
	WORD $0x4f00e745                 // VMOVI $26, V5.B16                    // movi	v5.16b, #26
	MOVD 24(RSP), R8                 // <--                                  // ldr	x8, [sp, #24]
	WORD $0x4f01e406                 // VMOVI $32, V6.B16                    // movi	v6.16b, #32
	MOVD $-16, R7                    // <--                                  // mov	x7, #-16
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	SUB  R8, R17, R8                 // <--                                  // sub	x8, x17, x8
	ADD  R8, R0, R6                  // <--                                  // add	x6, x0, x8
	JMP  LBB2_116                    // <--                                  // b	.LBB2_116

LBB2_112:
	CMP  $0, R15                    // <--                                  // cmp	x15, #0
	BLE  LBB2_141                   // <--                                  // b.le	.LBB2_141
	CMP  $16, R22                   // <--                                  // cmp	x22, #16
	BLT  LBB2_150                   // <--                                  // b.lt	.LBB2_150
	WORD $0x4f05e7e4                // VMOVI $191, V4.B16                   // movi	v4.16b, #191
	WORD $0x4f00e745                // VMOVI $26, V5.B16                    // movi	v5.16b, #26
	MOVD $-16, R6                   // <--                                  // mov	x6, #-16
	WORD $0x4f01e406                // VMOVI $32, V6.B16                    // movi	v6.16b, #32
	MOVD $tail_mask_table<>(SB), R7 // <--                                  // adrp	x7, tail_mask_table
	NOP                             // (skipped)                            // add	x7, x7, :lo12:tail_mask_table
	JMP  LBB2_133                   // <--                                  // b	.LBB2_133

LBB2_115:
	SUB  $16, R22, R4  // <--                                  // sub	x4, x22, #16
	CMP  $31, R22      // <--                                  // cmp	x22, #31
	ADD  $16, R17, R17 // <--                                  // add	x17, x17, #16
	ADD  $16, R6, R6   // <--                                  // add	x6, x6, #16
	MOVD R4, R22       // <--                                  // mov	x22, x4
	BLE  LBB2_151      // <--                                  // b.le	.LBB2_151

LBB2_116:
	WORD  $0x3dc00227              // FMOVQ (R17), F7                      // ldr	q7, [x17]
	WORD  $0x3ce56a30              // FMOVQ (R17)(R5), F16                 // ldr	q16, [x17, x5]
	VORR  V0.B16, V7.B16, V7.B16   // <--                                  // orr	v7.16b, v7.16b, v0.16b
	VORR  V2.B16, V16.B16, V16.B16 // <--                                  // orr	v16.16b, v16.16b, v2.16b
	VCMEQ V1.B16, V7.B16, V7.B16   // <--                                  // cmeq	v7.16b, v7.16b, v1.16b
	VCMEQ V3.B16, V16.B16, V16.B16 // <--                                  // cmeq	v16.16b, v16.16b, v3.16b
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x0f0c84e7              // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R4                   // <--                                  // fmov	x4, d7
	CBZ   R4, LBB2_115             // <--                                  // cbz	x4, .LBB2_115
	MOVD  8(RSP), R8               // <--                                  // ldr	x8, [sp, #8]
	SUB   R22, R8, R8              // <--                                  // sub	x8, x8, x22
	ASR   $3, R8, R8               // <--                                  // asr	x8, x8, #3
	ADD   $32, R8, R20             // <--                                  // add	x20, x8, #32
	MOVD  24(RSP), R8              // <--                                  // ldr	x8, [sp, #24]
	SUB   R8, R17, R21             // <--                                  // sub	x21, x17, x8
	JMP   LBB2_119                 // <--                                  // b	.LBB2_119

LBB2_118:
	AND  $60, R23, R8 // <--                                  // and	x8, x23, #0x3c
	LSL  R8, R7, R8   // <--                                  // lsl	x8, x7, x8
	ANDS R4, R8, R4   // <--                                  // ands	x4, x8, x4
	BEQ  LBB2_115     // <--                                  // b.eq	.LBB2_115

LBB2_119:
	RBIT R4, R8       // <--                                  // rbit	x8, x4
	CLZ  R8, R23      // <--                                  // clz	x23, x8
	LSR  $2, R23, R24 // <--                                  // lsr	x24, x23, #2
	ADDS R24, R21, R8 // <--                                  // adds	x8, x21, x24
	BMI  LBB2_118     // <--                                  // b.mi	.LBB2_118
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BGT  LBB2_118     // <--                                  // b.gt	.LBB2_118
	SUB  R8, R1, R13  // <--                                  // sub	x13, x1, x8
	CMP  $16, R13     // <--                                  // cmp	x13, #16
	BLT  LBB2_127     // <--                                  // b.lt	.LBB2_127
	MOVD ZR, R25      // <--                                  // mov	x25, xzr
	ADD  R24, R6, R14 // <--                                  // add	x14, x6, x24
	MOVD R15, R3      // <--                                  // mov	x3, x15

LBB2_123:
	WORD  $0x3cf969c7              // FMOVQ (R14)(R25), F7                 // ldr	q7, [x14, x25]
	VADD  V4.B16, V7.B16, V16.B16  // <--                                  // add	v16.16b, v7.16b, v4.16b
	WORD  $0x6e3034b0              // VCMHI V16.B16, V5.B16, V16.B16       // cmhi	v16.16b, v5.16b, v16.16b
	VAND  V6.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v6.16b
	VORR  V7.B16, V16.B16, V7.B16  // <--                                  // orr	v7.16b, v16.16b, v7.16b
	WORD  $0x3cf96850              // FMOVQ (R2)(R25), F16                 // ldr	q16, [x2, x25]
	VEOR  V16.B16, V7.B16, V7.B16  // <--                                  // eor	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7              // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                  // <--                                  // fmov	w11, s7
	CBNZW R11, LBB2_130            // <--                                  // cbnz	w11, .LBB2_130
	CMP   $32, R3                  // <--                                  // cmp	x3, #32
	SUB   $16, R3, R26             // <--                                  // sub	x26, x3, #16
	ADD   $16, R25, R25            // <--                                  // add	x25, x25, #16
	BLT   LBB2_126                 // <--                                  // b.lt	.LBB2_126
	CMP   $31, R13                 // <--                                  // cmp	x13, #31
	SUB   $16, R13, R13            // <--                                  // sub	x13, x13, #16
	MOVD  R26, R3                  // <--                                  // mov	x3, x26
	BGT   LBB2_123                 // <--                                  // b.gt	.LBB2_123

LBB2_126:
	ADD R24, R6, R11  // <--                                  // add	x11, x6, x24
	ADD R25, R11, R13 // <--                                  // add	x13, x11, x25
	ADD R25, R2, R11  // <--                                  // add	x11, x2, x25
	JMP LBB2_128      // <--                                  // b	.LBB2_128

LBB2_127:
	ADD  R8, R0, R13 // <--                                  // add	x13, x0, x8
	MOVD R15, R26    // <--                                  // mov	x26, x15
	MOVD R2, R11     // <--                                  // mov	x11, x2

LBB2_128:
	CMP   $1, R26                  // <--                                  // cmp	x26, #1
	BLT   LBB2_171                 // <--                                  // b.lt	.LBB2_171
	WORD  $0x3dc001a7              // FMOVQ (R13), F7                      // ldr	q7, [x13]
	VADD  V4.B16, V7.B16, V16.B16  // <--                                  // add	v16.16b, v7.16b, v4.16b
	WORD  $0x6e3034b0              // VCMHI V16.B16, V5.B16, V16.B16       // cmhi	v16.16b, v5.16b, v16.16b
	VAND  V6.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v6.16b
	VORR  V7.B16, V16.B16, V7.B16  // <--                                  // orr	v7.16b, v16.16b, v7.16b
	WORD  $0x3dc00170              // FMOVQ (R11), F16                     // ldr	q16, [x11]
	VEOR  V16.B16, V7.B16, V7.B16  // <--                                  // eor	v7.16b, v7.16b, v16.16b
	WORD  $0x3cfa7a70              // FMOVQ (R19)(R26<<4), F16             // ldr	q16, [x19, x26, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7              // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                  // <--                                  // fmov	w11, s7
	CBZW  R11, LBB2_171            // <--                                  // cbz	w11, .LBB2_171

LBB2_130:
	CMP R20, R16     // <--                                  // cmp	x16, x20
	BGE LBB2_169     // <--                                  // b.ge	.LBB2_169
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1
	JMP LBB2_118     // <--                                  // b	.LBB2_118

LBB2_132:
	SUB  $16, R22, R4  // <--                                  // sub	x4, x22, #16
	CMP  $31, R22      // <--                                  // cmp	x22, #31
	ADD  $16, R17, R17 // <--                                  // add	x17, x17, #16
	MOVD R4, R22       // <--                                  // mov	x22, x4
	BLE  LBB2_151      // <--                                  // b.le	.LBB2_151

LBB2_133:
	WORD  $0x3dc00227              // FMOVQ (R17), F7                      // ldr	q7, [x17]
	WORD  $0x3ce56a30              // FMOVQ (R17)(R5), F16                 // ldr	q16, [x17, x5]
	VORR  V0.B16, V7.B16, V7.B16   // <--                                  // orr	v7.16b, v7.16b, v0.16b
	VORR  V2.B16, V16.B16, V16.B16 // <--                                  // orr	v16.16b, v16.16b, v2.16b
	VCMEQ V1.B16, V7.B16, V7.B16   // <--                                  // cmeq	v7.16b, v7.16b, v1.16b
	VCMEQ V3.B16, V16.B16, V16.B16 // <--                                  // cmeq	v16.16b, v16.16b, v3.16b
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x0f0c84e7              // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R4                   // <--                                  // fmov	x4, d7
	CBZ   R4, LBB2_132             // <--                                  // cbz	x4, .LBB2_132
	MOVD  8(RSP), R8               // <--                                  // ldr	x8, [sp, #8]
	SUB   R22, R8, R8              // <--                                  // sub	x8, x8, x22
	ASR   $3, R8, R8               // <--                                  // asr	x8, x8, #3
	ADD   $32, R8, R19             // <--                                  // add	x19, x8, #32
	MOVD  24(RSP), R8              // <--                                  // ldr	x8, [sp, #24]
	SUB   R8, R17, R20             // <--                                  // sub	x20, x17, x8
	JMP   LBB2_136                 // <--                                  // b	.LBB2_136

LBB2_135:
	AND  $60, R13, R8 // <--                                  // and	x8, x13, #0x3c
	LSL  R8, R6, R8   // <--                                  // lsl	x8, x6, x8
	ANDS R4, R8, R4   // <--                                  // ands	x4, x8, x4
	BEQ  LBB2_132     // <--                                  // b.eq	.LBB2_132

LBB2_136:
	RBIT  R4, R8                   // <--                                  // rbit	x8, x4
	CLZ   R8, R13                  // <--                                  // clz	x13, x8
	ADDS  R13>>2, R20, R8          // <--                                  // adds	x8, x20, x13, lsr #2
	BMI   LBB2_135                 // <--                                  // b.mi	.LBB2_135
	CMP   R9, R8                   // <--                                  // cmp	x8, x9
	BGT   LBB2_135                 // <--                                  // b.gt	.LBB2_135
	WORD  $0x3ce86807              // FMOVQ (R0)(R8), F7                   // ldr	q7, [x0, x8]
	VADD  V4.B16, V7.B16, V16.B16  // <--                                  // add	v16.16b, v7.16b, v4.16b
	WORD  $0x6e3034b0              // VCMHI V16.B16, V5.B16, V16.B16       // cmhi	v16.16b, v5.16b, v16.16b
	VAND  V6.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v6.16b
	VORR  V7.B16, V16.B16, V7.B16  // <--                                  // orr	v7.16b, v16.16b, v7.16b
	WORD  $0x3dc00050              // FMOVQ (R2), F16                      // ldr	q16, [x2]
	VEOR  V16.B16, V7.B16, V7.B16  // <--                                  // eor	v7.16b, v7.16b, v16.16b
	WORD  $0x3cef78f0              // FMOVQ (R7)(R15<<4), F16              // ldr	q16, [x7, x15, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7              // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                  // <--                                  // fmov	w11, s7
	CBZW  R11, LBB2_171            // <--                                  // cbz	w11, .LBB2_171
	CMP   R19, R16                 // <--                                  // cmp	x16, x19
	BGE   LBB2_169                 // <--                                  // b.ge	.LBB2_169
	ADD   $1, R16, R16             // <--                                  // add	x16, x16, #1
	JMP   LBB2_135                 // <--                                  // b	.LBB2_135

LBB2_141:
	CMP  $16, R22     // <--                                  // cmp	x22, #16
	BLT  LBB2_143     // <--                                  // b.lt	.LBB2_143
	MOVD 24(RSP), R11 // <--                                  // ldr	x11, [sp, #24]
	MOVD $-16, R6     // <--                                  // mov	x6, #-16
	JMP  LBB2_145     // <--                                  // b	.LBB2_145

LBB2_143:
	MOVD R22, R4  // <--                                  // mov	x4, x22
	CMP  $1, R22  // <--                                  // cmp	x22, #1
	BGE  LBB2_152 // <--                                  // b.ge	.LBB2_152
	JMP  LBB2_170 // <--                                  // b	.LBB2_170

LBB2_144:
	SUB  $16, R22, R4  // <--                                  // sub	x4, x22, #16
	CMP  $31, R22      // <--                                  // cmp	x22, #31
	ADD  $16, R17, R17 // <--                                  // add	x17, x17, #16
	MOVD R4, R22       // <--                                  // mov	x22, x4
	BLE  LBB2_151      // <--                                  // b.le	.LBB2_151

LBB2_145:
	WORD  $0x3dc00224            // FMOVQ (R17), F4                      // ldr	q4, [x17]
	WORD  $0x3ce56a25            // FMOVQ (R17)(R5), F5                  // ldr	q5, [x17, x5]
	VORR  V0.B16, V4.B16, V4.B16 // <--                                  // orr	v4.16b, v4.16b, v0.16b
	VORR  V2.B16, V5.B16, V5.B16 // <--                                  // orr	v5.16b, v5.16b, v2.16b
	VCMEQ V1.B16, V4.B16, V4.B16 // <--                                  // cmeq	v4.16b, v4.16b, v1.16b
	VCMEQ V3.B16, V5.B16, V5.B16 // <--                                  // cmeq	v5.16b, v5.16b, v3.16b
	VAND  V5.B16, V4.B16, V4.B16 // <--                                  // and	v4.16b, v4.16b, v5.16b
	WORD  $0x0f0c8484            // VSHRN $4, V4.H8, V4.B8               // shrn	v4.8b, v4.8h, #4
	FMOVD F4, R13                // <--                                  // fmov	x13, d4
	CBZ   R13, LBB2_144          // <--                                  // cbz	x13, .LBB2_144
	RBIT  R13, R8                // <--                                  // rbit	x8, x13
	SUB   R11, R17, R14          // <--                                  // sub	x14, x17, x11
	CLZ   R8, R3                 // <--                                  // clz	x3, x8
	ADDS  R3>>2, R14, R8         // <--                                  // adds	x8, x14, x3, lsr #2
	BMI   LBB2_148               // <--                                  // b.mi	.LBB2_148

LBB2_147:
	CMP R9, R8   // <--                                  // cmp	x8, x9
	BLE LBB2_171 // <--                                  // b.le	.LBB2_171

LBB2_148:
	AND  $60, R3, R8    // <--                                  // and	x8, x3, #0x3c
	LSL  R8, R6, R8     // <--                                  // lsl	x8, x6, x8
	ANDS R13, R8, R13   // <--                                  // ands	x13, x8, x13
	BEQ  LBB2_144       // <--                                  // b.eq	.LBB2_144
	RBIT R13, R8        // <--                                  // rbit	x8, x13
	CLZ  R8, R3         // <--                                  // clz	x3, x8
	ADDS R3>>2, R14, R8 // <--                                  // adds	x8, x14, x3, lsr #2
	BPL  LBB2_147       // <--                                  // b.pl	.LBB2_147
	JMP  LBB2_148       // <--                                  // b	.LBB2_148

LBB2_150:
	MOVD R22, R4 // <--                                  // mov	x4, x22

LBB2_151:
	CMP $1, R4   // <--                                  // cmp	x4, #1
	BLT LBB2_170 // <--                                  // b.lt	.LBB2_170

LBB2_152:
	WORD $0x4f05e7e0                // VMOVI $191, V0.B16                   // movi	v0.16b, #191
	WORD $0x4f00e741                // VMOVI $26, V1.B16                    // movi	v1.16b, #26
	MOVD 24(RSP), R13               // <--                                  // ldr	x13, [sp, #24]
	WORD $0x4f01e402                // VMOVI $32, V2.B16                    // movi	v2.16b, #32
	MOVD $tail_mask_table<>(SB), R6 // <--                                  // adrp	x6, tail_mask_table
	NOP                             // (skipped)                            // add	x6, x6, :lo12:tail_mask_table
	JMP  LBB2_154                   // <--                                  // b	.LBB2_154

LBB2_153:
	SUBS $1, R4, R4   // <--                                  // subs	x4, x4, #1
	ADD  $1, R17, R17 // <--                                  // add	x17, x17, #1
	BLE  LBB2_170     // <--                                  // b.le	.LBB2_170

LBB2_154:
	WORD  $0x39400228       // MOVBU (R17), R8                      // ldrb	w8, [x17]
	ORRW  R12, R8, R8       // <--                                  // orr	w8, w8, w12
	CMPW  R10, R8           // <--                                  // cmp	w8, w10
	BNE   LBB2_153          // <--                                  // b.ne	.LBB2_153
	WORD  $0x38656a28       // MOVBU (R17)(R5), R8                  // ldrb	w8, [x17, x5]
	MOVWU (RSP), R11        // <--                                  // ldr	w11, [sp]
	ORRW  R11, R8, R8       // <--                                  // orr	w8, w8, w11
	MOVWU 4(RSP), R11       // <--                                  // ldr	w11, [sp, #4]
	CMPW  R11, R8           // <--                                  // cmp	w8, w11
	BNE   LBB2_153          // <--                                  // b.ne	.LBB2_153
	SUB   R13, R17, R8      // <--                                  // sub	x8, x17, x13
	TBNZ  $63, R8, LBB2_153 // <--                                  // tbnz	x8, #63, .LBB2_153
	CMP   R9, R8            // <--                                  // cmp	x8, x9
	BGT   LBB2_153          // <--                                  // b.gt	.LBB2_153
	CMP   $16, R15          // <--                                  // cmp	x15, #16
	ADD   R8, R0, R7        // <--                                  // add	x7, x0, x8
	BLT   LBB2_164          // <--                                  // b.lt	.LBB2_164
	SUB   R8, R1, R13       // <--                                  // sub	x13, x1, x8
	CMP   $16, R13          // <--                                  // cmp	x13, #16
	BLT   LBB2_164          // <--                                  // b.lt	.LBB2_164
	MOVD  R2, R19           // <--                                  // mov	x19, x2
	MOVD  R15, R3           // <--                                  // mov	x3, x15

LBB2_161:
	WORD  $0x3cc104e3            // FMOVQ.P 16(R7), F3                   // ldr	q3, [x7], #16
	VADD  V0.B16, V3.B16, V4.B16 // <--                                  // add	v4.16b, v3.16b, v0.16b
	WORD  $0x6e243424            // VCMHI V4.B16, V1.B16, V4.B16         // cmhi	v4.16b, v1.16b, v4.16b
	VAND  V2.B16, V4.B16, V4.B16 // <--                                  // and	v4.16b, v4.16b, v2.16b
	VORR  V3.B16, V4.B16, V3.B16 // <--                                  // orr	v3.16b, v4.16b, v3.16b
	WORD  $0x3cc10664            // FMOVQ.P 16(R19), F4                  // ldr	q4, [x19], #16
	VEOR  V4.B16, V3.B16, V3.B16 // <--                                  // eor	v3.16b, v3.16b, v4.16b
	WORD  $0x6e30a863            // VUMAXV V3.B16, V3                    // umaxv	b3, v3.16b
	FMOVS F3, R11                // <--                                  // fmov	w11, s3
	CBNZW R11, LBB2_167          // <--                                  // cbnz	w11, .LBB2_167
	CMP   $32, R3                // <--                                  // cmp	x3, #32
	SUB   $16, R3, R14           // <--                                  // sub	x14, x3, #16
	BLT   LBB2_165               // <--                                  // b.lt	.LBB2_165
	CMP   $31, R13               // <--                                  // cmp	x13, #31
	SUB   $16, R13, R13          // <--                                  // sub	x13, x13, #16
	MOVD  R14, R3                // <--                                  // mov	x3, x14
	BGT   LBB2_161               // <--                                  // b.gt	.LBB2_161
	JMP   LBB2_165               // <--                                  // b	.LBB2_165

LBB2_164:
	MOVD R15, R14 // <--                                  // mov	x14, x15
	MOVD R2, R19  // <--                                  // mov	x19, x2

LBB2_165:
	CMP   $1, R14                // <--                                  // cmp	x14, #1
	BLT   LBB2_171               // <--                                  // b.lt	.LBB2_171
	WORD  $0x3dc000e3            // FMOVQ (R7), F3                       // ldr	q3, [x7]
	VADD  V0.B16, V3.B16, V4.B16 // <--                                  // add	v4.16b, v3.16b, v0.16b
	WORD  $0x6e243424            // VCMHI V4.B16, V1.B16, V4.B16         // cmhi	v4.16b, v1.16b, v4.16b
	VAND  V2.B16, V4.B16, V4.B16 // <--                                  // and	v4.16b, v4.16b, v2.16b
	VORR  V3.B16, V4.B16, V3.B16 // <--                                  // orr	v3.16b, v4.16b, v3.16b
	WORD  $0x3dc00264            // FMOVQ (R19), F4                      // ldr	q4, [x19]
	VEOR  V4.B16, V3.B16, V3.B16 // <--                                  // eor	v3.16b, v3.16b, v4.16b
	WORD  $0x3cee78c4            // FMOVQ (R6)(R14<<4), F4               // ldr	q4, [x6, x14, lsl #4]
	VAND  V4.B16, V3.B16, V3.B16 // <--                                  // and	v3.16b, v3.16b, v4.16b
	WORD  $0x6e30a863            // VUMAXV V3.B16, V3                    // umaxv	b3, v3.16b
	FMOVS F3, R11                // <--                                  // fmov	w11, s3
	CBZW  R11, LBB2_171          // <--                                  // cbz	w11, .LBB2_171

LBB2_167:
	MOVD 8(RSP), R11   // <--                                  // ldr	x11, [sp, #8]
	SUB  R4, R11, R11  // <--                                  // sub	x11, x11, x4
	ASR  $3, R11, R11  // <--                                  // asr	x11, x11, #3
	ADD  $32, R11, R11 // <--                                  // add	x11, x11, #32
	CMP  R11, R16      // <--                                  // cmp	x16, x11
	BGE  LBB2_169      // <--                                  // b.ge	.LBB2_169
	MOVD 24(RSP), R13  // <--                                  // ldr	x13, [sp, #24]
	ADD  $1, R16, R16  // <--                                  // add	x16, x16, #1
	JMP  LBB2_153      // <--                                  // b	.LBB2_153

LBB2_169:
	MOVD $-9223372036854775807, R9 // <--                                  // mov	x9, #-9223372036854775807
	ADD  R9, R8, R8                // <--                                  // add	x8, x8, x9
	JMP  LBB2_171                  // <--                                  // b	.LBB2_171

LBB2_170:
	MOVD $-1, R8 // <--                                  // mov	x8, #-1

LBB2_171:
	NOP                 // (skipped)                            // ldp	x20, x19, [sp, #80]
	MOVD 16(RSP), R30   // <--                                  // ldr	x30, [sp, #16]
	NOP                 // (skipped)                            // ldp	x22, x21, [sp, #64]
	NOP                 // (skipped)                            // ldp	x24, x23, [sp, #48]
	NOP                 // (skipped)                            // ldp	x26, x25, [sp, #32]
	NOP                 // (skipped)                            // add	sp, sp, #96
	MOVD R8, R0         // <--                                  // mov	x0, x8
	MOVD R0, ret+48(FP) // <--
	RET                 // <--                                  // ret


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


TEXT ·indexFold2ByteRaw(SB), 0, $96-56
	MOVD haystack+0(FP), R0
	MOVD haystack_len+8(FP), R1
	MOVD needle+16(FP), R2
	MOVD needle_len+24(FP), R3
	MOVD off1+32(FP), R4
	MOVD off2_delta+40(FP), R5
	SUBS R3, R1, R9             // <--                                  // subs	x9, x1, x3
	BGE  LBB5_2                 // <--                                  // b.ge	.LBB5_2
	MOVD $-1, R0                // <--                                  // mov	x0, #-1
	MOVD R0, ret+48(FP)         // <--
	RET                         // <--                                  // ret

LBB5_2:
	MOVD  R3, R15                     // <--                                  // mov	x15, x3
	CBZ   R3, LBB5_107                // <--                                  // cbz	x3, .LBB5_107
	NOP                               // (skipped)                            // sub	sp, sp, #96
	ADD   R4, R2, R8                  // <--                                  // add	x8, x2, x4
	NOP                               // (skipped)                            // stp	x22, x21, [sp, #64]
	ADD   $1, R9, R21                 // <--                                  // add	x21, x9, #1
	WORD  $0x3940010a                 // MOVBU (R8), R10                      // ldrb	w10, [x8]
	WORD  $0x38656908                 // MOVBU (R8)(R5), R8                   // ldrb	w8, [x8, x5]
	ADD   R4, R0, R17                 // <--                                  // add	x17, x0, x4
	MOVD  ZR, R16                     // <--                                  // mov	x16, xzr
	MOVD  R30, 16(RSP)                // <--                                  // str	x30, [sp, #16]
	SUBW  $65, R10, R11               // <--                                  // sub	w11, w10, #65
	ORRW  $32, R10, R12               // <--                                  // orr	w12, w10, #0x20
	NOP                               // (skipped)                            // stp	x26, x25, [sp, #32]
	CMPW  $26, R11                    // <--                                  // cmp	w11, #26
	SUBW  $65, R8, R11                // <--                                  // sub	w11, w8, #65
	NOP                               // (skipped)                            // stp	x24, x23, [sp, #48]
	CSELW LO, R12, R10, R10           // <--                                  // csel	w10, w12, w10, lo
	ORRW  $32, R8, R12                // <--                                  // orr	w12, w8, #0x20
	CMPW  $26, R11                    // <--                                  // cmp	w11, #26
	CSELW LO, R12, R8, R13            // <--                                  // csel	w13, w12, w8, lo
	SUBW  $97, R10, R8                // <--                                  // sub	w8, w10, #97
	VDUP  R10, V2.B16                 // <--                                  // dup	v2.16b, w10
	ANDW  $255, R8, R8                // <--                                  // and	w8, w8, #0xff
	SUBW  $97, R13, R11               // <--                                  // sub	w11, w13, #97
	VDUP  R13, V3.B16                 // <--                                  // dup	v3.16b, w13
	ANDW  $255, R11, R11              // <--                                  // and	w11, w11, #0xff
	CMPW  $26, R8                     // <--                                  // cmp	w8, #26
	MOVW  $32, R8                     // <--                                  // mov	w8, #32
	CSELW LO, R8, ZR, R12             // <--                                  // csel	w12, w8, wzr, lo
	CMPW  $26, R11                    // <--                                  // cmp	w11, #26
	NOP                               // (skipped)                            // stp	x20, x19, [sp, #80]
	CSELW LO, R8, ZR, R8              // <--                                  // csel	w8, w8, wzr, lo
	VDUP  R12, V0.B16                 // <--                                  // dup	v0.16b, w12
	CMP   $63, R9                     // <--                                  // cmp	x9, #63
	VDUP  R8, V1.B16                  // <--                                  // dup	v1.16b, w8
	STPW  (R8, R13), (RSP)            // <--                                  // stp	w8, w13, [sp]
	MOVD  R21, 8(RSP)                 // <--                                  // str	x21, [sp, #8]
	MOVD  R17, 24(RSP)                // <--                                  // str	x17, [sp, #24]
	BLT   LBB5_108                    // <--                                  // b.lt	.LBB5_108
	WORD  $0x4f05e7e4                 // VMOVI $191, V4.B16                   // movi	v4.16b, #191
	WORD  $0x4f00e745                 // VMOVI $26, V5.B16                    // movi	v5.16b, #26
	ADD   $16, R0, R4                 // <--                                  // add	x4, x0, #16
	WORD  $0x4f01e406                 // VMOVI $32, V6.B16                    // movi	v6.16b, #32
	ADD   $32, R0, R6                 // <--                                  // add	x6, x0, #32
	ADD   $48, R0, R7                 // <--                                  // add	x7, x0, #48
	MOVD  $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                               // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	MOVD  $-16, R20                   // <--                                  // mov	x20, #-16

LBB5_5:
	ADD   R5, R17, R8               // <--                                  // add	x8, x17, x5
	WORD  $0xad404227               // FLDPQ (R17), (F7, F16)               // ldp	q7, q16, [x17]
	WORD  $0xad414a31               // FLDPQ 32(R17), (F17, F18)            // ldp	q17, q18, [x17, #32]
	WORD  $0xad405113               // FLDPQ (R8), (F19, F20)               // ldp	q19, q20, [x8]
	WORD  $0xad415915               // FLDPQ 32(R8), (F21, F22)             // ldp	q21, q22, [x8, #32]
	VORR  V0.B16, V7.B16, V7.B16    // <--                                  // orr	v7.16b, v7.16b, v0.16b
	VORR  V0.B16, V16.B16, V16.B16  // <--                                  // orr	v16.16b, v16.16b, v0.16b
	VORR  V0.B16, V17.B16, V17.B16  // <--                                  // orr	v17.16b, v17.16b, v0.16b
	VORR  V0.B16, V18.B16, V18.B16  // <--                                  // orr	v18.16b, v18.16b, v0.16b
	VORR  V1.B16, V19.B16, V19.B16  // <--                                  // orr	v19.16b, v19.16b, v1.16b
	VORR  V1.B16, V20.B16, V20.B16  // <--                                  // orr	v20.16b, v20.16b, v1.16b
	VORR  V1.B16, V21.B16, V21.B16  // <--                                  // orr	v21.16b, v21.16b, v1.16b
	VORR  V1.B16, V22.B16, V22.B16  // <--                                  // orr	v22.16b, v22.16b, v1.16b
	VCMEQ V2.B16, V7.B16, V7.B16    // <--                                  // cmeq	v7.16b, v7.16b, v2.16b
	VCMEQ V2.B16, V16.B16, V16.B16  // <--                                  // cmeq	v16.16b, v16.16b, v2.16b
	VCMEQ V2.B16, V17.B16, V23.B16  // <--                                  // cmeq	v23.16b, v17.16b, v2.16b
	VCMEQ V2.B16, V18.B16, V24.B16  // <--                                  // cmeq	v24.16b, v18.16b, v2.16b
	VCMEQ V3.B16, V19.B16, V17.B16  // <--                                  // cmeq	v17.16b, v19.16b, v3.16b
	VCMEQ V3.B16, V20.B16, V19.B16  // <--                                  // cmeq	v19.16b, v20.16b, v3.16b
	VCMEQ V3.B16, V21.B16, V20.B16  // <--                                  // cmeq	v20.16b, v21.16b, v3.16b
	VCMEQ V3.B16, V22.B16, V21.B16  // <--                                  // cmeq	v21.16b, v22.16b, v3.16b
	VAND  V17.B16, V7.B16, V18.B16  // <--                                  // and	v18.16b, v7.16b, v17.16b
	VAND  V19.B16, V16.B16, V17.B16 // <--                                  // and	v17.16b, v16.16b, v19.16b
	VAND  V20.B16, V23.B16, V16.B16 // <--                                  // and	v16.16b, v23.16b, v20.16b
	VAND  V21.B16, V24.B16, V7.B16  // <--                                  // and	v7.16b, v24.16b, v21.16b
	VORR  V18.B16, V17.B16, V19.B16 // <--                                  // orr	v19.16b, v17.16b, v18.16b
	VORR  V7.B16, V16.B16, V20.B16  // <--                                  // orr	v20.16b, v16.16b, v7.16b
	VORR  V20.B16, V19.B16, V19.B16 // <--                                  // orr	v19.16b, v19.16b, v20.16b
	WORD  $0x4ef3be73               // VADDP V19.D2, V19.D2, V19.D2         // addp	v19.2d, v19.2d, v19.2d
	FMOVD F19, R8                   // <--                                  // fmov	x8, d19
	CBZ   R8, LBB5_106              // <--                                  // cbz	x8, .LBB5_106
	MOVD  8(RSP), R8                // <--                                  // ldr	x8, [sp, #8]
	WORD  $0x0f0c8652               // VSHRN $4, V18.H8, V18.B8             // shrn	v18.8b, v18.8h, #4
	CMP   $16, R15                  // <--                                  // cmp	x15, #16
	SUB   R21, R8, R8               // <--                                  // sub	x8, x8, x21
	LSR   $3, R8, R8                // <--                                  // lsr	x8, x8, #3
	FMOVD F18, R24                  // <--                                  // fmov	x24, d18
	ADD   $32, R8, R22              // <--                                  // add	x22, x8, #32
	MOVD  24(RSP), R8               // <--                                  // ldr	x8, [sp, #24]
	SUB   R8, R17, R23              // <--                                  // sub	x23, x17, x8
	BLT   LBB5_33                   // <--                                  // b.lt	.LBB5_33
	CBNZ  R24, LBB5_11              // <--                                  // cbnz	x24, .LBB5_11

LBB5_8:
	WORD  $0x0f0c8631   // VSHRN $4, V17.H8, V17.B8             // shrn	v17.8b, v17.8h, #4
	FMOVD F17, R24      // <--                                  // fmov	x24, d17
	CBZ   R24, LBB5_47  // <--                                  // cbz	x24, .LBB5_47
	ADD   $16, R23, R25 // <--                                  // add	x25, x23, #16
	JMP   LBB5_23       // <--                                  // b	.LBB5_23

LBB5_10:
	AND  $60, R25, R8 // <--                                  // and	x8, x25, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_8       // <--                                  // b.eq	.LBB5_8

LBB5_11:
	RBIT R24, R8         // <--                                  // rbit	x8, x24
	CLZ  R8, R25         // <--                                  // clz	x25, x8
	ADD  R25>>2, R23, R8 // <--                                  // add	x8, x23, x25, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BHI  LBB5_10         // <--                                  // b.hi	.LBB5_10
	SUB  R8, R1, R13     // <--                                  // sub	x13, x1, x8
	ADD  R8, R0, R30     // <--                                  // add	x30, x0, x8
	MOVD R15, R14        // <--                                  // mov	x14, x15
	CMP  $16, R13        // <--                                  // cmp	x13, #16
	MOVD R2, R26         // <--                                  // mov	x26, x2
	MOVD R15, R3         // <--                                  // mov	x3, x15
	BLT  LBB5_16         // <--                                  // b.lt	.LBB5_16

LBB5_13:
	WORD  $0x3cc107d2               // FMOVQ.P 16(R30), F18                 // ldr	q18, [x30], #16
	WORD  $0x3cc10753               // FMOVQ.P 16(R26), F19                 // ldr	q19, [x26], #16
	VADD  V4.B16, V18.B16, V20.B16  // <--                                  // add	v20.16b, v18.16b, v4.16b
	VADD  V4.B16, V19.B16, V21.B16  // <--                                  // add	v21.16b, v19.16b, v4.16b
	WORD  $0x6e3434b4               // VCMHI V20.B16, V5.B16, V20.B16       // cmhi	v20.16b, v5.16b, v20.16b
	WORD  $0x6e3534b5               // VCMHI V21.B16, V5.B16, V21.B16       // cmhi	v21.16b, v5.16b, v21.16b
	VAND  V6.B16, V20.B16, V20.B16  // <--                                  // and	v20.16b, v20.16b, v6.16b
	VAND  V6.B16, V21.B16, V21.B16  // <--                                  // and	v21.16b, v21.16b, v6.16b
	VORR  V18.B16, V20.B16, V18.B16 // <--                                  // orr	v18.16b, v20.16b, v18.16b
	VORR  V19.B16, V21.B16, V19.B16 // <--                                  // orr	v19.16b, v21.16b, v19.16b
	VEOR  V18.B16, V19.B16, V18.B16 // <--                                  // eor	v18.16b, v19.16b, v18.16b
	WORD  $0x6e30aa52               // VUMAXV V18.B16, V18                  // umaxv	b18, v18.16b
	FMOVS F18, R11                  // <--                                  // fmov	w11, s18
	CBNZW R11, LBB5_18              // <--                                  // cbnz	w11, .LBB5_18
	CMP   $32, R3                   // <--                                  // cmp	x3, #32
	SUB   $16, R3, R14              // <--                                  // sub	x14, x3, #16
	BLT   LBB5_16                   // <--                                  // b.lt	.LBB5_16
	CMP   $31, R13                  // <--                                  // cmp	x13, #31
	SUB   $16, R13, R13             // <--                                  // sub	x13, x13, #16
	MOVD  R14, R3                   // <--                                  // mov	x3, x14
	BGT   LBB5_13                   // <--                                  // b.gt	.LBB5_13

LBB5_16:
	CMP   $1, R14                   // <--                                  // cmp	x14, #1
	BLT   LBB5_171                  // <--                                  // b.lt	.LBB5_171
	WORD  $0x3dc003d2               // FMOVQ (R30), F18                     // ldr	q18, [x30]
	WORD  $0x3dc00353               // FMOVQ (R26), F19                     // ldr	q19, [x26]
	VADD  V4.B16, V18.B16, V20.B16  // <--                                  // add	v20.16b, v18.16b, v4.16b
	VADD  V4.B16, V19.B16, V21.B16  // <--                                  // add	v21.16b, v19.16b, v4.16b
	WORD  $0x6e3434b4               // VCMHI V20.B16, V5.B16, V20.B16       // cmhi	v20.16b, v5.16b, v20.16b
	WORD  $0x6e3534b5               // VCMHI V21.B16, V5.B16, V21.B16       // cmhi	v21.16b, v5.16b, v21.16b
	VAND  V6.B16, V20.B16, V20.B16  // <--                                  // and	v20.16b, v20.16b, v6.16b
	VAND  V6.B16, V21.B16, V21.B16  // <--                                  // and	v21.16b, v21.16b, v6.16b
	VORR  V18.B16, V20.B16, V18.B16 // <--                                  // orr	v18.16b, v20.16b, v18.16b
	VORR  V19.B16, V21.B16, V19.B16 // <--                                  // orr	v19.16b, v21.16b, v19.16b
	VEOR  V18.B16, V19.B16, V18.B16 // <--                                  // eor	v18.16b, v19.16b, v18.16b
	WORD  $0x3cee7a73               // FMOVQ (R19)(R14<<4), F19             // ldr	q19, [x19, x14, lsl #4]
	VAND  V19.B16, V18.B16, V18.B16 // <--                                  // and	v18.16b, v18.16b, v19.16b
	WORD  $0x6e30aa52               // VUMAXV V18.B16, V18                  // umaxv	b18, v18.16b
	FMOVS F18, R11                  // <--                                  // fmov	w11, s18
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171

LBB5_18:
	CMP R22, R16     // <--                                  // cmp	x16, x22
	BGE LBB5_169     // <--                                  // b.ge	.LBB5_169
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1
	JMP LBB5_10      // <--                                  // b	.LBB5_10

LBB5_20:
	CMP  R22, R16                    // <--                                  // cmp	x16, x22
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	BGE  LBB5_169                    // <--                                  // b.ge	.LBB5_169
	ADD  $1, R16, R16                // <--                                  // add	x16, x16, #1

LBB5_22:
	AND  $60, R26, R8 // <--                                  // and	x8, x26, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_47      // <--                                  // b.eq	.LBB5_47

LBB5_23:
	RBIT R24, R8      // <--                                  // rbit	x8, x24
	CLZ  R8, R26      // <--                                  // clz	x26, x8
	LSR  $2, R26, R30 // <--                                  // lsr	x30, x26, #2
	ADD  R30, R25, R8 // <--                                  // add	x8, x25, x30
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BHI  LBB5_22      // <--                                  // b.hi	.LBB5_22
	SUB  R8, R1, R14  // <--                                  // sub	x14, x1, x8
	CMP  $16, R14     // <--                                  // cmp	x14, #16
	BLT  LBB5_30      // <--                                  // b.lt	.LBB5_30
	MOVD ZR, R13      // <--                                  // mov	x13, xzr
	ADD  R30, R4, R19 // <--                                  // add	x19, x4, x30
	MOVD R15, R3      // <--                                  // mov	x3, x15

LBB5_26:
	WORD  $0x3ced6a71               // FMOVQ (R19)(R13), F17                // ldr	q17, [x19, x13]
	WORD  $0x3ced6852               // FMOVQ (R2)(R13), F18                 // ldr	q18, [x2, x13]
	VADD  V4.B16, V17.B16, V19.B16  // <--                                  // add	v19.16b, v17.16b, v4.16b
	VADD  V4.B16, V18.B16, V20.B16  // <--                                  // add	v20.16b, v18.16b, v4.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	WORD  $0x6e3434b4               // VCMHI V20.B16, V5.B16, V20.B16       // cmhi	v20.16b, v5.16b, v20.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VAND  V6.B16, V20.B16, V20.B16  // <--                                  // and	v20.16b, v20.16b, v6.16b
	VORR  V17.B16, V19.B16, V17.B16 // <--                                  // orr	v17.16b, v19.16b, v17.16b
	VORR  V18.B16, V20.B16, V18.B16 // <--                                  // orr	v18.16b, v20.16b, v18.16b
	VEOR  V17.B16, V18.B16, V17.B16 // <--                                  // eor	v17.16b, v18.16b, v17.16b
	WORD  $0x6e30aa31               // VUMAXV V17.B16, V17                  // umaxv	b17, v17.16b
	FMOVS F17, R11                  // <--                                  // fmov	w11, s17
	CBNZW R11, LBB5_20              // <--                                  // cbnz	w11, .LBB5_20
	CMP   $32, R3                   // <--                                  // cmp	x3, #32
	SUB   $16, R3, R11              // <--                                  // sub	x11, x3, #16
	ADD   $16, R13, R13             // <--                                  // add	x13, x13, #16
	BLT   LBB5_29                   // <--                                  // b.lt	.LBB5_29
	CMP   $31, R14                  // <--                                  // cmp	x14, #31
	SUB   $16, R14, R14             // <--                                  // sub	x14, x14, #16
	MOVD  R11, R3                   // <--                                  // mov	x3, x11
	BGT   LBB5_26                   // <--                                  // b.gt	.LBB5_26

LBB5_29:
	ADD  R30, R4, R14                // <--                                  // add	x14, x4, x30
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	ADD  R13, R14, R14               // <--                                  // add	x14, x14, x13
	ADD  R13, R2, R13                // <--                                  // add	x13, x2, x13
	JMP  LBB5_31                     // <--                                  // b	.LBB5_31

LBB5_30:
	ADD  R8, R0, R14 // <--                                  // add	x14, x0, x8
	MOVD R15, R11    // <--                                  // mov	x11, x15
	MOVD R2, R13     // <--                                  // mov	x13, x2

LBB5_31:
	CMP   $1, R11                   // <--                                  // cmp	x11, #1
	BLT   LBB5_171                  // <--                                  // b.lt	.LBB5_171
	WORD  $0x3dc001d1               // FMOVQ (R14), F17                     // ldr	q17, [x14]
	WORD  $0x3dc001b2               // FMOVQ (R13), F18                     // ldr	q18, [x13]
	VADD  V4.B16, V17.B16, V19.B16  // <--                                  // add	v19.16b, v17.16b, v4.16b
	VADD  V4.B16, V18.B16, V20.B16  // <--                                  // add	v20.16b, v18.16b, v4.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	WORD  $0x6e3434b4               // VCMHI V20.B16, V5.B16, V20.B16       // cmhi	v20.16b, v5.16b, v20.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VAND  V6.B16, V20.B16, V20.B16  // <--                                  // and	v20.16b, v20.16b, v6.16b
	VORR  V17.B16, V19.B16, V17.B16 // <--                                  // orr	v17.16b, v19.16b, v17.16b
	VORR  V18.B16, V20.B16, V18.B16 // <--                                  // orr	v18.16b, v20.16b, v18.16b
	VEOR  V17.B16, V18.B16, V17.B16 // <--                                  // eor	v17.16b, v18.16b, v17.16b
	WORD  $0x3ceb7a72               // FMOVQ (R19)(R11<<4), F18             // ldr	q18, [x19, x11, lsl #4]
	VAND  V18.B16, V17.B16, V17.B16 // <--                                  // and	v17.16b, v17.16b, v18.16b
	WORD  $0x6e30aa31               // VUMAXV V17.B16, V17                  // umaxv	b17, v17.16b
	FMOVS F17, R11                  // <--                                  // fmov	w11, s17
	CBNZW R11, LBB5_20              // <--                                  // cbnz	w11, .LBB5_20
	JMP   LBB5_171                  // <--                                  // b	.LBB5_171

LBB5_33:
	CMP  $0, R15      // <--                                  // cmp	x15, #0
	BLE  LBB5_62      // <--                                  // b.le	.LBB5_62
	CBNZ R24, LBB5_44 // <--                                  // cbnz	x24, .LBB5_44

LBB5_35:
	WORD  $0x0f0c8631   // VSHRN $4, V17.H8, V17.B8             // shrn	v17.8b, v17.8h, #4
	FMOVD F17, R24      // <--                                  // fmov	x24, d17
	CBZ   R24, LBB5_77  // <--                                  // cbz	x24, .LBB5_77
	ADD   $16, R23, R13 // <--                                  // add	x13, x23, #16
	JMP   LBB5_38       // <--                                  // b	.LBB5_38

LBB5_37:
	AND  $60, R14, R8 // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_77      // <--                                  // b.eq	.LBB5_77

LBB5_38:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R14                   // <--                                  // clz	x14, x8
	ADD   R14>>2, R13, R8           // <--                                  // add	x8, x13, x14, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB5_37                   // <--                                  // b.hi	.LBB5_37
	WORD  $0x3ce86811               // FMOVQ (R0)(R8), F17                  // ldr	q17, [x0, x8]
	WORD  $0x3dc00052               // FMOVQ (R2), F18                      // ldr	q18, [x2]
	VADD  V4.B16, V17.B16, V19.B16  // <--                                  // add	v19.16b, v17.16b, v4.16b
	VADD  V4.B16, V18.B16, V20.B16  // <--                                  // add	v20.16b, v18.16b, v4.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	WORD  $0x6e3434b4               // VCMHI V20.B16, V5.B16, V20.B16       // cmhi	v20.16b, v5.16b, v20.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VAND  V6.B16, V20.B16, V20.B16  // <--                                  // and	v20.16b, v20.16b, v6.16b
	VORR  V17.B16, V19.B16, V17.B16 // <--                                  // orr	v17.16b, v19.16b, v17.16b
	VORR  V18.B16, V20.B16, V18.B16 // <--                                  // orr	v18.16b, v20.16b, v18.16b
	VEOR  V17.B16, V18.B16, V17.B16 // <--                                  // eor	v17.16b, v18.16b, v17.16b
	WORD  $0x3cef7a72               // FMOVQ (R19)(R15<<4), F18             // ldr	q18, [x19, x15, lsl #4]
	VAND  V18.B16, V17.B16, V17.B16 // <--                                  // and	v17.16b, v17.16b, v18.16b
	WORD  $0x6e30aa31               // VUMAXV V17.B16, V17                  // umaxv	b17, v17.16b
	FMOVS F17, R11                  // <--                                  // fmov	w11, s17
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BGE   LBB5_169                  // <--                                  // b.ge	.LBB5_169
	ADD   $1, R16, R16              // <--                                  // add	x16, x16, #1
	JMP   LBB5_37                   // <--                                  // b	.LBB5_37

LBB5_42:
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1

LBB5_43:
	AND  $60, R13, R8 // <--                                  // and	x8, x13, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_35      // <--                                  // b.eq	.LBB5_35

LBB5_44:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R13                   // <--                                  // clz	x13, x8
	ADD   R13>>2, R23, R8           // <--                                  // add	x8, x23, x13, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB5_43                   // <--                                  // b.hi	.LBB5_43
	WORD  $0x3ce86812               // FMOVQ (R0)(R8), F18                  // ldr	q18, [x0, x8]
	WORD  $0x3dc00053               // FMOVQ (R2), F19                      // ldr	q19, [x2]
	VADD  V4.B16, V18.B16, V20.B16  // <--                                  // add	v20.16b, v18.16b, v4.16b
	VADD  V4.B16, V19.B16, V21.B16  // <--                                  // add	v21.16b, v19.16b, v4.16b
	WORD  $0x6e3434b4               // VCMHI V20.B16, V5.B16, V20.B16       // cmhi	v20.16b, v5.16b, v20.16b
	WORD  $0x6e3534b5               // VCMHI V21.B16, V5.B16, V21.B16       // cmhi	v21.16b, v5.16b, v21.16b
	VAND  V6.B16, V20.B16, V20.B16  // <--                                  // and	v20.16b, v20.16b, v6.16b
	VAND  V6.B16, V21.B16, V21.B16  // <--                                  // and	v21.16b, v21.16b, v6.16b
	VORR  V18.B16, V20.B16, V18.B16 // <--                                  // orr	v18.16b, v20.16b, v18.16b
	VORR  V19.B16, V21.B16, V19.B16 // <--                                  // orr	v19.16b, v21.16b, v19.16b
	VEOR  V18.B16, V19.B16, V18.B16 // <--                                  // eor	v18.16b, v19.16b, v18.16b
	WORD  $0x3cef7a73               // FMOVQ (R19)(R15<<4), F19             // ldr	q19, [x19, x15, lsl #4]
	VAND  V19.B16, V18.B16, V18.B16 // <--                                  // and	v18.16b, v18.16b, v19.16b
	WORD  $0x6e30aa52               // VUMAXV V18.B16, V18                  // umaxv	b18, v18.16b
	FMOVS F18, R11                  // <--                                  // fmov	w11, s18
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BLT   LBB5_42                   // <--                                  // b.lt	.LBB5_42
	JMP   LBB5_169                  // <--                                  // b	.LBB5_169

LBB5_47:
	WORD  $0x0f0c8610   // VSHRN $4, V16.H8, V16.B8             // shrn	v16.8b, v16.8h, #4
	FMOVD F16, R24      // <--                                  // fmov	x24, d16
	CBZ   R24, LBB5_84  // <--                                  // cbz	x24, .LBB5_84
	ADD   $32, R23, R25 // <--                                  // add	x25, x23, #32
	JMP   LBB5_50       // <--                                  // b	.LBB5_50

LBB5_49:
	AND  $60, R26, R8 // <--                                  // and	x8, x26, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_84      // <--                                  // b.eq	.LBB5_84

LBB5_50:
	RBIT R24, R8      // <--                                  // rbit	x8, x24
	CLZ  R8, R26      // <--                                  // clz	x26, x8
	LSR  $2, R26, R30 // <--                                  // lsr	x30, x26, #2
	ADD  R30, R25, R8 // <--                                  // add	x8, x25, x30
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BHI  LBB5_49      // <--                                  // b.hi	.LBB5_49
	SUB  R8, R1, R14  // <--                                  // sub	x14, x1, x8
	CMP  $16, R14     // <--                                  // cmp	x14, #16
	BLT  LBB5_57      // <--                                  // b.lt	.LBB5_57
	MOVD ZR, R13      // <--                                  // mov	x13, xzr
	ADD  R30, R6, R19 // <--                                  // add	x19, x6, x30
	MOVD R15, R11     // <--                                  // mov	x11, x15

LBB5_53:
	WORD  $0x3ced6a70               // FMOVQ (R19)(R13), F16                // ldr	q16, [x19, x13]
	WORD  $0x3ced6851               // FMOVQ (R2)(R13), F17                 // ldr	q17, [x2, x13]
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	VADD  V4.B16, V17.B16, V19.B16  // <--                                  // add	v19.16b, v17.16b, v4.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VORR  V17.B16, V19.B16, V17.B16 // <--                                  // orr	v17.16b, v19.16b, v17.16b
	VEOR  V16.B16, V17.B16, V16.B16 // <--                                  // eor	v16.16b, v17.16b, v16.16b
	WORD  $0x6e30aa10               // VUMAXV V16.B16, V16                  // umaxv	b16, v16.16b
	FMOVS F16, R3                   // <--                                  // fmov	w3, s16
	CBNZW R3, LBB5_60               // <--                                  // cbnz	w3, .LBB5_60
	CMP   $32, R11                  // <--                                  // cmp	x11, #32
	SUB   $16, R11, R3              // <--                                  // sub	x3, x11, #16
	ADD   $16, R13, R13             // <--                                  // add	x13, x13, #16
	BLT   LBB5_56                   // <--                                  // b.lt	.LBB5_56
	CMP   $31, R14                  // <--                                  // cmp	x14, #31
	SUB   $16, R14, R14             // <--                                  // sub	x14, x14, #16
	MOVD  R3, R11                   // <--                                  // mov	x11, x3
	BGT   LBB5_53                   // <--                                  // b.gt	.LBB5_53

LBB5_56:
	ADD  R30, R6, R11                // <--                                  // add	x11, x6, x30
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	ADD  R13, R11, R14               // <--                                  // add	x14, x11, x13
	ADD  R13, R2, R11                // <--                                  // add	x11, x2, x13
	JMP  LBB5_58                     // <--                                  // b	.LBB5_58

LBB5_57:
	ADD  R8, R0, R14 // <--                                  // add	x14, x0, x8
	MOVD R15, R3     // <--                                  // mov	x3, x15
	MOVD R2, R11     // <--                                  // mov	x11, x2

LBB5_58:
	CMP   $1, R3                    // <--                                  // cmp	x3, #1
	BLT   LBB5_171                  // <--                                  // b.lt	.LBB5_171
	WORD  $0x3dc001d0               // FMOVQ (R14), F16                     // ldr	q16, [x14]
	WORD  $0x3dc00171               // FMOVQ (R11), F17                     // ldr	q17, [x11]
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	VADD  V4.B16, V17.B16, V19.B16  // <--                                  // add	v19.16b, v17.16b, v4.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VORR  V17.B16, V19.B16, V17.B16 // <--                                  // orr	v17.16b, v19.16b, v17.16b
	VEOR  V16.B16, V17.B16, V16.B16 // <--                                  // eor	v16.16b, v17.16b, v16.16b
	WORD  $0x3ce37a71               // FMOVQ (R19)(R3<<4), F17              // ldr	q17, [x19, x3, lsl #4]
	VAND  V17.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v17.16b
	WORD  $0x6e30aa10               // VUMAXV V16.B16, V16                  // umaxv	b16, v16.16b
	FMOVS F16, R11                  // <--                                  // fmov	w11, s16
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171

LBB5_60:
	CMP  R22, R16                    // <--                                  // cmp	x16, x22
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	BGE  LBB5_169                    // <--                                  // b.ge	.LBB5_169
	ADD  $1, R16, R16                // <--                                  // add	x16, x16, #1
	JMP  LBB5_49                     // <--                                  // b	.LBB5_49

LBB5_62:
	CBZ R24, LBB5_65 // <--                                  // cbz	x24, .LBB5_65

LBB5_63:
	RBIT R24, R8         // <--                                  // rbit	x8, x24
	CLZ  R8, R11         // <--                                  // clz	x11, x8
	ADD  R11>>2, R23, R8 // <--                                  // add	x8, x23, x11, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB5_171        // <--                                  // b.ls	.LBB5_171
	AND  $60, R11, R8    // <--                                  // and	x8, x11, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24    // <--                                  // ands	x24, x8, x24
	BNE  LBB5_63         // <--                                  // b.ne	.LBB5_63

LBB5_65:
	WORD  $0x0f0c8631   // VSHRN $4, V17.H8, V17.B8             // shrn	v17.8b, v17.8h, #4
	FMOVD F17, R11      // <--                                  // fmov	x11, d17
	CBZ   R11, LBB5_69  // <--                                  // cbz	x11, .LBB5_69
	ADD   $16, R23, R13 // <--                                  // add	x13, x23, #16

LBB5_67:
	RBIT R11, R8         // <--                                  // rbit	x8, x11
	CLZ  R8, R14         // <--                                  // clz	x14, x8
	ADD  R14>>2, R13, R8 // <--                                  // add	x8, x13, x14, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB5_171        // <--                                  // b.ls	.LBB5_171
	AND  $60, R14, R8    // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R11, R8, R11    // <--                                  // ands	x11, x8, x11
	BNE  LBB5_67         // <--                                  // b.ne	.LBB5_67

LBB5_69:
	WORD  $0x0f0c8610   // VSHRN $4, V16.H8, V16.B8             // shrn	v16.8b, v16.8h, #4
	FMOVD F16, R11      // <--                                  // fmov	x11, d16
	CBZ   R11, LBB5_73  // <--                                  // cbz	x11, .LBB5_73
	ADD   $32, R23, R13 // <--                                  // add	x13, x23, #32

LBB5_71:
	RBIT R11, R8         // <--                                  // rbit	x8, x11
	CLZ  R8, R14         // <--                                  // clz	x14, x8
	ADD  R14>>2, R13, R8 // <--                                  // add	x8, x13, x14, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB5_171        // <--                                  // b.ls	.LBB5_171
	AND  $60, R14, R8    // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R11, R8, R11    // <--                                  // ands	x11, x8, x11
	BNE  LBB5_71         // <--                                  // b.ne	.LBB5_71

LBB5_73:
	WORD  $0x0f0c84e7   // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R11       // <--                                  // fmov	x11, d7
	CBZ   R11, LBB5_106 // <--                                  // cbz	x11, .LBB5_106
	ADD   $48, R23, R13 // <--                                  // add	x13, x23, #48

LBB5_75:
	RBIT R11, R8         // <--                                  // rbit	x8, x11
	CLZ  R8, R14         // <--                                  // clz	x14, x8
	ADD  R14>>2, R13, R8 // <--                                  // add	x8, x13, x14, lsr #2
	CMP  R9, R8          // <--                                  // cmp	x8, x9
	BLS  LBB5_171        // <--                                  // b.ls	.LBB5_171
	AND  $60, R14, R8    // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8     // <--                                  // lsl	x8, x20, x8
	ANDS R11, R8, R11    // <--                                  // ands	x11, x8, x11
	BNE  LBB5_75         // <--                                  // b.ne	.LBB5_75
	JMP  LBB5_106        // <--                                  // b	.LBB5_106

LBB5_77:
	WORD  $0x0f0c8610   // VSHRN $4, V16.H8, V16.B8             // shrn	v16.8b, v16.8h, #4
	FMOVD F16, R24      // <--                                  // fmov	x24, d16
	CBZ   R24, LBB5_99  // <--                                  // cbz	x24, .LBB5_99
	ADD   $32, R23, R13 // <--                                  // add	x13, x23, #32
	JMP   LBB5_81       // <--                                  // b	.LBB5_81

LBB5_79:
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1

LBB5_80:
	AND  $60, R14, R8 // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_99      // <--                                  // b.eq	.LBB5_99

LBB5_81:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R14                   // <--                                  // clz	x14, x8
	ADD   R14>>2, R13, R8           // <--                                  // add	x8, x13, x14, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB5_80                   // <--                                  // b.hi	.LBB5_80
	WORD  $0x3ce86810               // FMOVQ (R0)(R8), F16                  // ldr	q16, [x0, x8]
	WORD  $0x3dc00051               // FMOVQ (R2), F17                      // ldr	q17, [x2]
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	VADD  V4.B16, V17.B16, V19.B16  // <--                                  // add	v19.16b, v17.16b, v4.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	WORD  $0x6e3334b3               // VCMHI V19.B16, V5.B16, V19.B16       // cmhi	v19.16b, v5.16b, v19.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VAND  V6.B16, V19.B16, V19.B16  // <--                                  // and	v19.16b, v19.16b, v6.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VORR  V17.B16, V19.B16, V17.B16 // <--                                  // orr	v17.16b, v19.16b, v17.16b
	VEOR  V16.B16, V17.B16, V16.B16 // <--                                  // eor	v16.16b, v17.16b, v16.16b
	WORD  $0x3cef7a71               // FMOVQ (R19)(R15<<4), F17             // ldr	q17, [x19, x15, lsl #4]
	VAND  V17.B16, V16.B16, V16.B16 // <--                                  // and	v16.16b, v16.16b, v17.16b
	WORD  $0x6e30aa10               // VUMAXV V16.B16, V16                  // umaxv	b16, v16.16b
	FMOVS F16, R11                  // <--                                  // fmov	w11, s16
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BLT   LBB5_79                   // <--                                  // b.lt	.LBB5_79
	JMP   LBB5_169                  // <--                                  // b	.LBB5_169

LBB5_84:
	WORD  $0x0f0c84e7   // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R24       // <--                                  // fmov	x24, d7
	CBZ   R24, LBB5_106 // <--                                  // cbz	x24, .LBB5_106
	ADD   $48, R23, R23 // <--                                  // add	x23, x23, #48
	JMP   LBB5_87       // <--                                  // b	.LBB5_87

LBB5_86:
	AND  $60, R25, R8 // <--                                  // and	x8, x25, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_106     // <--                                  // b.eq	.LBB5_106

LBB5_87:
	RBIT R24, R8      // <--                                  // rbit	x8, x24
	CLZ  R8, R25      // <--                                  // clz	x25, x8
	LSR  $2, R25, R26 // <--                                  // lsr	x26, x25, #2
	ADD  R26, R23, R8 // <--                                  // add	x8, x23, x26
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BHI  LBB5_86      // <--                                  // b.hi	.LBB5_86
	SUB  R8, R1, R14  // <--                                  // sub	x14, x1, x8
	CMP  $16, R14     // <--                                  // cmp	x14, #16
	BLT  LBB5_94      // <--                                  // b.lt	.LBB5_94
	MOVD ZR, R13      // <--                                  // mov	x13, xzr
	ADD  R26, R7, R19 // <--                                  // add	x19, x7, x26
	MOVD R15, R11     // <--                                  // mov	x11, x15

LBB5_90:
	WORD  $0x3ced6a67               // FMOVQ (R19)(R13), F7                 // ldr	q7, [x19, x13]
	WORD  $0x3ced6850               // FMOVQ (R2)(R13), F16                 // ldr	q16, [x2, x13]
	VADD  V4.B16, V7.B16, V17.B16   // <--                                  // add	v17.16b, v7.16b, v4.16b
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V7.B16, V17.B16, V7.B16   // <--                                  // orr	v7.16b, v17.16b, v7.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VEOR  V7.B16, V16.B16, V7.B16   // <--                                  // eor	v7.16b, v16.16b, v7.16b
	WORD  $0x6e30a8e7               // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R3                    // <--                                  // fmov	w3, s7
	CBNZW R3, LBB5_97               // <--                                  // cbnz	w3, .LBB5_97
	CMP   $32, R11                  // <--                                  // cmp	x11, #32
	SUB   $16, R11, R3              // <--                                  // sub	x3, x11, #16
	ADD   $16, R13, R13             // <--                                  // add	x13, x13, #16
	BLT   LBB5_93                   // <--                                  // b.lt	.LBB5_93
	CMP   $31, R14                  // <--                                  // cmp	x14, #31
	SUB   $16, R14, R14             // <--                                  // sub	x14, x14, #16
	MOVD  R3, R11                   // <--                                  // mov	x11, x3
	BGT   LBB5_90                   // <--                                  // b.gt	.LBB5_90

LBB5_93:
	ADD  R26, R7, R11                // <--                                  // add	x11, x7, x26
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	ADD  R13, R11, R14               // <--                                  // add	x14, x11, x13
	ADD  R13, R2, R11                // <--                                  // add	x11, x2, x13
	JMP  LBB5_95                     // <--                                  // b	.LBB5_95

LBB5_94:
	ADD  R8, R0, R14 // <--                                  // add	x14, x0, x8
	MOVD R15, R3     // <--                                  // mov	x3, x15
	MOVD R2, R11     // <--                                  // mov	x11, x2

LBB5_95:
	CMP   $1, R3                    // <--                                  // cmp	x3, #1
	BLT   LBB5_171                  // <--                                  // b.lt	.LBB5_171
	WORD  $0x3dc001c7               // FMOVQ (R14), F7                      // ldr	q7, [x14]
	WORD  $0x3dc00170               // FMOVQ (R11), F16                     // ldr	q16, [x11]
	VADD  V4.B16, V7.B16, V17.B16   // <--                                  // add	v17.16b, v7.16b, v4.16b
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V7.B16, V17.B16, V7.B16   // <--                                  // orr	v7.16b, v17.16b, v7.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VEOR  V7.B16, V16.B16, V7.B16   // <--                                  // eor	v7.16b, v16.16b, v7.16b
	WORD  $0x3ce37a70               // FMOVQ (R19)(R3<<4), F16              // ldr	q16, [x19, x3, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16   // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7               // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                   // <--                                  // fmov	w11, s7
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171

LBB5_97:
	CMP  R22, R16                    // <--                                  // cmp	x16, x22
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	BGE  LBB5_169                    // <--                                  // b.ge	.LBB5_169
	ADD  $1, R16, R16                // <--                                  // add	x16, x16, #1
	JMP  LBB5_86                     // <--                                  // b	.LBB5_86

LBB5_99:
	WORD  $0x0f0c84e7   // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R24       // <--                                  // fmov	x24, d7
	CBZ   R24, LBB5_106 // <--                                  // cbz	x24, .LBB5_106
	ADD   $48, R23, R13 // <--                                  // add	x13, x23, #48
	JMP   LBB5_103      // <--                                  // b	.LBB5_103

LBB5_101:
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1

LBB5_102:
	AND  $60, R14, R8 // <--                                  // and	x8, x14, #0x3c
	LSL  R8, R20, R8  // <--                                  // lsl	x8, x20, x8
	ANDS R24, R8, R24 // <--                                  // ands	x24, x8, x24
	BEQ  LBB5_106     // <--                                  // b.eq	.LBB5_106

LBB5_103:
	RBIT  R24, R8                   // <--                                  // rbit	x8, x24
	CLZ   R8, R14                   // <--                                  // clz	x14, x8
	ADD   R14>>2, R13, R8           // <--                                  // add	x8, x13, x14, lsr #2
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BHI   LBB5_102                  // <--                                  // b.hi	.LBB5_102
	WORD  $0x3ce86807               // FMOVQ (R0)(R8), F7                   // ldr	q7, [x0, x8]
	WORD  $0x3dc00050               // FMOVQ (R2), F16                      // ldr	q16, [x2]
	VADD  V4.B16, V7.B16, V17.B16   // <--                                  // add	v17.16b, v7.16b, v4.16b
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V7.B16, V17.B16, V7.B16   // <--                                  // orr	v7.16b, v17.16b, v7.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VEOR  V7.B16, V16.B16, V7.B16   // <--                                  // eor	v7.16b, v16.16b, v7.16b
	WORD  $0x3cef7a70               // FMOVQ (R19)(R15<<4), F16             // ldr	q16, [x19, x15, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16   // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7               // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                   // <--                                  // fmov	w11, s7
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171
	CMP   R22, R16                  // <--                                  // cmp	x16, x22
	BLT   LBB5_101                  // <--                                  // b.lt	.LBB5_101
	JMP   LBB5_169                  // <--                                  // b	.LBB5_169

LBB5_106:
	SUB  $64, R21, R22 // <--                                  // sub	x22, x21, #64
	ADD  $64, R17, R17 // <--                                  // add	x17, x17, #64
	ADD  $64, R4, R4   // <--                                  // add	x4, x4, #64
	CMP  $127, R21     // <--                                  // cmp	x21, #127
	ADD  $64, R6, R6   // <--                                  // add	x6, x6, #64
	ADD  $64, R7, R7   // <--                                  // add	x7, x7, #64
	MOVD R22, R21      // <--                                  // mov	x21, x22
	BGT  LBB5_5        // <--                                  // b.gt	.LBB5_5
	JMP  LBB5_109      // <--                                  // b	.LBB5_109

LBB5_107:
	MOVD ZR, R0         // <--                                  // mov	x0, xzr
	MOVD R0, ret+48(FP) // <--
	RET                 // <--                                  // ret

LBB5_108:
	MOVD R21, R22 // <--                                  // mov	x22, x21

LBB5_109:
	CMP  $16, R15                    // <--                                  // cmp	x15, #16
	BLT  LBB5_112                    // <--                                  // b.lt	.LBB5_112
	CMP  $16, R22                    // <--                                  // cmp	x22, #16
	BLT  LBB5_143                    // <--                                  // b.lt	.LBB5_143
	WORD $0x4f05e7e4                 // VMOVI $191, V4.B16                   // movi	v4.16b, #191
	WORD $0x4f00e745                 // VMOVI $26, V5.B16                    // movi	v5.16b, #26
	MOVD 24(RSP), R8                 // <--                                  // ldr	x8, [sp, #24]
	WORD $0x4f01e406                 // VMOVI $32, V6.B16                    // movi	v6.16b, #32
	MOVD $-16, R7                    // <--                                  // mov	x7, #-16
	MOVD $tail_mask_table<>(SB), R19 // <--                                  // adrp	x19, tail_mask_table
	NOP                              // (skipped)                            // add	x19, x19, :lo12:tail_mask_table
	SUB  R8, R17, R8                 // <--                                  // sub	x8, x17, x8
	ADD  R8, R0, R6                  // <--                                  // add	x6, x0, x8
	JMP  LBB5_116                    // <--                                  // b	.LBB5_116

LBB5_112:
	CMP  $0, R15                    // <--                                  // cmp	x15, #0
	BLE  LBB5_141                   // <--                                  // b.le	.LBB5_141
	CMP  $16, R22                   // <--                                  // cmp	x22, #16
	BLT  LBB5_150                   // <--                                  // b.lt	.LBB5_150
	WORD $0x4f05e7e4                // VMOVI $191, V4.B16                   // movi	v4.16b, #191
	WORD $0x4f00e745                // VMOVI $26, V5.B16                    // movi	v5.16b, #26
	MOVD $-16, R6                   // <--                                  // mov	x6, #-16
	WORD $0x4f01e406                // VMOVI $32, V6.B16                    // movi	v6.16b, #32
	MOVD $tail_mask_table<>(SB), R7 // <--                                  // adrp	x7, tail_mask_table
	NOP                             // (skipped)                            // add	x7, x7, :lo12:tail_mask_table
	JMP  LBB5_133                   // <--                                  // b	.LBB5_133

LBB5_115:
	SUB  $16, R22, R4  // <--                                  // sub	x4, x22, #16
	CMP  $31, R22      // <--                                  // cmp	x22, #31
	ADD  $16, R17, R17 // <--                                  // add	x17, x17, #16
	ADD  $16, R6, R6   // <--                                  // add	x6, x6, #16
	MOVD R4, R22       // <--                                  // mov	x22, x4
	BLE  LBB5_151      // <--                                  // b.le	.LBB5_151

LBB5_116:
	WORD  $0x3dc00227              // FMOVQ (R17), F7                      // ldr	q7, [x17]
	WORD  $0x3ce56a30              // FMOVQ (R17)(R5), F16                 // ldr	q16, [x17, x5]
	VORR  V0.B16, V7.B16, V7.B16   // <--                                  // orr	v7.16b, v7.16b, v0.16b
	VORR  V1.B16, V16.B16, V16.B16 // <--                                  // orr	v16.16b, v16.16b, v1.16b
	VCMEQ V2.B16, V7.B16, V7.B16   // <--                                  // cmeq	v7.16b, v7.16b, v2.16b
	VCMEQ V3.B16, V16.B16, V16.B16 // <--                                  // cmeq	v16.16b, v16.16b, v3.16b
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x0f0c84e7              // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R4                   // <--                                  // fmov	x4, d7
	CBZ   R4, LBB5_115             // <--                                  // cbz	x4, .LBB5_115
	MOVD  8(RSP), R8               // <--                                  // ldr	x8, [sp, #8]
	SUB   R22, R8, R8              // <--                                  // sub	x8, x8, x22
	ASR   $3, R8, R8               // <--                                  // asr	x8, x8, #3
	ADD   $32, R8, R20             // <--                                  // add	x20, x8, #32
	MOVD  24(RSP), R8              // <--                                  // ldr	x8, [sp, #24]
	SUB   R8, R17, R21             // <--                                  // sub	x21, x17, x8
	JMP   LBB5_119                 // <--                                  // b	.LBB5_119

LBB5_118:
	AND  $60, R23, R8 // <--                                  // and	x8, x23, #0x3c
	LSL  R8, R7, R8   // <--                                  // lsl	x8, x7, x8
	ANDS R4, R8, R4   // <--                                  // ands	x4, x8, x4
	BEQ  LBB5_115     // <--                                  // b.eq	.LBB5_115

LBB5_119:
	RBIT R4, R8       // <--                                  // rbit	x8, x4
	CLZ  R8, R23      // <--                                  // clz	x23, x8
	LSR  $2, R23, R24 // <--                                  // lsr	x24, x23, #2
	ADDS R24, R21, R8 // <--                                  // adds	x8, x21, x24
	BMI  LBB5_118     // <--                                  // b.mi	.LBB5_118
	CMP  R9, R8       // <--                                  // cmp	x8, x9
	BGT  LBB5_118     // <--                                  // b.gt	.LBB5_118
	SUB  R8, R1, R13  // <--                                  // sub	x13, x1, x8
	CMP  $16, R13     // <--                                  // cmp	x13, #16
	BLT  LBB5_127     // <--                                  // b.lt	.LBB5_127
	MOVD ZR, R25      // <--                                  // mov	x25, xzr
	ADD  R24, R6, R14 // <--                                  // add	x14, x6, x24
	MOVD R15, R3      // <--                                  // mov	x3, x15

LBB5_123:
	WORD  $0x3cf969c7               // FMOVQ (R14)(R25), F7                 // ldr	q7, [x14, x25]
	WORD  $0x3cf96850               // FMOVQ (R2)(R25), F16                 // ldr	q16, [x2, x25]
	VADD  V4.B16, V7.B16, V17.B16   // <--                                  // add	v17.16b, v7.16b, v4.16b
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V7.B16, V17.B16, V7.B16   // <--                                  // orr	v7.16b, v17.16b, v7.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VEOR  V7.B16, V16.B16, V7.B16   // <--                                  // eor	v7.16b, v16.16b, v7.16b
	WORD  $0x6e30a8e7               // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                   // <--                                  // fmov	w11, s7
	CBNZW R11, LBB5_130             // <--                                  // cbnz	w11, .LBB5_130
	CMP   $32, R3                   // <--                                  // cmp	x3, #32
	SUB   $16, R3, R26              // <--                                  // sub	x26, x3, #16
	ADD   $16, R25, R25             // <--                                  // add	x25, x25, #16
	BLT   LBB5_126                  // <--                                  // b.lt	.LBB5_126
	CMP   $31, R13                  // <--                                  // cmp	x13, #31
	SUB   $16, R13, R13             // <--                                  // sub	x13, x13, #16
	MOVD  R26, R3                   // <--                                  // mov	x3, x26
	BGT   LBB5_123                  // <--                                  // b.gt	.LBB5_123

LBB5_126:
	ADD R24, R6, R11  // <--                                  // add	x11, x6, x24
	ADD R25, R11, R13 // <--                                  // add	x13, x11, x25
	ADD R25, R2, R11  // <--                                  // add	x11, x2, x25
	JMP LBB5_128      // <--                                  // b	.LBB5_128

LBB5_127:
	ADD  R8, R0, R13 // <--                                  // add	x13, x0, x8
	MOVD R15, R26    // <--                                  // mov	x26, x15
	MOVD R2, R11     // <--                                  // mov	x11, x2

LBB5_128:
	CMP   $1, R26                   // <--                                  // cmp	x26, #1
	BLT   LBB5_171                  // <--                                  // b.lt	.LBB5_171
	WORD  $0x3dc001a7               // FMOVQ (R13), F7                      // ldr	q7, [x13]
	WORD  $0x3dc00170               // FMOVQ (R11), F16                     // ldr	q16, [x11]
	VADD  V4.B16, V7.B16, V17.B16   // <--                                  // add	v17.16b, v7.16b, v4.16b
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V7.B16, V17.B16, V7.B16   // <--                                  // orr	v7.16b, v17.16b, v7.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VEOR  V7.B16, V16.B16, V7.B16   // <--                                  // eor	v7.16b, v16.16b, v7.16b
	WORD  $0x3cfa7a70               // FMOVQ (R19)(R26<<4), F16             // ldr	q16, [x19, x26, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16   // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7               // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                   // <--                                  // fmov	w11, s7
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171

LBB5_130:
	CMP R20, R16     // <--                                  // cmp	x16, x20
	BGE LBB5_169     // <--                                  // b.ge	.LBB5_169
	ADD $1, R16, R16 // <--                                  // add	x16, x16, #1
	JMP LBB5_118     // <--                                  // b	.LBB5_118

LBB5_132:
	SUB  $16, R22, R4  // <--                                  // sub	x4, x22, #16
	CMP  $31, R22      // <--                                  // cmp	x22, #31
	ADD  $16, R17, R17 // <--                                  // add	x17, x17, #16
	MOVD R4, R22       // <--                                  // mov	x22, x4
	BLE  LBB5_151      // <--                                  // b.le	.LBB5_151

LBB5_133:
	WORD  $0x3dc00227              // FMOVQ (R17), F7                      // ldr	q7, [x17]
	WORD  $0x3ce56a30              // FMOVQ (R17)(R5), F16                 // ldr	q16, [x17, x5]
	VORR  V0.B16, V7.B16, V7.B16   // <--                                  // orr	v7.16b, v7.16b, v0.16b
	VORR  V1.B16, V16.B16, V16.B16 // <--                                  // orr	v16.16b, v16.16b, v1.16b
	VCMEQ V2.B16, V7.B16, V7.B16   // <--                                  // cmeq	v7.16b, v7.16b, v2.16b
	VCMEQ V3.B16, V16.B16, V16.B16 // <--                                  // cmeq	v16.16b, v16.16b, v3.16b
	VAND  V16.B16, V7.B16, V7.B16  // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x0f0c84e7              // VSHRN $4, V7.H8, V7.B8               // shrn	v7.8b, v7.8h, #4
	FMOVD F7, R4                   // <--                                  // fmov	x4, d7
	CBZ   R4, LBB5_132             // <--                                  // cbz	x4, .LBB5_132
	MOVD  8(RSP), R8               // <--                                  // ldr	x8, [sp, #8]
	SUB   R22, R8, R8              // <--                                  // sub	x8, x8, x22
	ASR   $3, R8, R8               // <--                                  // asr	x8, x8, #3
	ADD   $32, R8, R19             // <--                                  // add	x19, x8, #32
	MOVD  24(RSP), R8              // <--                                  // ldr	x8, [sp, #24]
	SUB   R8, R17, R20             // <--                                  // sub	x20, x17, x8
	JMP   LBB5_136                 // <--                                  // b	.LBB5_136

LBB5_135:
	AND  $60, R13, R8 // <--                                  // and	x8, x13, #0x3c
	LSL  R8, R6, R8   // <--                                  // lsl	x8, x6, x8
	ANDS R4, R8, R4   // <--                                  // ands	x4, x8, x4
	BEQ  LBB5_132     // <--                                  // b.eq	.LBB5_132

LBB5_136:
	RBIT  R4, R8                    // <--                                  // rbit	x8, x4
	CLZ   R8, R13                   // <--                                  // clz	x13, x8
	ADDS  R13>>2, R20, R8           // <--                                  // adds	x8, x20, x13, lsr #2
	BMI   LBB5_135                  // <--                                  // b.mi	.LBB5_135
	CMP   R9, R8                    // <--                                  // cmp	x8, x9
	BGT   LBB5_135                  // <--                                  // b.gt	.LBB5_135
	WORD  $0x3ce86807               // FMOVQ (R0)(R8), F7                   // ldr	q7, [x0, x8]
	WORD  $0x3dc00050               // FMOVQ (R2), F16                      // ldr	q16, [x2]
	VADD  V4.B16, V7.B16, V17.B16   // <--                                  // add	v17.16b, v7.16b, v4.16b
	VADD  V4.B16, V16.B16, V18.B16  // <--                                  // add	v18.16b, v16.16b, v4.16b
	WORD  $0x6e3134b1               // VCMHI V17.B16, V5.B16, V17.B16       // cmhi	v17.16b, v5.16b, v17.16b
	WORD  $0x6e3234b2               // VCMHI V18.B16, V5.B16, V18.B16       // cmhi	v18.16b, v5.16b, v18.16b
	VAND  V6.B16, V17.B16, V17.B16  // <--                                  // and	v17.16b, v17.16b, v6.16b
	VAND  V6.B16, V18.B16, V18.B16  // <--                                  // and	v18.16b, v18.16b, v6.16b
	VORR  V7.B16, V17.B16, V7.B16   // <--                                  // orr	v7.16b, v17.16b, v7.16b
	VORR  V16.B16, V18.B16, V16.B16 // <--                                  // orr	v16.16b, v18.16b, v16.16b
	VEOR  V7.B16, V16.B16, V7.B16   // <--                                  // eor	v7.16b, v16.16b, v7.16b
	WORD  $0x3cef78f0               // FMOVQ (R7)(R15<<4), F16              // ldr	q16, [x7, x15, lsl #4]
	VAND  V16.B16, V7.B16, V7.B16   // <--                                  // and	v7.16b, v7.16b, v16.16b
	WORD  $0x6e30a8e7               // VUMAXV V7.B16, V7                    // umaxv	b7, v7.16b
	FMOVS F7, R11                   // <--                                  // fmov	w11, s7
	CBZW  R11, LBB5_171             // <--                                  // cbz	w11, .LBB5_171
	CMP   R19, R16                  // <--                                  // cmp	x16, x19
	BGE   LBB5_169                  // <--                                  // b.ge	.LBB5_169
	ADD   $1, R16, R16              // <--                                  // add	x16, x16, #1
	JMP   LBB5_135                  // <--                                  // b	.LBB5_135

LBB5_141:
	CMP  $16, R22 // <--                                  // cmp	x22, #16
	BLT  LBB5_143 // <--                                  // b.lt	.LBB5_143
	MOVD $-16, R6 // <--                                  // mov	x6, #-16
	JMP  LBB5_145 // <--                                  // b	.LBB5_145

LBB5_143:
	MOVD R22, R4  // <--                                  // mov	x4, x22
	CMP  $1, R22  // <--                                  // cmp	x22, #1
	BGE  LBB5_152 // <--                                  // b.ge	.LBB5_152
	JMP  LBB5_170 // <--                                  // b	.LBB5_170

LBB5_144:
	SUB  $16, R22, R4  // <--                                  // sub	x4, x22, #16
	CMP  $31, R22      // <--                                  // cmp	x22, #31
	ADD  $16, R17, R17 // <--                                  // add	x17, x17, #16
	MOVD R4, R22       // <--                                  // mov	x22, x4
	BLE  LBB5_151      // <--                                  // b.le	.LBB5_151

LBB5_145:
	WORD  $0x3dc00224            // FMOVQ (R17), F4                      // ldr	q4, [x17]
	WORD  $0x3ce56a25            // FMOVQ (R17)(R5), F5                  // ldr	q5, [x17, x5]
	VORR  V0.B16, V4.B16, V4.B16 // <--                                  // orr	v4.16b, v4.16b, v0.16b
	VORR  V1.B16, V5.B16, V5.B16 // <--                                  // orr	v5.16b, v5.16b, v1.16b
	VCMEQ V2.B16, V4.B16, V4.B16 // <--                                  // cmeq	v4.16b, v4.16b, v2.16b
	VCMEQ V3.B16, V5.B16, V5.B16 // <--                                  // cmeq	v5.16b, v5.16b, v3.16b
	VAND  V5.B16, V4.B16, V4.B16 // <--                                  // and	v4.16b, v4.16b, v5.16b
	WORD  $0x0f0c8484            // VSHRN $4, V4.H8, V4.B8               // shrn	v4.8b, v4.8h, #4
	FMOVD F4, R13                // <--                                  // fmov	x13, d4
	CBZ   R13, LBB5_144          // <--                                  // cbz	x13, .LBB5_144
	MOVD  24(RSP), R11           // <--                                  // ldr	x11, [sp, #24]
	RBIT  R13, R8                // <--                                  // rbit	x8, x13
	SUB   R11, R17, R14          // <--                                  // sub	x14, x17, x11
	CLZ   R8, R11                // <--                                  // clz	x11, x8
	ADDS  R11>>2, R14, R8        // <--                                  // adds	x8, x14, x11, lsr #2
	BMI   LBB5_148               // <--                                  // b.mi	.LBB5_148

LBB5_147:
	CMP R9, R8   // <--                                  // cmp	x8, x9
	BLE LBB5_171 // <--                                  // b.le	.LBB5_171

LBB5_148:
	AND  $60, R11, R8    // <--                                  // and	x8, x11, #0x3c
	LSL  R8, R6, R8      // <--                                  // lsl	x8, x6, x8
	ANDS R13, R8, R13    // <--                                  // ands	x13, x8, x13
	BEQ  LBB5_144        // <--                                  // b.eq	.LBB5_144
	RBIT R13, R8         // <--                                  // rbit	x8, x13
	CLZ  R8, R11         // <--                                  // clz	x11, x8
	ADDS R11>>2, R14, R8 // <--                                  // adds	x8, x14, x11, lsr #2
	BPL  LBB5_147        // <--                                  // b.pl	.LBB5_147
	JMP  LBB5_148        // <--                                  // b	.LBB5_148

LBB5_150:
	MOVD R22, R4 // <--                                  // mov	x4, x22

LBB5_151:
	CMP $1, R4   // <--                                  // cmp	x4, #1
	BLT LBB5_170 // <--                                  // b.lt	.LBB5_170

LBB5_152:
	WORD $0x4f05e7e0                // VMOVI $191, V0.B16                   // movi	v0.16b, #191
	WORD $0x4f00e741                // VMOVI $26, V1.B16                    // movi	v1.16b, #26
	MOVD 24(RSP), R13               // <--                                  // ldr	x13, [sp, #24]
	WORD $0x4f01e402                // VMOVI $32, V2.B16                    // movi	v2.16b, #32
	MOVD $tail_mask_table<>(SB), R6 // <--                                  // adrp	x6, tail_mask_table
	NOP                             // (skipped)                            // add	x6, x6, :lo12:tail_mask_table
	JMP  LBB5_154                   // <--                                  // b	.LBB5_154

LBB5_153:
	SUBS $1, R4, R4   // <--                                  // subs	x4, x4, #1
	ADD  $1, R17, R17 // <--                                  // add	x17, x17, #1
	BLE  LBB5_170     // <--                                  // b.le	.LBB5_170

LBB5_154:
	WORD  $0x39400228       // MOVBU (R17), R8                      // ldrb	w8, [x17]
	ORRW  R12, R8, R8       // <--                                  // orr	w8, w8, w12
	CMPW  R10.UXTB, R8      // <--                                  // cmp	w8, w10, uxtb
	BNE   LBB5_153          // <--                                  // b.ne	.LBB5_153
	WORD  $0x38656a28       // MOVBU (R17)(R5), R8                  // ldrb	w8, [x17, x5]
	MOVWU (RSP), R11        // <--                                  // ldr	w11, [sp]
	ORRW  R11, R8, R8       // <--                                  // orr	w8, w8, w11
	MOVWU 4(RSP), R11       // <--                                  // ldr	w11, [sp, #4]
	CMPW  R11.UXTB, R8      // <--                                  // cmp	w8, w11, uxtb
	BNE   LBB5_153          // <--                                  // b.ne	.LBB5_153
	SUB   R13, R17, R8      // <--                                  // sub	x8, x17, x13
	TBNZ  $63, R8, LBB5_153 // <--                                  // tbnz	x8, #63, .LBB5_153
	CMP   R9, R8            // <--                                  // cmp	x8, x9
	BGT   LBB5_153          // <--                                  // b.gt	.LBB5_153
	CMP   $16, R15          // <--                                  // cmp	x15, #16
	ADD   R8, R0, R7        // <--                                  // add	x7, x0, x8
	BLT   LBB5_164          // <--                                  // b.lt	.LBB5_164
	SUB   R8, R1, R13       // <--                                  // sub	x13, x1, x8
	CMP   $16, R13          // <--                                  // cmp	x13, #16
	BLT   LBB5_164          // <--                                  // b.lt	.LBB5_164
	MOVD  R2, R19           // <--                                  // mov	x19, x2
	MOVD  R15, R3           // <--                                  // mov	x3, x15

LBB5_161:
	WORD  $0x3cc104e3            // FMOVQ.P 16(R7), F3                   // ldr	q3, [x7], #16
	WORD  $0x3cc10664            // FMOVQ.P 16(R19), F4                  // ldr	q4, [x19], #16
	VADD  V0.B16, V3.B16, V5.B16 // <--                                  // add	v5.16b, v3.16b, v0.16b
	VADD  V0.B16, V4.B16, V6.B16 // <--                                  // add	v6.16b, v4.16b, v0.16b
	WORD  $0x6e253425            // VCMHI V5.B16, V1.B16, V5.B16         // cmhi	v5.16b, v1.16b, v5.16b
	WORD  $0x6e263426            // VCMHI V6.B16, V1.B16, V6.B16         // cmhi	v6.16b, v1.16b, v6.16b
	VAND  V2.B16, V5.B16, V5.B16 // <--                                  // and	v5.16b, v5.16b, v2.16b
	VAND  V2.B16, V6.B16, V6.B16 // <--                                  // and	v6.16b, v6.16b, v2.16b
	VORR  V3.B16, V5.B16, V3.B16 // <--                                  // orr	v3.16b, v5.16b, v3.16b
	VORR  V4.B16, V6.B16, V4.B16 // <--                                  // orr	v4.16b, v6.16b, v4.16b
	VEOR  V3.B16, V4.B16, V3.B16 // <--                                  // eor	v3.16b, v4.16b, v3.16b
	WORD  $0x6e30a863            // VUMAXV V3.B16, V3                    // umaxv	b3, v3.16b
	FMOVS F3, R11                // <--                                  // fmov	w11, s3
	CBNZW R11, LBB5_167          // <--                                  // cbnz	w11, .LBB5_167
	CMP   $32, R3                // <--                                  // cmp	x3, #32
	SUB   $16, R3, R14           // <--                                  // sub	x14, x3, #16
	BLT   LBB5_165               // <--                                  // b.lt	.LBB5_165
	CMP   $31, R13               // <--                                  // cmp	x13, #31
	SUB   $16, R13, R13          // <--                                  // sub	x13, x13, #16
	MOVD  R14, R3                // <--                                  // mov	x3, x14
	BGT   LBB5_161               // <--                                  // b.gt	.LBB5_161
	JMP   LBB5_165               // <--                                  // b	.LBB5_165

LBB5_164:
	MOVD R15, R14 // <--                                  // mov	x14, x15
	MOVD R2, R19  // <--                                  // mov	x19, x2

LBB5_165:
	CMP   $1, R14                // <--                                  // cmp	x14, #1
	BLT   LBB5_171               // <--                                  // b.lt	.LBB5_171
	WORD  $0x3dc000e3            // FMOVQ (R7), F3                       // ldr	q3, [x7]
	WORD  $0x3dc00264            // FMOVQ (R19), F4                      // ldr	q4, [x19]
	VADD  V0.B16, V3.B16, V5.B16 // <--                                  // add	v5.16b, v3.16b, v0.16b
	VADD  V0.B16, V4.B16, V6.B16 // <--                                  // add	v6.16b, v4.16b, v0.16b
	WORD  $0x6e253425            // VCMHI V5.B16, V1.B16, V5.B16         // cmhi	v5.16b, v1.16b, v5.16b
	WORD  $0x6e263426            // VCMHI V6.B16, V1.B16, V6.B16         // cmhi	v6.16b, v1.16b, v6.16b
	VAND  V2.B16, V5.B16, V5.B16 // <--                                  // and	v5.16b, v5.16b, v2.16b
	VAND  V2.B16, V6.B16, V6.B16 // <--                                  // and	v6.16b, v6.16b, v2.16b
	VORR  V3.B16, V5.B16, V3.B16 // <--                                  // orr	v3.16b, v5.16b, v3.16b
	VORR  V4.B16, V6.B16, V4.B16 // <--                                  // orr	v4.16b, v6.16b, v4.16b
	VEOR  V3.B16, V4.B16, V3.B16 // <--                                  // eor	v3.16b, v4.16b, v3.16b
	WORD  $0x3cee78c4            // FMOVQ (R6)(R14<<4), F4               // ldr	q4, [x6, x14, lsl #4]
	VAND  V4.B16, V3.B16, V3.B16 // <--                                  // and	v3.16b, v3.16b, v4.16b
	WORD  $0x6e30a863            // VUMAXV V3.B16, V3                    // umaxv	b3, v3.16b
	FMOVS F3, R11                // <--                                  // fmov	w11, s3
	CBZW  R11, LBB5_171          // <--                                  // cbz	w11, .LBB5_171

LBB5_167:
	MOVD 8(RSP), R11   // <--                                  // ldr	x11, [sp, #8]
	SUB  R4, R11, R11  // <--                                  // sub	x11, x11, x4
	ASR  $3, R11, R11  // <--                                  // asr	x11, x11, #3
	ADD  $32, R11, R11 // <--                                  // add	x11, x11, #32
	CMP  R11, R16      // <--                                  // cmp	x16, x11
	BGE  LBB5_169      // <--                                  // b.ge	.LBB5_169
	MOVD 24(RSP), R13  // <--                                  // ldr	x13, [sp, #24]
	ADD  $1, R16, R16  // <--                                  // add	x16, x16, #1
	JMP  LBB5_153      // <--                                  // b	.LBB5_153

LBB5_169:
	MOVD $-9223372036854775807, R9 // <--                                  // mov	x9, #-9223372036854775807
	ADD  R9, R8, R8                // <--                                  // add	x8, x8, x9
	JMP  LBB5_171                  // <--                                  // b	.LBB5_171

LBB5_170:
	MOVD $-1, R8 // <--                                  // mov	x8, #-1

LBB5_171:
	NOP                 // (skipped)                            // ldp	x20, x19, [sp, #80]
	MOVD 16(RSP), R30   // <--                                  // ldr	x30, [sp, #16]
	NOP                 // (skipped)                            // ldp	x22, x21, [sp, #64]
	NOP                 // (skipped)                            // ldp	x24, x23, [sp, #48]
	NOP                 // (skipped)                            // ldp	x26, x25, [sp, #32]
	NOP                 // (skipped)                            // add	sp, sp, #96
	MOVD R8, R0         // <--                                  // mov	x0, x8
	MOVD R0, ret+48(FP) // <--
	RET                 // <--                                  // ret
