# CGO IndexFoldMemchr Optimization Notes

## Current Status

The CGO implementation achieves **97% of handwritten ASM throughput** at 1MB while maintaining a $0 stack frame (NOSPLIT).

| Size | CGO Memchr | ASM | Ratio |
|------|-----------|-----|-------|
| 15B | 2.79 GB/s | 3.97 GB/s | 70% |
| 44B | 23.1 GB/s | 23.3 GB/s | 99% ✓ |
| 100B | 17.7 GB/s | 22.0 GB/s | 81% |
| 1000B | 32.2 GB/s | 24.5 GB/s | 131% ✓ |
| 1MB | 72.7 GB/s | 74.7 GB/s | 97% ✓ |

## Cut Corners / Missing Optimizations

### 1. No 2-Byte Rare Character Mode

**ASM behavior**: Uses both `rare1` and `rare2` to filter candidates. When a position matches `rare1` at `off1`, it also checks if `rare2` matches at `off2`. This dramatically reduces false positives for needles like `"num"` in JSON data where `"` is common but the combination `"n` is rare.

**CGO behavior**: Ignores `rare2` and `off2` parameters entirely. Only uses single-byte filtering.

**Impact**: Pathological cases with many false positives (e.g., searching for `"num"` in JSON with many `"` characters) will be slower.

**Fix complexity**: Medium. Need to add 2-byte comparison in the main loop and separate verification path.

### 2. No Threshold-Based Loop Switching

**ASM behavior**: Uses a 768-byte threshold:
- Small inputs (<768B): 32-byte tight loop for better CPU speculation overlap
- Large inputs (≥768B): 128-byte loop for lower per-byte overhead

**CGO behavior**: Sequential fallthrough: 128→64→32→16→scalar. Small inputs that hit the 128-byte check and fail waste cycles.

**Impact**: Small-to-medium inputs (100-500 bytes) may have suboptimal loop selection.

**Fix complexity**: Low. Add a size check at function entry to dispatch to appropriate loop.

### 3. No Non-Letter Fast Path

**ASM behavior**: Checks if `rare1` is a non-letter (digits, punctuation). If so, skips the `VORR` case-folding instruction since non-letters don't need case normalization. This saves ~1 vector op per 16 bytes.

**CGO behavior**: Always applies case-folding mask (`vorrq_u8(v, v_mask)`) even when mask is 0x00.

**Impact**: ~5-10% slower for non-letter needles like `"12345"` or `"{"key"`.

**Fix complexity**: Low. Add `if (rare1_mask == 0)` branch with simpler comparison loop.

### 4. Duplicated Syndrome Extraction Code

**ASM behavior**: Uses a single shared verification routine accessed via `B` (branch) instruction. All 8 chunks in the 128-byte loop jump to the same verify code.

**CGO behavior**: Syndrome extraction and verification code is duplicated 8 times in the 128-byte loop and 4 times in the 64-byte loop. Total ~12 copies.

**Impact**: Binary bloat (~2KB extra code). May affect instruction cache efficiency for very hot loops.

**Fix complexity**: Hard. C doesn't support computed gotos that map well to Go assembly. Inline functions get duplicated by the compiler. Would need manual assembly or accept the bloat.

### 5. Suboptimal Small Input Performance

**ASM behavior**: Has optimized 16-byte loop with minimal overhead for inputs <32 bytes.

**CGO behavior**: Falls through multiple loop conditions (128, 64, 32, 16) before finding the right loop size, wasting cycles on condition checks.

**Impact**: 15B case is 70% of ASM, 100B case is 81%.

**Fix complexity**: Low. Add early dispatch based on `haystack_len` to jump directly to appropriate loop.

## Constraints Discovered

1. **gocc cannot handle `noinline` functions**: Generates broken `bl` instructions. All helpers must use `always_inline`.

2. **Function pointers prevent inlining**: Even with `always_inline` on the target, calling through a function pointer defeats inlining.

3. **Register pressure threshold**: ~8 live vector registers is the maximum before spilling occurs. The 128-byte loop works by processing in two 64-byte halves.

4. **`goto` labels cause spilling**: Adding `goto small_input` with a label in the middle of the function caused $64 stack allocation, even though the code paths didn't overlap.

## Build Command

```bash
CC=/opt/homebrew/opt/llvm/bin/clang gocc -l -a arm64 -O3 -o . csrc/ascii_neon_memchr.c
```

## Verification

```bash
# Check stack frame size (should be $0)
grep "TEXT" ascii_neon_memchr.s

# Run tests
go test -run="TestContainsFold|TestSearcher" -timeout=30s

# Run benchmarks
go test -bench="BenchmarkMemchr" -benchtime=1s -run='^$'
```
