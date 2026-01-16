## Biggest wins

### 2) Stop loading the 2nd stream when `off2_delta` overlaps the first stream

Your 2‑byte kernels are the biggest bandwidth sink: they read the haystack twice (`ptr1` and `ptr2=ptr1+delta`), even when the windows overlap heavily (common when `delta` is small, which happens for short needles and for “rare bytes” chosen close together).

Implement a **small‑delta path** that derives `ptr2` vectors from `ptr1` vectors using `EXT` (and/or pure register reuse for `delta` multiple-of-16), so you only touch memory once.

#### Concrete plan (works for `indexExact2Byte`, `indexFold2Byte`, `indexFold2ByteRaw`)

Split `off2_delta` into:

- `q = off2_delta >> 4` (whole vectors)
- `r = off2_delta & 15` (byte shift within vector)

For a 64‑byte block, load **(4 + q + 1)** vectors from `ptr1` (one extra “next” vector for the final `EXT`). Then for each 16‑byte chunk `i` in 0..3:

- Base vectors are `V[i+q]` and `V[i+q+1]`
- `ptr2_chunk_i = EXT V[i+q], V[i+q+1], #r` when `r != 0`
- If `r == 0`, `ptr2_chunk_i = V[i+q]` (zero permute cost)

Then compare rare2 against `ptr2_chunk_i` and AND with rare1 compares.

Gate this path on `off2_delta < 64` for the 64‑byte loop and `off2_delta < 128` for the 128‑byte loop. Fall back to your current dual-stream loads for larger deltas.

This is the single highest-impact change because it attacks the only place you’re knowingly doing redundant memory traffic.

---

## Hot-loop throughput improvements

### 3) Lower the 128‑byte loop thresholds in `indexExact1Byte` and `indexExact2Byte`

You currently switch to 128B only when `remaining >= 2048`. That leaves a lot of medium input (128–2047 bytes) stuck on the 64B loop.

Bring the threshold down to match what you already do in fold kernels (`768`), or at least `1024`.

This is free perf on medium sizes: fewer branches per byte and better amortization of loop overhead.

---

### 4) Add a 64‑byte loop to the fold1/raw1 kernels (they jump 32 → 128)

`indexFold1Byte` / `indexFold1ByteRaw` currently do 32B for the entire 32..767 window.

Add a 64B loop (mirroring your exact1 `loop64`) for `remaining >= 64 && <128B-threshold`. This halves loop overhead and reduces branch frequency in a range that shows up constantly in real workloads (small strings, log lines, HTTP headers).

Do it for both letter and non‑letter scan paths.

---

### 5) Add a 128‑byte loop to fold2/raw2 (they stop at 64)

`indexFold2Byte` and `indexFold2ByteRaw` top out at 64B. For large haystacks this is avoidable loop overhead.

Implement the same 128B structure you have in exact2, and combine it with the **small‑delta single-stream** trick above.

---

## Register / instruction stream cleanup that buys real cycles

### 6) Use destructive compares in the scan loops (overwrite the loaded vectors)

In the scan stage you never reuse the loaded bytes after `VCMEQ`. Keep fewer live vector regs and delete move chains in the match path.

Example pattern (exact1 64B loop):

Current:

- load `V1..V4`
- compare into `V16..V19`

Better:

- load `V1..V4`
- `VCMEQ …, V1, V1` (overwrite)
- `VCMEQ …, V2, V2`
- …

Same for the 128B loop: overwrite `V1..V4` and `V24..V27` (or whatever your load regs are) with compare results. Then:

- syndrome extraction reads directly from those regs
- you remove the 4× `VMOV` block in the “second64” path (`second64_exact1/2`) entirely by not shuffling registers to “unify processing”.

This reduces register pressure and removes vector moves on the match path, and it makes deeper unrolling/pipelining feasible later.

---

### 7) Stop recomputing half-block OR reductions after a match in 128B loops

In your 128B loops you build the full `OR` tree, reduce to `R15`, then if `R15 != 0` you **recompute** OR+reduce for first 64 and second 64.

Keep `OR(first64)` and `OR(second64)` around from the first tree build:

- compute `Vfirst = OR(V0..V3)` and `Vsecond = OR(V4..V7)`
- compute `Vall = OR(Vfirst, Vsecond)` and reduce once for the loop continuation check
- on the match path, reduce `Vfirst` first; only if zero reduce `Vsecond`

Net: remove ~6 `VORR` per taken-match path.

This matters on pathological needles (common byte) where match paths are hot.

---

### 8) Remove byte-by-byte scalar verification; reuse the NEON verify path everywhere

Your scan tail scalar loop (`scalar_exact1` / `scalar_exact2`) does byte-by-byte full verification. That is catastrophically slow if the needle is long and the candidate survives to verify (even if that’s “rare”, it becomes hot in worst-cases).

Replace scalar verify with the same NEON verify loop you already use (`VLD1.P` + `VEOR` + `UMAXV/UMAXP` + tail mask). It’s safe because you already checked `candidatePos <= searchLen`, so the candidate has `needle_len` bytes available.

Keep scalar only for scanning the last <16 search positions, not for verifying.

---

## Fold verification is doing unnecessary work

### 9) In fold verification, base the OR-mask on the needle bytes — stop detecting letters in the haystack

For ASCII fold with a **pre-normalized needle** (your `indexFold1Byte` / `indexFold2Byte`), you do expensive letter detection on **haystack** every 16 bytes:

- build `(h|0x20)`
- range check to decide if letter
- selectively OR 0x20

You don’t need haystack letter detection at all.

Key property: for ASCII, `(x | 0x20)` only maps uppercase letters to lowercase; it cannot turn a non-letter into a lowercase letter. Therefore:

- When the needle byte is a lowercase letter, OR’ing 0x20 into the haystack byte is always safe.
- When the needle byte is not a letter, you must not OR.

So the per-byte OR mask depends on the needle byte only.

#### Minimal rewrite (no extra precomputed mask)

Per 16B chunk:

- load `Vh` and `Vn` (needle is already normalized)
- compute `needle_is_letter` via `(Vn + 159) < 26` (same trick you already use, just on `Vn`)
- `Vmask = needle_is_letter & 0x20`
- `Vh = Vh | Vmask`
- `diff = Vh XOR Vn`
- reduce `diff`

This deletes the initial `VORR 0x20` and shifts work from haystack-dependent to needle-dependent.

#### Bigger rewrite (faster for long needles / many verifies)

Precompute a per-byte `foldMask` array for the needle once (0x20 where needle byte is letter, 0x00 otherwise). Then verify per 16B chunk is:

- load `Vh`, `Vn`, `Vm` (mask)
- `Vh |= Vm`
- `diff = Vh XOR Vn`
- reduce

This replaces 3 ALU ops (`VADD`+`VCMHI`+`VAND`) with one extra load. For worst-cases with many candidate verifies, it wins.

Do **not** apply this to the Raw-fold variants; they need real dual-normalize logic.

---

### 10) In fold2/raw2 scan loops, dispatch on masks to avoid redundant VORR

Fold2/raw2 always do:

- `VORR mask1, …` even when `mask1==0`
- `VORR mask2, …` even when `mask2==0`

Split into 4 scan variants decided once in setup:

- `mask1=0, mask2=0` → call/use exact2 kernel (no folding at all)
- `mask1=0, mask2=0x20` → fold only stream2
- `mask1=0x20, mask2=0` → fold only stream1
- both 0x20 → current path

This removes 4–8 vector ops per 64B iteration when masks are zero (common in binary/non-text data and for punctuation-heavy needles).

---

## Microarchitecture-facing improvements (they matter once the above is done)

### 11) Add prefetch in the long scan loops

For truly large scans (MB-scale), you’re latency/bandwidth bound.

Insert prefetches in 128B loops:

- `PRFM PLDL1KEEP, [ptr, #256]` (or #512; tune)
- For dual-stream 2-byte fallback path, prefetch both pointers.

Prefer `PLDL1STRM` if the haystack is truly streaming and you don’t want to pollute cache, but keep it behind a size threshold so you don’t hurt mid-sized inputs.

---

### 12) Align hot loop entry points

Use `PCALIGN $32` (or $64) immediately before:

- `loop128_*`
- `loop64_*`
- the primary verify loops if they’re hit often in your workload

Then reorder labels so the hot scan loop body is contiguous and the cold match/verify/tail code is out-of-line later in the function. This reduces I‑cache misses and BTB noise.

Given the sheer size of `indexFold1Byte` / `Raw` variants, code layout is not optional; it’s perf.

---

### 13) Optional: add an ASIMDDP (dot-product) fast path for mask extraction

If you want to reduce the “syndrome extraction” cost when matches are frequent, implement a dot-product movemask:

- shift compare mask to 0/1 bytes
- `UDOT` with a constant weight vector to pack bits quickly

Gate it on `arm64` dotprod feature and keep the existing path as baseline.

This is only worth it after fixing the big-ticket items above, and only for workloads with high candidate rates.

---

## Summary of changes that pay off immediately

1. ABIInternal everywhere (no wrappers).
2. 2-byte kernels: single-stream small-delta path using `EXT`/register reuse.
3. Lower exact 128B thresholds; add missing 64B/128B loops in fold variants.
4. Destructive compares; delete match-path `VMOV` shuffles.
5. Kill scalar byte-by-byte verify; always NEON-verify.
6. Fold verify: OR mask derived from needle bytes (or precomputed mask), not haystack letter detection.
