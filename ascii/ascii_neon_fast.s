//go:build !noasm && arm64

// Hand-optimized NEON implementation for IndexFoldNeedle
// Key optimization: mask-based case folding (AND + VCMEQ) instead of dual compare
// 
// Original gocc uses: (rare1 & mask1) == rare1U
//   - mask1 = 0xDF for letters (clears case bit), 0xFF for non-letters
//   - rare1U = uppercase variant
// This is ONE compare per vector vs TWO (upper + lower + OR)

#include "textflag.h"

// Magic constant for syndrome: 0x40100401
DATA magic_const<>+0x00(SB)/8, $0x4010040140100401
DATA magic_const<>+0x08(SB)/8, $0x4010040140100401
GLOBL magic_const<>(SB), (RODATA|NOPTR), $16

// func indexFoldNeedleNeonFast(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleNeonFast(SB), NOSPLIT, $0-72
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVBU rare1+16(FP), R2
	MOVD  off1+24(FP), R3
	MOVBU rare2+32(FP), R4
	MOVD  off2+40(FP), R5
	MOVD  norm_needle+48(FP), R6
	MOVD  needle_len+56(FP), R7

	// searchLen = haystackLen - needleLen
	SUBS  R7, R1, R9
	BLT   not_found
	CBZ   R7, found_zero

	// Compute mask and uppercase for rare1
	// is_letter = ((rare1 | 0x20) - 'a') < 26
	ORRW  $0x20, R2, R10
	SUBW  $97, R10, R10
	CMPW  $26, R10
	BCS   r1_not_letter
	// rare1 is letter: mask1 = 0xDF, rare1U = rare1 & 0xDF
	MOVW  $0xDF, R10               // mask1
	ANDW  $0xDF, R2, R11           // rare1U (uppercase)
	B     r1_done
r1_not_letter:
	MOVW  $0xFF, R10               // mask1 (no change)
	MOVW  R2, R11                  // rare1U = rare1
r1_done:

	// Compute mask and uppercase for rare2
	ORRW  $0x20, R4, R12
	SUBW  $97, R12, R12
	CMPW  $26, R12
	BCS   r2_not_letter
	MOVW  $0xDF, R12               // mask2
	ANDW  $0xDF, R4, R13           // rare2U
	B     r2_done
r2_not_letter:
	MOVW  $0xFF, R12
	MOVW  R4, R13
r2_done:

	// Create NEON vectors
	VDUP  R11, V0.B16              // rare1U
	VDUP  R10, V1.B16              // mask1
	VDUP  R13, V2.B16              // rare2U
	VDUP  R12, V3.B16              // mask2

	// Load magic constant
	MOVD  $magic_const<>(SB), R14
	VLD1  (R14), [V4.B16]

	// Constants for verification
	WORD  $0x4f04e7e5               // movi v5.16b, #159
	WORD  $0x4f00e746               // movi v6.16b, #26
	WORD  $0x4f01e407               // movi v7.16b, #32

	// Preload normalized needle first/last bytes
	MOVBU (R6), R14
	ANDW  $0xDF, R14, R15
	SUBW  $65, R15, R16
	CMPW  $26, R16
	CSELW LO, R15, R14, R14

	SUB   $1, R7, R15
	ADD   R6, R15, R16
	MOVBU (R16), R16
	ANDW  $0xDF, R16, R17
	SUBW  $65, R17, R19
	CMPW  $26, R19
	CSELW LO, R17, R16, R16

	// Main loop
	MOVD  ZR, R17                  // i = 0
	ADD   $1, R9, R19              // searchLen

	CMP   $64, R19
	BLT   loop32_check

	SUB   $64, R19, R20

loop64:
	ADD   R17, R0, R21
	ADD   R3, R21, R22
	VLD1  (R22), [V16.B16, V17.B16, V18.B16, V19.B16]
	ADD   R5, R21, R22
	VLD1  (R22), [V20.B16, V21.B16, V22.B16, V23.B16]

	// Apply masks and compare: (data & mask) == rareU
	VAND  V1.B16, V16.B16, V24.B16
	VCMEQ V0.B16, V24.B16, V24.B16
	VAND  V3.B16, V20.B16, V25.B16
	VCMEQ V2.B16, V25.B16, V25.B16
	VAND  V24.B16, V25.B16, V24.B16  // chunk0

	VAND  V1.B16, V17.B16, V25.B16
	VCMEQ V0.B16, V25.B16, V25.B16
	VAND  V3.B16, V21.B16, V26.B16
	VCMEQ V2.B16, V26.B16, V26.B16
	VAND  V25.B16, V26.B16, V25.B16  // chunk1

	VAND  V1.B16, V18.B16, V26.B16
	VCMEQ V0.B16, V26.B16, V26.B16
	VAND  V3.B16, V22.B16, V27.B16
	VCMEQ V2.B16, V27.B16, V27.B16
	VAND  V26.B16, V27.B16, V26.B16  // chunk2

	VAND  V1.B16, V19.B16, V27.B16
	VCMEQ V0.B16, V27.B16, V27.B16
	VAND  V3.B16, V23.B16, V28.B16
	VCMEQ V2.B16, V28.B16, V28.B16
	VAND  V27.B16, V28.B16, V27.B16  // chunk3

	// Early exit: OR all chunks
	VORR  V24.B16, V25.B16, V28.B16
	VORR  V26.B16, V27.B16, V29.B16
	VORR  V28.B16, V29.B16, V28.B16
	WORD  $0x6e30ab9c               // umaxv b28, v28.16b
	FMOVS F28, R24
	CBZW  R24, adv64

	// Matches found - check each chunk
	WORD  $0x0f0c8718               // shrn v24.8b, v24.8h, #4
	FMOVD F24, R24
	CBNZ  R24, try64_c0

	WORD  $0x0f0c8739               // shrn v25.8b, v25.8h, #4
	FMOVD F25, R24
	MOVW  $16, R25
	CBNZ  R24, try64_cn

	WORD  $0x0f0c875a               // shrn v26.8b, v26.8h, #4
	FMOVD F26, R24
	MOVW  $32, R25
	CBNZ  R24, try64_cn

	WORD  $0x0f0c877b               // shrn v27.8b, v27.8h, #4
	FMOVD F27, R24
	MOVW  $48, R25
	CBNZ  R24, try64_cn
	B     adv64

try64_c0:
	MOVD  ZR, R25
try64_cn:
	// R24 = syndrome, R25 = chunk offset
	RBIT  R24, R26
	CLZ   R26, R26
	LSR   $2, R26, R26
	ADD   R25, R26, R26
	ADD   R17, R26, R26             // candidate = i + chunk_off + pos

	CMP   R9, R26
	BGT   adv64                     // past end

	// Verify
	ADD   R0, R26, R8
	MOVBU (R8), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   nf64a
	EORW  $0x20, R10, R10
nf64a:
	CMPW  R14, R10
	BNE   adv64

	ADD   R15, R8, R10
	MOVBU (R10), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   nf64b
	EORW  $0x20, R10, R10
nf64b:
	CMPW  R16, R10
	BNE   adv64

	// Full verify
	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

vl64:
	CMP   $16, R12
	BLT   vl64_tail
	VLD1  (R10), [V28.B16]
	VLD1  (R11), [V29.B16]
	VADD  V5.B16, V28.B16, V30.B16
	VEOR  V29.B16, V28.B16, V31.B16
	WORD  $0x6e3e37da               // cmhi v26.16b, v30.16b, v6.16b
	// Wrong - need cmhi v30, v6, v30 for "v6 > v30"
	// Let me use the pattern from original: cmhi v30.16b, v6.16b, v30.16b
	// ARM encoding for cmhi Vd.16b, Vn.16b, Vm.16b:
	// 0110 1110 001 Vm 0011 01 Vn Vd
	// cmhi v30.16b, v6.16b, v30.16b: Vd=30, Vn=6, Vm=30
	// = 6e 1e 34 de (need recalc)
	// Actually easier: use VCMHI Go syntax if available, otherwise just use inline
	// The original uses 0x6e3934b3 for cmhi v19.16b, v5.16b, v19.16b
	// Decoding: 6e xx 34 yy
	// For v30, v6, v30: Vm=30=11110, Vn=6=00110, Vd=30=11110
	// = 0110 1110 0011 1110 0011 0100 1101 1110 = 0x6e3e34de
	WORD  $0x6e3e34de               // cmhi v30.16b, v6.16b, v30.16b
	VAND  V7.B16, V30.B16, V30.B16
	VEOR  V30.B16, V31.B16, V30.B16
	WORD  $0x6e30abde               // umaxv b30, v30.16b
	FMOVS F30, R13
	CBNZW R13, adv64
	ADD   $16, R10, R10
	ADD   $16, R11, R11
	SUB   $16, R12, R12
	B     vl64

vl64_tail:
	CBZ   R12, fd64
vl64_sc:
	MOVBU (R10), R13
	MOVBU (R11), R21
	SUBW  $97, R13, R22
	CMPW  $26, R22
	BCS   vnf64
	EORW  $0x20, R13, R13
vnf64:
	CMPW  R21, R13
	BNE   adv64
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	CBNZ  R12, vl64_sc

fd64:
	MOVD  R26, R0
	MOVD  R0, ret+64(FP)
	RET

adv64:
	ADD   $64, R17, R17
	CMP   R20, R17
	BLE   loop64

loop32_check:
	CMP   $32, R19
	SUB   R17, R19, R20
	CMP   $32, R20
	BLT   loop16_check

loop32:
	ADD   R17, R0, R21
	ADD   R3, R21, R22
	VLD1  (R22), [V16.B16, V17.B16]
	ADD   R5, R21, R22
	VLD1  (R22), [V20.B16, V21.B16]

	VAND  V1.B16, V16.B16, V24.B16
	VCMEQ V0.B16, V24.B16, V24.B16
	VAND  V3.B16, V20.B16, V25.B16
	VCMEQ V2.B16, V25.B16, V25.B16
	VAND  V24.B16, V25.B16, V24.B16

	VAND  V1.B16, V17.B16, V25.B16
	VCMEQ V0.B16, V25.B16, V25.B16
	VAND  V3.B16, V21.B16, V26.B16
	VCMEQ V2.B16, V26.B16, V26.B16
	VAND  V25.B16, V26.B16, V25.B16

	VORR  V24.B16, V25.B16, V26.B16
	WORD  $0x6e30ab5a               // umaxv b26, v26.16b
	FMOVS F26, R24
	CBZW  R24, adv32

	WORD  $0x0f0c8718               // shrn v24.8b, v24.8h, #4
	FMOVD F24, R24
	CBNZ  R24, try32_c0

	WORD  $0x0f0c8739               // shrn v25.8b, v25.8h, #4
	FMOVD F25, R24
	MOVW  $16, R25
	B     try32_cn

try32_c0:
	MOVD  ZR, R25
try32_cn:
	RBIT  R24, R26
	CLZ   R26, R26
	LSR   $2, R26, R26
	ADD   R25, R26, R26
	ADD   R17, R26, R26

	CMP   R9, R26
	BGT   adv32

	ADD   R0, R26, R8
	MOVBU (R8), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   nf32a
	EORW  $0x20, R10, R10
nf32a:
	CMPW  R14, R10
	BNE   adv32

	ADD   R15, R8, R10
	MOVBU (R10), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   nf32b
	EORW  $0x20, R10, R10
nf32b:
	CMPW  R16, R10
	BNE   adv32

	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

vl32:
	CMP   $16, R12
	BLT   vl32_tail
	VLD1  (R10), [V28.B16]
	VLD1  (R11), [V29.B16]
	VADD  V5.B16, V28.B16, V30.B16
	VEOR  V29.B16, V28.B16, V31.B16
	WORD  $0x6e3e34de               // cmhi v30.16b, v6.16b, v30.16b
	VAND  V7.B16, V30.B16, V30.B16
	VEOR  V30.B16, V31.B16, V30.B16
	WORD  $0x6e30abde               // umaxv b30, v30.16b
	FMOVS F30, R13
	CBNZW R13, adv32
	ADD   $16, R10, R10
	ADD   $16, R11, R11
	SUB   $16, R12, R12
	B     vl32

vl32_tail:
	CBZ   R12, fd32
vl32_sc:
	MOVBU (R10), R13
	MOVBU (R11), R21
	SUBW  $97, R13, R22
	CMPW  $26, R22
	BCS   vnf32
	EORW  $0x20, R13, R13
vnf32:
	CMPW  R21, R13
	BNE   adv32
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	CBNZ  R12, vl32_sc

fd32:
	MOVD  R26, R0
	MOVD  R0, ret+64(FP)
	RET

adv32:
	ADD   $32, R17, R17
	SUB   R17, R19, R20
	CMP   $32, R20
	BGE   loop32

loop16_check:
	CMP   R19, R17
	BGE   not_found

loop16:
	SUB   R17, R19, R20
	CMP   $16, R20
	BLT   scalar

	ADD   R17, R0, R21
	ADD   R3, R21, R22
	VLD1  (R22), [V16.B16]
	ADD   R5, R21, R22
	VLD1  (R22), [V20.B16]

	VAND  V1.B16, V16.B16, V24.B16
	VCMEQ V0.B16, V24.B16, V24.B16
	VAND  V3.B16, V20.B16, V25.B16
	VCMEQ V2.B16, V25.B16, V25.B16
	VAND  V24.B16, V25.B16, V24.B16

	WORD  $0x0f0c8718               // shrn v24.8b, v24.8h, #4
	FMOVD F24, R24
	CBZ   R24, adv16

try16:
	RBIT  R24, R26
	CLZ   R26, R26
	LSR   $2, R26, R26
	ADD   R17, R26, R26

	CMP   R9, R26
	BGT   clear16

	ADD   R0, R26, R8
	MOVBU (R8), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   nf16a
	EORW  $0x20, R10, R10
nf16a:
	CMPW  R14, R10
	BNE   clear16

	ADD   R15, R8, R10
	MOVBU (R10), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   nf16b
	EORW  $0x20, R10, R10
nf16b:
	CMPW  R16, R10
	BNE   clear16

	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

vl16:
	CMP   $16, R12
	BLT   vl16_tail
	VLD1  (R10), [V28.B16]
	VLD1  (R11), [V29.B16]
	VADD  V5.B16, V28.B16, V30.B16
	VEOR  V29.B16, V28.B16, V31.B16
	WORD  $0x6e3e34de               // cmhi v30.16b, v6.16b, v30.16b
	VAND  V7.B16, V30.B16, V30.B16
	VEOR  V30.B16, V31.B16, V30.B16
	WORD  $0x6e30abde               // umaxv b30, v30.16b
	FMOVS F30, R13
	CBNZW R13, clear16
	ADD   $16, R10, R10
	ADD   $16, R11, R11
	SUB   $16, R12, R12
	B     vl16

vl16_tail:
	CBZ   R12, fd16
vl16_sc:
	MOVBU (R10), R13
	MOVBU (R11), R21
	SUBW  $97, R13, R22
	CMPW  $26, R22
	BCS   vnf16
	EORW  $0x20, R13, R13
vnf16:
	CMPW  R21, R13
	BNE   clear16
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	CBNZ  R12, vl16_sc

fd16:
	MOVD  R26, R0
	MOVD  R0, ret+64(FP)
	RET

clear16:
	ADD   $1, R26, R8
	SUB   R17, R8, R8
	LSL   $2, R8, R8
	MOVD  $1, R10
	LSL   R8, R10, R8
	SUB   $1, R8, R8
	BIC   R8, R24, R24
	CBNZ  R24, try16

adv16:
	ADD   $16, R17, R17
	CMP   R19, R17
	BLT   loop16

scalar:
	CMP   R19, R17
	BGE   not_found

	ADD   R17, R0, R21
	ADD   R3, R21, R22
	ADD   R5, R21, R23

	MOVBU (R22), R22
	MOVBU (R23), R23

	// Match rare1: (byte & mask1) == rare1U
	ANDW  R10, R22, R24
	VMOV  V0.B[0], R8
	CMPW  R8, R24
	BNE   adv_s

	// Match rare2
	ANDW  R12, R23, R24
	VMOV  V2.B[0], R8
	CMPW  R8, R24
	BNE   adv_s

	// Verify
	ADD   R0, R17, R8
	MOVBU (R8), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   snf3
	EORW  $0x20, R10, R10
snf3:
	CMPW  R14, R10
	BNE   adv_s

	ADD   R15, R8, R10
	MOVBU (R10), R10
	SUBW  $97, R10, R11
	CMPW  $26, R11
	BCS   snf4
	EORW  $0x20, R10, R10
snf4:
	CMPW  R16, R10
	BNE   adv_s

	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

sl:
	CBZ   R12, fds
	MOVBU (R10), R13
	MOVBU (R11), R21
	SUBW  $97, R13, R22
	CMPW  $26, R22
	BCS   snf5
	EORW  $0x20, R13, R13
snf5:
	CMPW  R21, R13
	BNE   adv_s
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	B     sl

fds:
	MOVD  R17, R0
	MOVD  R0, ret+64(FP)
	RET

adv_s:
	ADD   $1, R17, R17
	B     scalar

not_found:
	MOVD  $-1, R0
	MOVD  R0, ret+64(FP)
	RET

found_zero:
	MOVD  ZR, R0
	MOVD  R0, ret+64(FP)
	RET
