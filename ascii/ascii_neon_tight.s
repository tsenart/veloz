//go:build !noasm && arm64

// Tight 64-byte NEON loop minimizing instructions in hot path
// Key: Do absolute minimum between load and early exit

#include "textflag.h"

// func indexFoldNeedleNeonTight(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleNeonTight(SB), NOSPLIT, $0-72
	MOVD  haystack+0(FP), R0
	MOVD  haystack_len+8(FP), R1
	MOVBU rare1+16(FP), R2
	MOVD  off1+24(FP), R3
	MOVD  norm_needle+48(FP), R6
	MOVD  needle_len+56(FP), R7

	SUBS  R7, R1, R9
	BLT   not_found
	CBZ   R7, found_zero

	// Compute mask and target
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

	// Setup
	ADD   R3, R0, R10             // searchPtr
	MOVD  R10, R11                // save original
	ADD   $1, R9, R12             // remaining

	CMP   $64, R12
	BLT   loop32_entry

	// Pre-subtract to set up loop
	SUB   $64, R12, R12

loop64:
	// Load 64 bytes
	VLD1.P 64(R10), [V16.B16, V17.B16, V18.B16, V19.B16]

	// Apply mask to all 4 chunks
	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VAND  V0.B16, V18.B16, V22.B16
	VAND  V0.B16, V19.B16, V23.B16

	// Compare all 4 chunks
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16
	VCMEQ V1.B16, V22.B16, V22.B16
	VCMEQ V1.B16, V23.B16, V23.B16

	// OR all together for quick check
	VORR  V20.B16, V21.B16, V24.B16
	VORR  V22.B16, V23.B16, V25.B16
	VORR  V24.B16, V25.B16, V26.B16

	// Check if more data and no match - tight exit
	SUBS  $64, R12, R12
	BLT   end64
	VADDP V26.D2, V26.D2, V26.D2
	VMOV  V26.D[0], R13
	CBZ   R13, loop64

	// Match found - restore R12 for position calculation
	ADD   $64, R12, R12

end64:
	// Apply magic constant for position finding
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VAND  V5.B16, V22.B16, V22.B16
	VAND  V5.B16, V23.B16, V23.B16

	// Combine syndromes pairwise
	VADDP V21.B16, V20.B16, V24.B16  // chunks 0,1 -> 32 bytes
	VADDP V23.B16, V22.B16, V25.B16  // chunks 2,3 -> 32 bytes
	VADDP V25.B16, V24.B16, V26.B16  // all -> 16 bytes
	VADDP V26.B16, V26.B16, V26.B16  // -> 8 bytes
	VMOV  V26.D[0], R13

	// Mask if partial block
	CMP   $0, R12
	BGE   find_pos64
	// Mask invalid upper bits
	ADD   $64, R12, R14           // actual bytes valid
	LSL   $1, R14, R14            // 2 bits per byte
	MOVD  $-1, R15
	LSL   R14, R15, R15
	BIC   R15, R13, R13

find_pos64:
	CBZ   R13, after64
	RBIT  R13, R14
	CLZ   R14, R14
	LSR   $1, R14, R14            // byte position

	// Calculate haystack position
	SUB   $64, R10, R15
	ADD   R14, R15, R15
	SUB   R11, R15, R15           // offset from searchPtr

	CMP   R9, R15
	BGT   clear64

	// Verify
	ADD   R0, R15, R8

	MOVBU (R8), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   v1
	ANDW  $0xDF, R16, R16
v1:
	MOVBU (R6), R17
	CMPW  R17, R16
	BNE   clear64

	ADD   R7, R8, R16
	SUB   $1, R16
	MOVBU (R16), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   v2
	ANDW  $0xDF, R16, R16
v2:
	ADD   R7, R6, R17
	SUB   $1, R17
	MOVBU (R17), R17
	CMPW  R17, R16
	BNE   clear64

	// Full verify
	MOVD  R8, R16
	MOVD  R6, R17
	MOVD  R7, R19

vloop:
	CBZ   R19, found
	MOVBU (R16), R20
	MOVBU (R17), R21
	SUBW  $97, R20, R22
	CMPW  $26, R22
	BCS   v3
	ANDW  $0xDF, R20, R20
v3:
	CMPW  R21, R20
	BNE   clear64
	ADD   $1, R16
	ADD   $1, R17
	SUB   $1, R19
	B     vloop

found:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear64:
	// Clear this bit
	ADD   $1, R14, R15
	LSL   $1, R15, R15
	MOVD  $1, R16
	LSL   R15, R16, R15
	SUB   $1, R15, R15
	BIC   R15, R13, R13
	B     find_pos64

after64:
	CMP   $0, R12
	BGE   loop32_entry
	B     not_found

loop32_entry:
	ADD   $64, R12, R12           // Restore if we came from end64
	CMP   $32, R12
	BLT   loop16_entry

loop32:
	VLD1.P 32(R10), [V16.B16, V17.B16]
	SUBS  $32, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VAND  V0.B16, V17.B16, V21.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VCMEQ V1.B16, V21.B16, V21.B16

	VORR  V20.B16, V21.B16, V22.B16
	BLT   end32
	VADDP V22.D2, V22.D2, V22.D2
	VMOV  V22.D[0], R13
	CBZ   R13, loop32
	ADD   $32, R12, R12

end32:
	VAND  V5.B16, V20.B16, V20.B16
	VAND  V5.B16, V21.B16, V21.B16
	VADDP V21.B16, V20.B16, V22.B16
	VADDP V22.B16, V22.B16, V22.B16
	VMOV  V22.D[0], R13

	CMP   $0, R12
	BGE   find32
	ADD   $32, R12, R14
	LSL   $1, R14, R14
	MOVD  $-1, R15
	LSL   R14, R15, R15
	BIC   R15, R13, R13

find32:
	CBZ   R13, after32
	RBIT  R13, R14
	CLZ   R14, R14
	LSR   $1, R14, R14

	SUB   $32, R10, R15
	ADD   R14, R15, R15
	SUB   R11, R15, R15

	CMP   R9, R15
	BGT   clear32

	ADD   R0, R15, R8

	MOVBU (R8), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   v32a
	ANDW  $0xDF, R16, R16
v32a:
	MOVBU (R6), R17
	CMPW  R17, R16
	BNE   clear32

	ADD   R7, R8, R16
	SUB   $1, R16
	MOVBU (R16), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   v32b
	ANDW  $0xDF, R16, R16
v32b:
	ADD   R7, R6, R17
	SUB   $1, R17
	MOVBU (R17), R17
	CMPW  R17, R16
	BNE   clear32

	MOVD  R8, R16
	MOVD  R6, R17
	MOVD  R7, R19

vloop32:
	CBZ   R19, found32
	MOVBU (R16), R20
	MOVBU (R17), R21
	SUBW  $97, R20, R22
	CMPW  $26, R22
	BCS   v32c
	ANDW  $0xDF, R20, R20
v32c:
	CMPW  R21, R20
	BNE   clear32
	ADD   $1, R16
	ADD   $1, R17
	SUB   $1, R19
	B     vloop32

found32:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear32:
	ADD   $1, R14, R15
	LSL   $1, R15, R15
	MOVD  $1, R16
	LSL   R15, R16, R15
	SUB   $1, R15, R15
	BIC   R15, R13, R13
	B     find32

after32:
	CMP   $0, R12
	BGE   loop16_entry
	B     not_found

loop16_entry:
	ADD   $32, R12, R12
	CMP   $16, R12
	BLT   scalar_entry

loop16:
	VLD1.P 16(R10), [V16.B16]
	SUBS  $16, R12, R12

	VAND  V0.B16, V16.B16, V20.B16
	VCMEQ V1.B16, V20.B16, V20.B16
	VAND  V5.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VADDP V20.B16, V20.B16, V20.B16
	VMOV  V20.D[0], R13

	BLT   mask16
	CBZ   R13, loop16
	B     find16

mask16:
	ADD   $16, R12, R14
	LSL   $1, R14, R14
	MOVD  $-1, R15
	LSL   R14, R15, R15
	BIC   R15, R13, R13

find16:
	CBZ   R13, after16
	RBIT  R13, R14
	CLZ   R14, R14
	LSR   $1, R14, R14

	SUB   $16, R10, R15
	ADD   R14, R15, R15
	SUB   R11, R15, R15

	CMP   R9, R15
	BGT   clear16

	ADD   R0, R15, R8

	MOVBU (R8), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   v16a
	ANDW  $0xDF, R16, R16
v16a:
	MOVBU (R6), R17
	CMPW  R17, R16
	BNE   clear16

	ADD   R7, R8, R16
	SUB   $1, R16
	MOVBU (R16), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   v16b
	ANDW  $0xDF, R16, R16
v16b:
	ADD   R7, R6, R17
	SUB   $1, R17
	MOVBU (R17), R17
	CMPW  R17, R16
	BNE   clear16

	MOVD  R8, R16
	MOVD  R6, R17
	MOVD  R7, R19

vloop16:
	CBZ   R19, found16
	MOVBU (R16), R20
	MOVBU (R17), R21
	SUBW  $97, R20, R22
	CMPW  $26, R22
	BCS   v16c
	ANDW  $0xDF, R20, R20
v16c:
	CMPW  R21, R20
	BNE   clear16
	ADD   $1, R16
	ADD   $1, R17
	SUB   $1, R19
	B     vloop16

found16:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

clear16:
	ADD   $1, R14, R15
	LSL   $1, R15, R15
	MOVD  $1, R16
	LSL   R15, R16, R15
	SUB   $1, R15, R15
	BIC   R15, R13, R13
	B     find16

after16:
	CMP   $0, R12
	BGE   scalar_entry
	B     not_found

scalar_entry:
	ADD   $16, R12, R12
	CMP   $0, R12
	BLE   not_found

scalar:
	MOVBU (R10), R13
	ANDW  R4, R13, R14
	CMPW  R5, R14
	BNE   snext

	SUB   R11, R10, R15
	CMP   R9, R15
	BGT   snext

	ADD   R0, R15, R8

	MOVBU (R8), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   sva
	ANDW  $0xDF, R16, R16
sva:
	MOVBU (R6), R17
	CMPW  R17, R16
	BNE   snext

	ADD   R7, R8, R16
	SUB   $1, R16
	MOVBU (R16), R16
	SUBW  $97, R16, R17
	CMPW  $26, R17
	BCS   svb
	ANDW  $0xDF, R16, R16
svb:
	ADD   R7, R6, R17
	SUB   $1, R17
	MOVBU (R17), R17
	CMPW  R17, R16
	BNE   snext

	MOVD  R8, R16
	MOVD  R6, R17
	MOVD  R7, R19

sloop:
	CBZ   R19, founds
	MOVBU (R16), R20
	MOVBU (R17), R21
	SUBW  $97, R20, R22
	CMPW  $26, R22
	BCS   svc
	ANDW  $0xDF, R20, R20
svc:
	CMPW  R21, R20
	BNE   snext
	ADD   $1, R16
	ADD   $1, R17
	SUB   $1, R19
	B     sloop

founds:
	SUB   R0, R8, R0
	MOVD  R0, ret+64(FP)
	RET

snext:
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
