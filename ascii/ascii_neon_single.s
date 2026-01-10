//go:build !noasm && arm64

// Single-rare-byte NEON implementation for IndexFoldNeedle
// Goal: Match Go stdlib IndexByte's 41 GB/s by using only ONE rare byte
//
// Key insight: Go's Index uses byte-by-byte scan at ~41 GB/s with SIMD IndexByte prefilter.
// veloz's 2-rare-byte approach does 2 loads per position = half the throughput.
//
// This implementation searches for rare1 only, then verifies the full needle.
// Trade-off: More false positives but faster main loop.

#include "textflag.h"

// Magic constant for syndrome: 0x40100401
DATA magic_single<>+0x00(SB)/8, $0x4010040140100401
DATA magic_single<>+0x08(SB)/8, $0x4010040140100401
GLOBL magic_single<>(SB), (RODATA|NOPTR), $16

// func indexFoldNeedleNeonSingle(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleNeonSingle(SB), NOSPLIT, $0-72
	MOVD  haystack+0(FP), R0       // haystack ptr
	MOVD  haystack_len+8(FP), R1   // haystack len
	MOVBU rare1+16(FP), R2         // rare1
	MOVD  off1+24(FP), R3          // off1
	// rare2 and off2 ignored - single byte search
	MOVD  norm_needle+48(FP), R6   // needle ptr
	MOVD  needle_len+56(FP), R7    // needle len

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
	// rare1 is letter: we need to search for BOTH upper and lower
	ANDW  $0xDF, R2, R11           // rare1U (uppercase)
	ORRW  $0x20, R2, R12           // rare1L (lowercase)
	MOVW  $1, R13                  // is_letter flag
	B     r1_done
r1_not_letter:
	MOVW  R2, R11                  // rare1U = rare1
	MOVW  R2, R12                  // rare1L = rare1 (same)
	MOVW  $0, R13                  // not letter
r1_done:

	// Create NEON vectors
	VDUP  R11, V0.B16              // rare1U broadcast
	VDUP  R12, V1.B16              // rare1L broadcast

	// Load magic constant for syndrome
	MOVD  $magic_single<>(SB), R14
	VLD1  (R14), [V5.B16]

	// Precompute needle first/last bytes for quick verify
	MOVBU (R6), R14
	ANDW  $0xDF, R14, R15
	SUBW  $65, R15, R16
	CMPW  $26, R16
	CSELW LO, R15, R14, R14        // needle[0] normalized

	SUB   $1, R7, R15
	ADD   R6, R15, R16
	MOVBU (R16), R16
	ANDW  $0xDF, R16, R17
	SUBW  $65, R17, R19
	CMPW  $26, R19
	CSELW LO, R17, R16, R16        // needle[len-1] normalized

	// Main loop setup
	MOVD  ZR, R17                  // i = 0
	ADD   $1, R9, R19              // searchLen = haystack_len - needle_len + 1
	ADD   R3, R0, R20              // haystack + off1 (search position)

	// 32-byte aligned main loop like Go's IndexByte
	CMP   $32, R19
	BLT   loop16_check

	SUB   $32, R19, R21

loop32:
	ADD   R17, R20, R22            // &haystack[i + off1]
	VLD1.P 32(R22), [V2.B16, V3.B16]

	// Compare against both upper and lower (case-insensitive)
	VCMEQ V0.B16, V2.B16, V6.B16   // match upper in first 16
	VCMEQ V1.B16, V2.B16, V7.B16   // match lower in first 16
	VORR  V6.B16, V7.B16, V6.B16   // either matches

	VCMEQ V0.B16, V3.B16, V8.B16   // match upper in second 16
	VCMEQ V1.B16, V3.B16, V9.B16   // match lower in second 16
	VORR  V8.B16, V9.B16, V8.B16   // either matches

	// Fast early exit check (like Go)
	VORR  V6.B16, V8.B16, V10.B16
	WORD  $0x4e31ab4a              // addp v10.2d, v10.2d, v10.2d (fast 128→64 reduce)
	VMOV  V10.D[0], R22
	CBZ   R22, adv32              // no matches, advance 32

	// Match found - compute syndrome
	VAND  V5.B16, V6.B16, V6.B16
	VAND  V5.B16, V8.B16, V8.B16
	VADDP V8.B16, V6.B16, V10.B16  // 256→128
	VADDP V10.B16, V10.B16, V10.B16 // 128→64
	VMOV  V10.D[0], R22

try32:
	CBZ   R22, adv32
	RBIT  R22, R23
	CLZ   R23, R23
	LSR   $1, R23, R23             // position in chunk
	ADD   R17, R23, R23            // candidate = i + pos

	CMP   R9, R23
	BGT   clear32                  // past searchLen

	// Verify candidate
	ADD   R0, R23, R8              // &haystack[candidate]

	// Quick first/last byte check
	MOVBU (R8), R24
	SUBW  $97, R24, R25
	CMPW  $26, R25
	BCS   nf32a
	ANDW  $0xDF, R24, R24          // normalize to upper
nf32a:
	CMPW  R14, R24
	BNE   clear32

	ADD   R15, R8, R24
	MOVBU (R24), R24
	SUBW  $97, R24, R25
	CMPW  $26, R25
	BCS   nf32b
	ANDW  $0xDF, R24, R24
nf32b:
	CMPW  R16, R24
	BNE   clear32

	// Full verification
	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

vloop32:
	CMP   $8, R12
	BLT   vtail32
	MOVD  (R10), R24
	MOVD  (R11), R25
	// Quick check: if equal, no case folding needed
	CMP   R24, R25
	BEQ   vok32
	// Case-fold and compare byte by byte
	B     vslow32
vok32:
	ADD   $8, R10, R10
	ADD   $8, R11, R11
	SUB   $8, R12, R12
	B     vloop32

vtail32:
	CBZ   R12, found32
vslow32:
	MOVBU (R10), R24
	MOVBU (R11), R25
	SUBW  $97, R24, R26
	CMPW  $26, R26
	BCS   vnf32
	ANDW  $0xDF, R24, R24
vnf32:
	CMPW  R25, R24
	BNE   clear32
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	CBNZ  R12, vslow32

found32:
	MOVD  R23, R0
	MOVD  R0, ret+64(FP)
	RET

clear32:
	// Clear this bit and try next
	ADD   $1, R23, R24
	SUB   R17, R24, R24
	LSL   $1, R24, R24
	MOVD  $1, R25
	LSL   R24, R25, R24
	SUB   $1, R24, R24
	BIC   R24, R22, R22
	B     try32

adv32:
	ADD   $32, R17, R17
	CMP   R21, R17
	BLE   loop32

loop16_check:
	CMP   R19, R17
	BGE   not_found

loop16:
	SUB   R17, R19, R21
	CMP   $16, R21
	BLT   scalar

	ADD   R17, R20, R22
	VLD1  (R22), [V2.B16]

	VCMEQ V0.B16, V2.B16, V6.B16
	VCMEQ V1.B16, V2.B16, V7.B16
	VORR  V6.B16, V7.B16, V6.B16

	// Compute syndrome immediately for 16-byte path
	VAND  V5.B16, V6.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VADDP V6.B16, V6.B16, V6.B16
	VMOV  V6.D[0], R22
	CBZ   R22, adv16

try16:
	RBIT  R22, R23
	CLZ   R23, R23
	LSR   $1, R23, R23
	ADD   R17, R23, R23

	CMP   R9, R23
	BGT   clear16

	ADD   R0, R23, R8
	MOVBU (R8), R24
	SUBW  $97, R24, R25
	CMPW  $26, R25
	BCS   nf16a
	ANDW  $0xDF, R24, R24
nf16a:
	CMPW  R14, R24
	BNE   clear16

	ADD   R15, R8, R24
	MOVBU (R24), R24
	SUBW  $97, R24, R25
	CMPW  $26, R25
	BCS   nf16b
	ANDW  $0xDF, R24, R24
nf16b:
	CMPW  R16, R24
	BNE   clear16

	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

vloop16:
	CBZ   R12, found16
	MOVBU (R10), R24
	MOVBU (R11), R25
	SUBW  $97, R24, R26
	CMPW  $26, R26
	BCS   vnf16
	ANDW  $0xDF, R24, R24
vnf16:
	CMPW  R25, R24
	BNE   clear16
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	B     vloop16

found16:
	MOVD  R23, R0
	MOVD  R0, ret+64(FP)
	RET

clear16:
	ADD   $1, R23, R24
	SUB   R17, R24, R24
	LSL   $1, R24, R24
	MOVD  $1, R25
	LSL   R24, R25, R24
	SUB   $1, R24, R24
	BIC   R24, R22, R22
	CBNZ  R22, try16

adv16:
	ADD   $16, R17, R17
	CMP   R19, R17
	BLT   loop16

scalar:
	CMP   R19, R17
	BGE   not_found

	ADD   R17, R20, R22
	MOVBU (R22), R22

	// Check rare1 match (case-insensitive)
	CMPW  R11, R22
	BEQ   scalar_match
	CMPW  R12, R22
	BNE   scalar_next

scalar_match:
	ADD   R0, R17, R8
	MOVBU (R8), R24
	SUBW  $97, R24, R25
	CMPW  $26, R25
	BCS   snf1
	ANDW  $0xDF, R24, R24
snf1:
	CMPW  R14, R24
	BNE   scalar_next

	ADD   R15, R8, R24
	MOVBU (R24), R24
	SUBW  $97, R24, R25
	CMPW  $26, R25
	BCS   snf2
	ANDW  $0xDF, R24, R24
snf2:
	CMPW  R16, R24
	BNE   scalar_next

	MOVD  R8, R10
	MOVD  R6, R11
	MOVD  R7, R12

sloop:
	CBZ   R12, founds
	MOVBU (R10), R24
	MOVBU (R11), R25
	SUBW  $97, R24, R26
	CMPW  $26, R26
	BCS   snf3
	ANDW  $0xDF, R24, R24
snf3:
	CMPW  R25, R24
	BNE   scalar_next
	ADD   $1, R10, R10
	ADD   $1, R11, R11
	SUB   $1, R12, R12
	B     sloop

founds:
	MOVD  R17, R0
	MOVD  R0, ret+64(FP)
	RET

scalar_next:
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
