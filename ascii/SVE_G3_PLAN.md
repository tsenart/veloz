# SVE-G3 Implementation Plan

## Target: Graviton 3 (Neoverse V1) with 256-bit SVE

### Hardware Facts (Verified)
- **Vector Length**: 256-bit (32 bytes) - confirmed by AWS docs and NVIDIA blog
- **SVE Version**: SVE (NOT SVE2) - ARMv8.4-a, no MATCH instruction
- **Architecture**: Neoverse V1
- **SIMD**: 2× SVE 256-bit units OR 4× NEON 128-bit units

### Key Insight: Why This Beats NEON on G4

| Factor | NEON (G4) | SVE (G3) |
|--------|-----------|----------|
| Vector width | 128-bit | **256-bit** |
| Vectors for 128B | 8 | **4** |
| Load instructions/128B | 8 | **4** |
| Filter instructions/128B | 16 | **8** |
| Tail handling | 256B table | **WHILELO** |
| Position extraction | SHRN+FMOVD+RBIT+CLZ (4+) | **BRKB+CNTP (2)** |

**2× vector width = 2× instruction efficiency**

---

## SVE Instructions Available (Verified in SVE, not SVE2)

### Core Instructions We Need
| Instruction | Purpose | SVE? | Encoding Source |
|-------------|---------|------|-----------------|
| `PTRUE Pd.B` | All-true predicate | ✅ SVE | ascii_sve2_opt.s |
| `RDVL Xd, #imm` | Get vector length | ✅ SVE | ascii_sve2_opt.s |
| `LD1B {Zd.B}, Pg/Z, [Xn, Xm]` | Predicated byte load | ✅ SVE | ascii_sve2_opt.s |
| `CMPEQ Pd.B, Pg/Z, Zn.B, Zm.B` | Compare equal | ✅ SVE | Verified in docs |
| `CMPEQ Pd.B, Pg/Z, Zn.B, #imm` | Compare equal imm | ✅ SVE | Verified in docs |
| `AND Pd.B, Pg/Z, Pn.B, Pm.B` | Predicate AND | ✅ SVE | Standard |
| `ANDS Pd.B, Pg/Z, Pn.B, Pm.B` | Predicate AND + flags | ✅ SVE | Standard |
| `ORRS Pd.B, Pg/Z, Pn.B, Pm.B` | Predicate OR + flags | ✅ SVE | ascii_sve2_opt.s |
| `BRKB Pd.B, Pg/Z, Pn.B` | Break after first true | ✅ SVE | ascii_sve2_opt.s |
| `BRKA Pd.B, Pg/Z, Pn.B` | Break at first true | ✅ SVE | ascii_sve2_opt.s |
| `CNTP Xd, Pg, Pn.B` | Count true predicates | ✅ SVE | ascii_sve2_opt.s |
| `WHILELO Pd.B, Xn, Xm` | Generate loop predicate | ✅ SVE | Verified in docs |
| `CMPHS Pd.B, Pg/Z, Zn.B, #imm` | Compare >= unsigned | ✅ SVE | ascii_sve2_opt.s |
| `CMPLS Pd.B, Pg/Z, Zn.B, #imm` | Compare <= unsigned | ✅ SVE | ascii_sve2_opt.s |
| `EOR Zd.B, Pg/M, Zn.B, Zm.B` | Predicated XOR | ✅ SVE | ascii_sve2_opt.s |
| `EOR Zd.D, Zn.D, Zm.D` | Unpredicated XOR | ✅ SVE | ascii_sve2_opt.s |
| `CMPNE Pd.B, Pg/Z, Zn.B, #0` | Compare not equal 0 | ✅ SVE | ascii_sve2_opt.s |
| `MOV Zd.B, #imm` | Broadcast immediate | ✅ SVE | ascii_sve2_opt.s |
| `ZIP1 Zd.B, Zn.B, Zm.B` | Interleave | ✅ SVE | ascii_sve2_opt.s |

### NOT Available in SVE (SVE2 only)
| Instruction | Purpose | SVE2 only |
|-------------|---------|-----------|
| `MATCH Pd.B, Pg/Z, Zn.B, Zm.B` | Element-in-set match | ❌ SVE2 only |

---

## Filtering Strategy: Without MATCH

Since MATCH is SVE2-only, we must use CMPEQ like NEON does, but with SVE's advantages.

### NEON 2-byte filtering (per 16B vector):
```asm
VAND  V_data, V_mask, V_masked    // Apply case-fold mask
VCMEQ V_masked, V_target, V_match // Compare to target
```
4 instructions for 2 rare bytes + 1 AND = 5 per vector

### SVE 2-byte filtering (per 32B vector):
```asm
// For letters: mask with 0xDF, compare to uppercase
// For non-letters: compare directly
and  z_masked.d, z_data.d, z_mask.d   // Apply case-fold mask (unpredicated)
cmpeq p1.b, p0/z, z_masked.b, z_target.b // Compare - result in predicate!
```
2 instructions for each rare byte + 1 AND = 5 per vector

**Same instruction count per vector, but 2× bytes per vector!**

---

## Implementation Plan

### Phase 1: Setup

```asm
// Get vector length (32 bytes on G3)
rdvl x8, #1                    // R8 = VL = 32

// Compute case variants for rare1
// If letter: mask=0xDF, target=uppercase
// If non-letter: mask=0xFF, target=byte
// (Same scalar logic as NEON)

// Broadcast to SVE vectors
mov z0.b, w_mask1              // z0 = rare1 mask
mov z1.b, w_target1            // z1 = rare1 target
mov z2.b, w_mask2              // z2 = rare2 mask
mov z3.b, w_target2            // z3 = rare2 target

// Verification constants
mov z4.b, #32                  // Case flip constant

// All-true predicate
ptrue p0.b
```

### Phase 2: Main Loop (4×VL = 128 bytes on G3)

```asm
loop_4x:
    // Load 4 vectors at off1 position (128 bytes total)
    ld1b {z8.b}, p0/z, [base, off1]
    add x_tmp, base, VL
    ld1b {z9.b}, p0/z, [x_tmp, off1]
    add x_tmp, x_tmp, VL
    ld1b {z10.b}, p0/z, [x_tmp, off1]
    add x_tmp, x_tmp, VL
    ld1b {z11.b}, p0/z, [x_tmp, off1]

    // Load 4 vectors at off2 position
    ld1b {z12.b}, p0/z, [base, off2]
    ... (similar for z13, z14, z15)

    // Filter rare1: mask + compare
    and z16.d, z8.d, z0.d           // Apply mask
    cmpeq p1.b, p0/z, z16.b, z1.b   // Compare to target -> predicate
    and z17.d, z9.d, z0.d
    cmpeq p2.b, p0/z, z17.b, z1.b
    ... (z10, z11 -> p3, p4)

    // Filter rare2: mask + compare  
    and z16.d, z12.d, z2.d
    cmpeq p5.b, p0/z, z16.b, z3.b
    ... (z13, z14, z15 -> p6, p7, reuse)

    // Combine: AND rare1 and rare2 predicates
    ands p1.b, p0/z, p1.b, p5.b     // Sets flags!
    b.ne found_match_v0
    
    ands p2.b, p0/z, p2.b, p6.b
    b.ne found_match_v1
    
    ... (check all 4 vectors)

    // No matches, advance
    add i, i, 4*VL                  // i += 128 on G3
    sub remaining, remaining, 4*VL
    cmp remaining, 4*VL
    b.ge loop_4x
```

### Phase 3: Position Extraction (BRKB + CNTP)

```asm
found_match_v0:
    // p1 has match predicate, find first match position
    brkb p2.b, p0/z, p1.b           // Break after first true
    cntp x_pos, p0, p2.b            // Count = position of first match
    
    // Total position = i + offset + pos
    add x_candidate, i, x_pos
    
    // Bounds check
    cmp x_candidate, searchLen
    b.gt clear_and_continue
    
    // Verify match...
```

**Savings vs NEON**: 2 instructions vs 4+ (SHRN+FMOVD+RBIT+CLZ)

### Phase 4: Verification (Vectorized Case-Fold Compare)

```asm
verify_loop:
    // Load VL bytes from haystack and needle
    ld1b {z8.b}, p0/z, [hay_ptr]
    ld1b {z9.b}, p0/z, [needle_ptr]

    // Normalize haystack: if 'a'<=c<='z', XOR with 32
    cmphs p2.b, p0/z, z8.b, #97     // >= 'a'
    cmpls p3.b, p0/z, z8.b, #122    // <= 'z'
    and p2.b, p0/z, p2.b, p3.b      // is_letter
    eor z8.b, p2/m, z8.b, z4.b      // Flip case where is_letter

    // Compare with needle
    eor z8.d, z8.d, z9.d            // XOR to find differences
    cmpne p2.b, p0/z, z8.b, #0      // Any differences?
    orrs p2.b, p0/z, p2.b, p2.b     // Set flags
    b.ne mismatch

    // Advance pointers
    add hay_ptr, hay_ptr, VL
    add needle_ptr, needle_ptr, VL
    sub remaining, remaining, VL
    cbnz remaining, verify_loop
```

### Phase 5: Tail Handling (WHILELO)

```asm
tail:
    cbz remaining, not_found
    
    // Generate tail predicate - NO TABLE LOOKUP!
    whilelo p1.b, xzr, remaining    // p1 = [1,1,1,...,0,0,0] for remaining bytes
    
    // Predicated loads
    ld1b {z8.b}, p1/z, [base, off1]
    ld1b {z12.b}, p1/z, [base, off2]
    
    // Filter with governing predicate p1
    and z16.d, z8.d, z0.d
    cmpeq p2.b, p1/z, z16.b, z1.b   // Governed by p1
    and z17.d, z12.d, z2.d
    cmpeq p3.b, p1/z, z17.b, z3.b
    ands p2.b, p1/z, p2.b, p3.b
    b.ne found_match_tail
```

**Savings vs NEON**: No 256-byte tail_mask_table!

---

## Expected Performance

| Metric | NEON (G4) | SVE (G3) | Improvement |
|--------|-----------|----------|-------------|
| Pure scan | 36 GB/s | **~55-60 GB/s** | **50-67%** |
| High-FP | 17 GB/s | **~25-30 GB/s** | **47-76%** |

### Why the improvement:
1. **2× vector width** = half the instructions for same data
2. **BRKB+CNTP** = cleaner position extraction (2 vs 4+ inst)
3. **WHILELO** = no tail mask table (eliminates memory access)
4. **Native predicates** = results go directly to predicates, no syndrome extraction

---

## Implementation Notes

### Encodings to Verify/Reuse from ascii_sve2_opt.s:
Most SVE instructions work on both SVE and SVE2. We can reuse encodings from ascii_sve2_opt.s for:
- `ptrue`, `rdvl`, `ld1b`, `zip1`, `mov z.b`
- `cmphs`, `cmpls`, `and` (predicate), `eor`
- `brkb`, `brka`, `cntp`
- `whilelo`, `cmpne`, `orrs`

### What changes from SVE2-Fast:
- Remove all `MATCH` instructions
- Replace with `AND` + `CMPEQ` pattern (like NEON, but for 32B vectors)
- Everything else (predicates, verification, tail handling) stays the same

### Test Infrastructure:
- Need G3 instance for testing (c7g or similar)
- Cross-compile: `GOOS=linux GOARCH=arm64 go test -c`
- Unit test, fuzz, then benchmark

---

## Files to Create

1. `ascii_sve_g3.s` - SVE assembly for Graviton 3
2. `ascii_sve_g3.go` - Go glue code with runtime detection

## Open Questions

1. Do we have access to a G3 instance for testing?
2. Should we also keep the NEON adaptive as fallback?
3. Priority: SVE-G3 vs other optimizations?
