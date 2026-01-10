//go:build !noasm && arm64

// Hand-optimized SVE2 implementation for IndexFoldNeedle
// Targets Graviton 4 (Neoverse V2) with 128-bit SVE2
//
// Key optimizations over gocc-generated code:
// 1. Unrolled 2x VL (32 bytes) per main loop iteration  
// 2. Streamlined match verification with vectorized case-fold
// 3. Register allocation optimized for out-of-order execution

#include "textflag.h"

// func indexFoldNeedleSve2Opt(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
TEXT ·indexFoldNeedleSve2Opt(SB), NOSPLIT|NOFRAME, $0-72
	MOVD haystack+0(FP), R0
	MOVD haystack_len+8(FP), R1
	MOVBU rare1+16(FP), R2
	MOVD off1+24(FP), R3
	MOVBU rare2+32(FP), R4
	MOVD off2+40(FP), R5
	MOVD norm_needle+48(FP), R6
	MOVD needle_len+56(FP), R7

	// searchLen = haystackLen - needleLen + 1
	// if searchLen <= 0, return -1
	SUBS R7, R1, R9          // R9 = searchLen - 1
	BLT  return_not_found

	// Handle empty needle
	CBZ  R7, return_zero

	// Get vector length: rdvl x8, #1
	WORD $0x04bf5028          // rdvl x8, #1  -> VL in R8

	// Compute case variants for rare bytes
	ANDW $0xDF, R2, R10       // R10 = rare1 & 0xDF (potential upper)
	SUBW $65, R10, R11
	CMPW $26, R11
	CSELW LO, R10, R2, R10    // R10 = is_letter ? upper : rare1
	ORRW $0x20, R2, R11       // R11 = rare1 | 0x20 (potential lower)
	SUBW $65, R10, R12
	CMPW $26, R12
	CSELW LO, R11, R2, R11    // R11 = is_letter ? lower : rare1

	ANDW $0xDF, R4, R12       // R12 = rare2 & 0xDF
	SUBW $65, R12, R13
	CMPW $26, R13
	CSELW LO, R12, R4, R12
	ORRW $0x20, R4, R13
	SUBW $65, R12, R14
	CMPW $26, R14
	CSELW LO, R13, R4, R13

	// Create SVE vectors for svmatch using zip1
	WORD $0x05203940          // mov z0.b, w10  (rare1 upper)
	WORD $0x05203961          // mov z1.b, w11  (rare1 lower)
	WORD $0x05203982          // mov z2.b, w12  (rare2 upper)
	WORD $0x052039a3          // mov z3.b, w13  (rare2 lower)
	WORD $0x05216000          // zip1 z0.b, z0.b, z1.b
	WORD $0x05236042          // zip1 z2.b, z2.b, z3.b

	// Preload first/last needle bytes (already normalized)
	MOVBU (R6), R14           // R14 = needle[0]
	SUB   $1, R7, R15         // R15 = needleLen - 1
	ADD   R6, R15, R16        
	MOVBU (R16), R16          // R16 = needle[needleLen-1]

	// ptrue p0.b
	WORD $0x2518e3e0          // ptrue p0.b

	// Main loop setup
	MOVD ZR, R17              // i = 0
	ADD  $1, R9, R19          // R19 = searchLen

	// Check if we can do 2x VL unrolled loop
	LSL  $1, R8, R20          // R20 = 2*VL
	CMP  R20, R19
	BLT  loop_1x

loop_2x:
	// Process 2*VL bytes per iteration
	// Compute base address for this iteration
	ADD  R17, R0, R21         // R21 = haystack + i

	// ld1b {z4.b}, p0/z, [x21, x3] - load at off1
	// Encoding: 1010_0100_00mm_mmmm_010p_ppnn_nnnt_tttt
	// m=x3(3)=00011, p=p0(0)=000, n=x21(21)=10101, t=z4(4)=00100
	// = 1010_0100_0000_0011_0100_0010_1010_0100 = 0xa40342a4
	WORD $0xa40342a4          // ld1b {z4.b}, p0/z, [x21, x3]
	
	// ld1b {z5.b}, p0/z, [x21, x5] - load at off2
	// m=x5(5)=00101, n=x21(21)=10101, t=z5(5)=00101
	// = 1010_0100_0000_0101_0100_0010_1010_0101 = 0xa40542a5
	WORD $0xa40542a5          // ld1b {z5.b}, p0/z, [x21, x5]

	// svmatch p1, p0/z, z4, z0
	WORD $0x45208081          // match p1.b, p0/z, z4.b, z0.b
	// svmatch p2, p0/z, z5, z2
	WORD $0x452280a2          // match p2.b, p0/z, z5.b, z2.b
	// p1 = p1 & p2 (ands sets flags)
	WORD $0x25424021          // ands p1.b, p0/z, p1.b, p2.b

	// Load second VL: base + VL
	ADD  R8, R21, R22         // R22 = haystack + i + VL

	// ld1b {z6.b}, p0/z, [x22, x3]
	// n=x22(22)=10110, m=x3(3), t=z6(6), p=p0(0)
	WORD $0xa40342c6          // ld1b {z6.b}, p0/z, [x22, x3]
	// ld1b {z7.b}, p0/z, [x22, x5]
	WORD $0xa40542c7          // ld1b {z7.b}, p0/z, [x22, x5]

	// svmatch for second chunk
	WORD $0x452080c3          // match p3.b, p0/z, z6.b, z0.b
	WORD $0x452280e4          // match p4.b, p0/z, z7.b, z2.b
	WORD $0x25444063          // ands p3.b, p0/z, p3.b, p4.b

	// Check first chunk matches (ands above set flags - but we need to re-check p1)
	// orrs p4.b, p0/z, p1.b, p1.b - sets flags based on p1
	WORD $0x25c14021          // orrs p4.b, p0/z, p1.b, p1.b
	BNE  verify_matches_2x_first

check_second_2x:
	// orrs p4.b, p0/z, p3.b, p3.b - sets flags based on p3
	WORD $0x25c34063          // orrs p4.b, p0/z, p3.b, p3.b
	BNE  verify_matches_2x_second

advance_2x:
	ADD  R20, R17, R17        // i += 2*VL
	SUB  R17, R19, R24        // remaining = searchLen - i
	CMP  R20, R24
	BGE  loop_2x

	CMP  R8, R24
	BLT  loop_tail

loop_1x:
	ADD  R17, R0, R21         // R21 = haystack + i

	WORD $0xa40342a4          // ld1b {z4.b}, p0/z, [x21, x3]
	WORD $0xa40542a5          // ld1b {z5.b}, p0/z, [x21, x5]

	WORD $0x45208081          // match p1.b, p0/z, z4.b, z0.b
	WORD $0x452280a2          // match p2.b, p0/z, z5.b, z2.b
	WORD $0x25424021          // ands p1.b, p0/z, p1.b, p2.b (sets flags)
	BNE  verify_matches_1x

advance_1x:
	ADD  R8, R17, R17
	SUB  R17, R19, R24
	CMP  R8, R24
	BGE  loop_1x

loop_tail:
	SUB  R17, R19, R24        // remaining
	CBZ  R24, return_not_found

	// whilelo p5.b, xzr, x24
	WORD $0x25381fe5          // whilelo p5.b, xzr, x24

	ADD  R17, R0, R21

	// ld1b {z4.b}, p5/z, [x21, x3]
	// n=x21(21), m=x3(3), t=z4(4), p=p5(5)=101
	// = 1010_0100_0000_0011_0101_0110_1010_0100 = 0xa40356a4
	WORD $0xa40356a4          // ld1b {z4.b}, p5/z, [x21, x3]
	WORD $0xa40556a5          // ld1b {z5.b}, p5/z, [x21, x5]

	WORD $0x45208141          // match p1.b, p5/z, z4.b, z0.b
	WORD $0x45228162          // match p2.b, p5/z, z5.b, z2.b
	WORD $0x25424141          // ands p1.b, p5/z, p1.b, p2.b (sets flags)
	BNE  verify_matches_tail

return_not_found:
	MOVD $-1, R0
	MOVD R0, ret+64(FP)
	RET

return_zero:
	MOVD ZR, R0
	MOVD R0, ret+64(FP)
	RET

// Verification for 2x first chunk
verify_matches_2x_first:
	WORD $0x25904021          // brkb p6.b, p0/z, p1.b
	WORD $0x252080d8          // cntp x24, p0, p6.b

	ADD  R17, R24, R24        // idx = i + pos

	CMP  R9, R24
	BGT  clear_2x_first

	// Quick check first byte
	ADD  R0, R24, R25
	MOVBU (R25), R26
	ANDW $0xDF, R26, R10
	SUBW $65, R10, R11
	CMPW $26, R11
	CSELW LO, R10, R26, R26
	CMPW R14, R26
	BNE  clear_2x_first

	// Quick check last byte
	ADD  R15, R25, R10
	MOVBU (R10), R10
	ANDW $0xDF, R10, R11
	SUBW $65, R11, R12
	CMPW $26, R12
	CSELW LO, R11, R10, R10
	CMPW R16, R10
	BNE  clear_2x_first

	// Full verification
	MOVD R25, R10             // haystack ptr
	MOVD R6, R11              // needle ptr
	MOVD R7, R12              // remaining

verify_loop_2x_first:
	CBZ  R12, found_2x_first
	CMP  R8, R12
	BLT  verify_scalar_2x_first

	// ld1b {z8.b}, p0/z, [x10]
	WORD $0xa400a148          // ld1b {z8.b}, p0/z, [x10]
	WORD $0xa400a169          // ld1b {z9.b}, p0/z, [x11]          // ld1b {z9.b}, p0/z, [x11]

	// Normalize z8: if 'a'<=z8<='z', xor with 0x20
	WORD $0x24384102          // cmphs p2.b, p0/z, z8.b, #97
	WORD $0x243ea103          // cmpls p3.b, p0/z, z8.b, #122
	WORD $0x25034042          // and p2.b, p0/z, p2.b, p3.b
	WORD $0x2538c40a          // mov z10.b, #32
	WORD $0x04190908          // eor z8.b, p2/m, z8.b, z10.b

	// Compare: XOR and check for any non-zero
	WORD $0x04080128          // eor z8.d, z8.d, z9.d
	// cmpne sets flags - need orrs to test predicate
	WORD $0x25008102          // cmpne p2.b, p0/z, z8.b, #0
	WORD $0x25c24042          // orrs p2.b, p0/z, p2.b, p2.b (sets flags based on p2)
	BNE  clear_2x_first

	ADD  R8, R10, R10
	ADD  R8, R11, R11
	SUB  R8, R12, R12
	B    verify_loop_2x_first

verify_scalar_2x_first:
	CBZ  R12, found_2x_first
	MOVBU (R10), R13
	MOVBU (R11), R21
	ANDW $0xDF, R13, R22
	SUBW $65, R22, R23
	CMPW $26, R23
	CSELW LO, R22, R13, R13
	CMP  R21, R13
	BNE  clear_2x_first
	ADD  $1, R10, R10
	ADD  $1, R11, R11
	SUB  $1, R12, R12
	B    verify_scalar_2x_first

found_2x_first:
	MOVD R24, R0
	MOVD R0, ret+64(FP)
	RET

clear_2x_first:
	WORD $0x25104021          // brka p6.b, p0/z, p1.b
	WORD $0x25464031          // bics p1.b, p0/z, p1.b, p6.b (sets flags)
	BNE  verify_matches_2x_first
	B    check_second_2x

// Verification for 2x second chunk
verify_matches_2x_second:
	WORD $0x25904063          // brkb p6.b, p0/z, p3.b
	WORD $0x252080d8          // cntp x24, p0, p6.b

	ADD  R17, R8, R25         // i + VL
	ADD  R25, R24, R24        // idx = i + VL + pos

	CMP  R9, R24
	BGT  clear_2x_second

	ADD  R0, R24, R25
	MOVBU (R25), R26
	ANDW $0xDF, R26, R10
	SUBW $65, R10, R11
	CMPW $26, R11
	CSELW LO, R10, R26, R26
	CMPW R14, R26
	BNE  clear_2x_second

	ADD  R15, R25, R10
	MOVBU (R10), R10
	ANDW $0xDF, R10, R11
	SUBW $65, R11, R12
	CMPW $26, R12
	CSELW LO, R11, R10, R10
	CMPW R16, R10
	BNE  clear_2x_second

	MOVD R25, R10
	MOVD R6, R11
	MOVD R7, R12

verify_loop_2x_second:
	CBZ  R12, found_2x_second
	CMP  R8, R12
	BLT  verify_scalar_2x_second

	WORD $0xa400a148          // ld1b {z8.b}, p0/z, [x10]
	WORD $0xa400a169          // ld1b {z9.b}, p0/z, [x11]
	WORD $0x24384102          // cmphs p2.b, p0/z, z8.b, #97
	WORD $0x243ea103          // cmpls p3.b, p0/z, z8.b, #122
	WORD $0x25034042          // and p2.b, p0/z, p2.b, p3.b
	WORD $0x2538c40a          // mov z10.b, #32
	WORD $0x04190908          // eor z8.b, p2/m, z8.b, z10.b
	WORD $0x04080128          // eor z8.d, z8.d, z9.d
	WORD $0x25008102          // cmpne p2.b, p0/z, z8.b, #0
	WORD $0x25c24042          // orrs p2.b, p0/z, p2.b, p2.b (sets flags)
	BNE  clear_2x_second

	ADD  R8, R10, R10
	ADD  R8, R11, R11
	SUB  R8, R12, R12
	B    verify_loop_2x_second

verify_scalar_2x_second:
	CBZ  R12, found_2x_second
	MOVBU (R10), R13
	MOVBU (R11), R21
	ANDW $0xDF, R13, R22
	SUBW $65, R22, R23
	CMPW $26, R23
	CSELW LO, R22, R13, R13
	CMP  R21, R13
	BNE  clear_2x_second
	ADD  $1, R10, R10
	ADD  $1, R11, R11
	SUB  $1, R12, R12
	B    verify_scalar_2x_second

found_2x_second:
	MOVD R24, R0
	MOVD R0, ret+64(FP)
	RET

clear_2x_second:
	WORD $0x25104063          // brka p6.b, p0/z, p3.b
	WORD $0x25464073          // bics p3.b, p0/z, p3.b, p6.b (sets flags)
	BNE  verify_matches_2x_second
	B    advance_2x

// Verification for 1x loop
verify_matches_1x:
	WORD $0x25904021          // brkb p6.b, p0/z, p1.b
	WORD $0x252080d8          // cntp x24, p0, p6.b

	ADD  R17, R24, R24

	CMP  R9, R24
	BGT  clear_1x

	ADD  R0, R24, R25
	MOVBU (R25), R26
	ANDW $0xDF, R26, R10
	SUBW $65, R10, R11
	CMPW $26, R11
	CSELW LO, R10, R26, R26
	CMPW R14, R26
	BNE  clear_1x

	ADD  R15, R25, R10
	MOVBU (R10), R10
	ANDW $0xDF, R10, R11
	SUBW $65, R11, R12
	CMPW $26, R12
	CSELW LO, R11, R10, R10
	CMPW R16, R10
	BNE  clear_1x

	MOVD R25, R10
	MOVD R6, R11
	MOVD R7, R12

verify_loop_1x:
	CBZ  R12, found_1x
	CMP  R8, R12
	BLT  verify_scalar_1x

	WORD $0xa400a148          // ld1b {z8.b}, p0/z, [x10]
	WORD $0xa400a169          // ld1b {z9.b}, p0/z, [x11]
	WORD $0x24384102          // cmphs p2.b, p0/z, z8.b, #97
	WORD $0x243ea103          // cmpls p3.b, p0/z, z8.b, #122
	WORD $0x25034042          // and p2.b, p0/z, p2.b, p3.b
	WORD $0x2538c40a          // mov z10.b, #32
	WORD $0x04190908          // eor z8.b, p2/m, z8.b, z10.b
	WORD $0x04080128          // eor z8.d, z8.d, z9.d
	WORD $0x25008102          // cmpne p2.b, p0/z, z8.b, #0
	WORD $0x25c24042          // orrs p2.b, p0/z, p2.b, p2.b (sets flags)
	BNE  clear_1x

	ADD  R8, R10, R10
	ADD  R8, R11, R11
	SUB  R8, R12, R12
	B    verify_loop_1x

verify_scalar_1x:
	CBZ  R12, found_1x
	MOVBU (R10), R13
	MOVBU (R11), R21
	ANDW $0xDF, R13, R22
	SUBW $65, R22, R23
	CMPW $26, R23
	CSELW LO, R22, R13, R13
	CMP  R21, R13
	BNE  clear_1x
	ADD  $1, R10, R10
	ADD  $1, R11, R11
	SUB  $1, R12, R12
	B    verify_scalar_1x

found_1x:
	MOVD R24, R0
	MOVD R0, ret+64(FP)
	RET

clear_1x:
	WORD $0x25104021          // brka p6.b, p0/z, p1.b
	WORD $0x25464031          // bics p1.b, p0/z, p1.b, p6.b (sets flags)
	BNE  verify_matches_1x
	B    advance_1x

// Verification for tail
verify_matches_tail:
	WORD $0x25904141          // brkb p6.b, p5/z, p1.b
	WORD $0x252140d8          // cntp x24, p5, p6.b

	ADD  R17, R24, R24

	CMP  R9, R24
	BGT  clear_tail

	ADD  R0, R24, R25
	MOVBU (R25), R26
	ANDW $0xDF, R26, R10
	SUBW $65, R10, R11
	CMPW $26, R11
	CSELW LO, R10, R26, R26
	CMPW R14, R26
	BNE  clear_tail

	ADD  R15, R25, R10
	MOVBU (R10), R10
	ANDW $0xDF, R10, R11
	SUBW $65, R11, R12
	CMPW $26, R12
	CSELW LO, R11, R10, R10
	CMPW R16, R10
	BNE  clear_tail

	MOVD R25, R10
	MOVD R6, R11
	MOVD R7, R12

verify_loop_tail:
	CBZ  R12, found_tail
	CMP  R8, R12
	BLT  verify_scalar_tail

	WORD $0xa400a148          // ld1b {z8.b}, p0/z, [x10]
	WORD $0xa400a169          // ld1b {z9.b}, p0/z, [x11]          // ld1b {z9.b}, p0/z, [x11]
	WORD $0x24384102          // cmphs p2.b, p0/z, z8.b, #97
	WORD $0x243ea103          // cmpls p3.b, p0/z, z8.b, #122
	WORD $0x25034042          // and p2.b, p0/z, p2.b, p3.b
	WORD $0x2538c40a          // mov z10.b, #32
	WORD $0x04190908          // eor z8.b, p2/m, z8.b, z10.b
	WORD $0x04080128          // eor z8.d, z8.d, z9.d
	WORD $0x25008102          // cmpne p2.b, p0/z, z8.b, #0
	WORD $0x25c24042          // orrs p2.b, p0/z, p2.b, p2.b (sets flags)
	BNE  clear_tail

	ADD  R8, R10, R10
	ADD  R8, R11, R11
	SUB  R8, R12, R12
	B    verify_loop_tail

verify_scalar_tail:
	CBZ  R12, found_tail
	MOVBU (R10), R13
	MOVBU (R11), R21
	ANDW $0xDF, R13, R22
	SUBW $65, R22, R23
	CMPW $26, R23
	CSELW LO, R22, R13, R13
	CMP  R21, R13
	BNE  clear_tail
	ADD  $1, R10, R10
	ADD  $1, R11, R11
	SUB  $1, R12, R12
	B    verify_scalar_tail

found_tail:
	MOVD R24, R0
	MOVD R0, ret+64(FP)
	RET

clear_tail:
	WORD $0x25104141          // brka p6.b, p5/z, p1.b
	WORD $0x25464171          // bics p1.b, p5/z, p1.b, p6.b (sets flags)
	BNE  verify_matches_tail
	B    return_not_found
