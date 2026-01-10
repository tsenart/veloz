# veloz

Veloz is a high-performance SIMD-accelerated library for ASCII and UTF-8 string operations in Go. It provides fast validation and case-insensitive string matching, leveraging SIMD instructions on supported architectures for significant performance improvements over standard library implementations.

While amd64 SIMD optimizations are becoming common in the Go ecosystem, arm64 (NEON) support is often overlooked. Veloz focuses on providing first-class SIMD acceleration for arm64, making it ideal for deployment on ARM-based servers like AWS Graviton, Apple Silicon, and other ARM platforms.

Another motivation for veloz is maintainability. Many Go packages rely on hand-rolled assembly for performance-critical code, which is notoriously difficult to maintain, debug, and extend. By writing SIMD implementations in C and transpiling them to Go assembly using [gocc](https://github.com/mhr3/gocc), veloz keeps the source code readable and maintainable while still delivering native performance.

## Features

- High-speed ASCII string validation
- Case-insensitive ASCII string comparison (`EqualFold`)
- Case-insensitive ASCII substring search (`IndexFold`, `SearchNeedle`)
- Precomputed needle search for repeated lookups (`MakeNeedle`, `SearchNeedle`)
- Multi-character search (`IndexAny`, `ContainsAny`) - find any byte from a set
- Fast UTF-8 validation
- SIMD support for amd64 (AVX2, SSE4.1) and arm64 (NEON)
- NEON bitset (TBL2) acceleration for `IndexAny` with unlimited character sets
- Pure Go fallback for other architectures

## Installation

To install the library, use `go get`:

```sh
go get github.com/mhr3/veloz
```

## Usage

### ASCII Operations

The `ascii` package provides functions for validating and searching ASCII strings:

```go
package main

import (
    "fmt"

    "github.com/mhr3/veloz/ascii"
)

func main() {
    // Check if a string contains only ASCII characters
    fmt.Println(ascii.ValidString("Hello, World!"))  // true
    fmt.Println(ascii.ValidString("Hello, 世界!"))   // false

    // Case-insensitive string comparison
    fmt.Println(ascii.EqualFold("Hello", "HELLO"))   // true
    fmt.Println(ascii.EqualFold("Hello", "World"))   // false

    // Case-insensitive substring search
    fmt.Println(ascii.IndexFold("Hello, World!", "WORLD"))  // 7
    fmt.Println(ascii.IndexFold("Hello, World!", "foo"))    // -1

    // Precomputed needle for repeated searches (1.7x faster for rare-byte needles)
    needle := ascii.MakeNeedle("lazy")
    fmt.Println(ascii.SearchNeedle("the quick brown fox jumps over the lazy dog", needle))  // 35

    // Custom rank table for specialized corpora (DNA, hex dumps, etc.)
    dnaRanks := make([]byte, 256)
    for i := range dnaRanks { dnaRanks[i] = 255 }  // all rare by default
    for _, c := range "ACGT" { dnaRanks[c] = 128 } // A,C,G,T equally common
    dnaRanks['N'] = 64  // N is rarer
    dnaRanks['X'] = 32  // X is very rare
    dnaPattern := ascii.MakeNeedleWithRanks("GATTACA", dnaRanks)
    _ = dnaPattern

    // Find first occurrence of any character from a set
    fmt.Println(ascii.IndexAny("hello world", " \t\n"))     // 5 (space)
    fmt.Println(ascii.ContainsAny("hello", "aeiou"))        // true
}
```

### UTF-8 Validation

The `utf8` package provides fast UTF-8 string validation:

```go
package main

import (
    "fmt"

    "github.com/mhr3/veloz/utf8"
)

func main() {
    // Validate UTF-8 strings
    fmt.Println(utf8.ValidString("Hello, 世界!"))           // true
    fmt.Println(utf8.ValidString("Valid UTF-8 string"))    // true
    fmt.Println(utf8.ValidString(string([]byte{0xff})))    // false (invalid UTF-8)
}
```

## Benchmarks

| Function           | CPU        | naive (MB/s) | veloz (MB/s) | Speedup |
|--------------------|------------|--------------|--------------|---------|
| ascii.ValidString  | Graviton 2 | 4,903        | 33,684       | 6.9x    |
| ascii.EqualFold    | Graviton 2 |   879        | 7,566        | 8.6x    |
| ascii.IndexFold    | Graviton 2 | 2,652        | 7,947        | 3.0x    |
| utf8.ValidString   | Graviton 2 |   618        | 3,090        | 5.0x    |
| ascii.ValidString  | Apple M2   | 12,256       | 89,227       | 7.3x    |
| ascii.EqualFold    | Apple M2   | 2,336        | 21,254       | 9.1x    |
| ascii.IndexFold    | Apple M2   | 7,117        | 29,046       | 4.1x    |
| utf8.ValidString   | Apple M2   | 1,673        | 10,014       | 6.0x    |

### IndexAny Performance

The `IndexAny` and `ContainsAny` functions use a NEON bitset approach (TBL2+TBL1 table lookups) that supports **unlimited character sets** with consistent performance.

**Throughput on Apple M3 Max:**

| Chars | Go (GB/s) | NEON bitset (GB/s) | Speedup |
|------:|----------:|-------------------:|--------:|
|     1 |       2.4 |               25.5 |   10.8x |
|    16 |       2.2 |               25.9 |   11.6x |
|    64 |       1.9 |               25.8 |   13.8x |

*The NEON bitset uses ARM's TBL2 instruction for 32-byte table lookups, which is heavily optimized for cryptographic operations.*

### SearchNeedle Performance

For repeated case-insensitive searches with the same needle, `SearchNeedle` with a precomputed `Needle` is faster than `IndexFold`. It uses an adaptive NEON implementation that combines techniques from [memchr](https://github.com/BurntSushi/memchr) (rare-byte selection) and [Sneller](https://github.com/SnellerInc/sneller) (compare+XOR normalization, tail masking):

- **Rare-byte selection**: Picks the two rarest bytes in the needle (using English frequency table) to minimize false positives
- **Adaptive filtering**: Starts with 1-byte fast path (~29 GB/s pure scan), switches to 2-byte filtering when false positives exceed threshold
- **Compare+XOR normalization**: ~4 NEON instructions instead of table lookups for case folding
- **Tail masking**: No scalar remainder loop - handles tail with SIMD masks

**Throughput (Graviton 4, vs case-sensitive strings.Index):**

| Scenario | NEON | Go strings.Index | Ratio |
|----------|-----:|----------------:|------:|
| Pure scan 1KB (letter) | 33.6 GB/s | 35.5 GB/s | 95% |
| Pure scan 64KB (letter) | 40.6 GB/s | 42.5 GB/s | 96% |
| Pure scan 1MB (letter) | 36.8 GB/s | 40.6 GB/s | 91% |
| Pure scan 16MB (letter) | 25.2 GB/s | 26.3 GB/s | 96% |
| Match at end 1KB | 26.0 GB/s | 32.1 GB/s | 81% |
| Match at end 64KB | 40.5 GB/s | 42.4 GB/s | 95% |
| Match at end 1MB | 36.2 GB/s | 39.9 GB/s | 91% |
| High FP JSON 2KB | 14.4 GB/s | 2.5 GB/s | **5.6x** |
| High FP JSON 64KB | 17.9 GB/s | 2.8 GB/s | **6.4x** |
| High FP JSON 1MB | 17.4 GB/s | 2.7 GB/s | **6.4x** |
| Non-letter pure scan 1KB | 34.8 GB/s | 35.6 GB/s | 98% |
| Non-letter pure scan 64KB | 40.9 GB/s | 42.5 GB/s | 96% |
| Non-letter pure scan 1MB | 30.9 GB/s | 39.6 GB/s | 78% |
| Non-letter match end 1KB | 29.7 GB/s | 31.7 GB/s | 94% |
| Non-letter match end 64KB | 40.9 GB/s | 42.4 GB/s | 96% |
| Non-letter match end 1MB | 31.0 GB/s | 39.8 GB/s | 78% |

**Throughput (Apple M3 Max, vs case-sensitive strings.Index):**

| Scenario | NEON | Go strings.Index | Ratio |
|----------|-----:|----------------:|------:|
| Pure scan 1KB (letter) | 55.3 GB/s | 66.3 GB/s | 83% |
| Pure scan 64KB (letter) | 67.9 GB/s | 82.7 GB/s | 82% |
| Pure scan 1MB (letter) | 68.5 GB/s | 83.3 GB/s | 82% |
| Pure scan 16MB (letter) | 67.2 GB/s | 81.5 GB/s | 82% |
| Match at end 1KB | 43.4 GB/s | 58.6 GB/s | 74% |
| Match at end 64KB | 67.6 GB/s | 81.3 GB/s | 83% |
| Match at end 1MB | 68.4 GB/s | 82.5 GB/s | 83% |
| High FP JSON 2KB | 26.4 GB/s | 3.0 GB/s | **8.9x** |
| High FP JSON 64KB | 33.4 GB/s | 3.4 GB/s | **9.9x** |
| High FP JSON 1MB | 33.7 GB/s | 3.4 GB/s | **10.1x** |
| Non-letter pure scan 1KB | 75.8 GB/s | 68.9 GB/s | **110%** |
| Non-letter pure scan 64KB | 96.9 GB/s | 82.6 GB/s | **117%** |
| Non-letter pure scan 1MB | 89.5 GB/s | 82.8 GB/s | **108%** |
| Non-letter match end 1KB | 57.9 GB/s | 57.8 GB/s | 100% |
| Non-letter match end 64KB | 92.9 GB/s | 80.9 GB/s | **115%** |
| Non-letter match end 1MB | 86.1 GB/s | 80.5 GB/s | **107%** |

**Throughput (Graviton 3, vs case-sensitive strings.Index):**

| Scenario | NEON | Go strings.Index | Ratio |
|----------|-----:|----------------:|------:|
| Pure scan 1KB (letter) | 32.1 GB/s | 32.3 GB/s | 99% |
| Pure scan 64KB (letter) | 33.0 GB/s | 37.5 GB/s | 88% |
| Pure scan 1MB (letter) | 29.7 GB/s | 32.6 GB/s | 91% |
| Pure scan 16MB (letter) | 26.8 GB/s | 30.1 GB/s | 89% |
| Match at end 1KB | 23.4 GB/s | 31.6 GB/s | 74% |
| Match at end 64KB | 33.0 GB/s | 37.6 GB/s | 88% |
| Match at end 1MB | 29.6 GB/s | 32.5 GB/s | 91% |
| High FP JSON 2KB | 12.4 GB/s | 2.3 GB/s | **5.3x** |
| High FP JSON 64KB | 16.8 GB/s | 2.6 GB/s | **6.5x** |
| High FP JSON 1MB | 15.1 GB/s | 2.6 GB/s | **5.8x** |
| Non-letter pure scan 1KB | 37.1 GB/s | 32.3 GB/s | **115%** |
| Non-letter pure scan 64KB | 43.3 GB/s | 37.5 GB/s | **115%** |
| Non-letter pure scan 1MB | 34.6 GB/s | 32.8 GB/s | **105%** |
| Non-letter match end 1KB | 30.0 GB/s | 31.7 GB/s | 95% |
| Non-letter match end 64KB | 43.1 GB/s | 37.4 GB/s | **115%** |
| Non-letter match end 1MB | 34.2 GB/s | 32.4 GB/s | **106%** |

The 768B threshold between 32-byte and 128-byte loops was empirically tuned by sweeping thresholds from 512B to 2KB on Graviton 3/4. See [docs/NEON_ADAPTIVE_TECHNIQUES.md](docs/NEON_ADAPTIVE_TECHNIQUES.md#loop-threshold-tuning) for details.

*The NEON implementation excels when the haystack has many false-positive candidates (e.g., JSON with many quote characters), achieving 5-10x speedups. In pure scan scenarios, it achieves 74-99% of Go's case-sensitive strings.Index speed while providing case-insensitive matching. Non-letter needles (digits, punctuation) use a VAND-free fast path that often exceeds Go's case-sensitive performance (up to 117%).*

#### Needle Reuse Across Many Haystacks

When searching for the same needle across many strings (e.g., log search, database queries), `MakeNeedle` cost is fully amortized:

| Benchmark | 1K haystacks | 1M haystacks |
|-----------|-------------:|-------------:|
| IndexFold | 6.1 GB/s | 6.6 GB/s |
| SearchNeedle (reused) | 7.5 GB/s | 8.1 GB/s |
| **Speedup** | **1.22x** | **1.23x** |

#### When Do Custom Rank Tables Help?

The default `byteRank` table uses English letter frequency. For **JSON logs and traces**, this can be suboptimal:

| Byte | Static Rank | JSON Logs | UUID-Heavy Traces |
|------|-------------|-----------|-------------------|
| `"` (double-quote) | 60 (rare) | **#1** (15%) | **#2** (9.5%) |
| `:` (colon) | 70 (rare) | **#2** (5%) | #13 (2.4%) |
| `0` (zero) | 130 (common) | #4 (4.6%) | **#1** (22%) |
| `{` `}` | 20 (very rare) | #17-18 | #21+ |

**Benchmark: JSON logs** (72KB corpus):

| Needle | Static | Computed | Speedup |
|--------|-------:|---------:|--------:|
| `"status":200` | 6.4 GB/s | 7.7 GB/s | **1.20x** |
| `"user_id":` | 5.3 GB/s | 5.8 GB/s | **1.09x** |

**Benchmark: UUID-heavy traces** (168KB corpus):

| Needle | Static | Computed | Speedup | Why |
|--------|-------:|---------:|--------:|-----|
| `"parent_id":"0003c` | 19.6 GB/s | 20.9 GB/s | **1.07x** | Static picks `"` (9.5% of corpus), computed picks `N` (1.2%) |
| `"span_id":"0002da12` | 15.3 GB/s | 16.1 GB/s | **1.05x** | 16x fewer false positives with `S` vs `"` |

**Key insight**: When the static table picks `"` as "rare", it checks 16x more candidate positions than necessary. The SIMD verification is fast, so the speedup is 5-20% rather than 16x - but it adds up.

**Recommendation for logs/traces databases**:
- Compute byte frequencies once per table/partition (256 bytes of metadata)
- Use `MakeNeedleWithRanks` for 5-20% speedup on JSON key/UUID searches
- Biggest wins: needles containing `"`, `:`, or `0` in JSON/trace data

```go
// Build rank table from corpus (do once, store with data)
var counts [256]int
for i := 0; i < len(corpus); i++ {
    c := corpus[i]
    if c >= 'a' && c <= 'z' { c -= 0x20 }  // case-fold
    counts[c]++
}
maxCount := slices.Max(counts[:])
ranks := make([]byte, 256)
for i, c := range counts {
    ranks[i] = byte(c * 255 / maxCount)
}

// Use for searches
needle := ascii.MakeNeedleWithRanks(`"trace_id":"abc123`, ranks)
```
