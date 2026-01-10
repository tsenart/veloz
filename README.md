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

`IndexFold` and `SearchNeedle` use an adaptive NEON implementation combining techniques from [memchr](https://github.com/BurntSushi/memchr) (rare-byte selection) and [Sneller](https://github.com/SnellerInc/sneller) (compare+XOR normalization, tail masking):

- **Rare-byte selection**: Picks the two rarest bytes in the needle (using English frequency table) to minimize false positives
- **Adaptive filtering**: Starts with 1-byte fast path, switches to 2-byte filtering when false positives exceed threshold
- **Compare+XOR normalization**: ~4 NEON instructions instead of table lookups for case folding
- **Tail masking**: No scalar remainder loop - handles tail with SIMD masks

For repeated searches with the same needle, `SearchNeedle` with a precomputed `Needle` avoids the overhead of computing rare bytes and normalizing the needle on each call.

**Full Comparison (Apple M3 Max):**

| Size | strings.Index | IndexFold | SearchNeedle | IndexFold vs Go |
|------|-------------:|----------:|-------------:|----------------:|
| 1KB | 58.8 GB/s | 25.7 GB/s | 43.4 GB/s | 44% |
| 64KB | 81.9 GB/s | 66.2 GB/s | 67.3 GB/s | 81% |
| 1MB | 82.3 GB/s | 68.0 GB/s | 68.1 GB/s | 83% |
| JSON 1KB | 2.7 GB/s | 15.3 GB/s | 19.7 GB/s | **5.7x** |
| JSON 64KB | 3.3 GB/s | 33.2 GB/s | 33.5 GB/s | **10.0x** |
| JSON 1MB | 3.4 GB/s | 33.7 GB/s | 33.8 GB/s | **10.1x** |

**Full Comparison (Graviton 4):**

| Size | strings.Index | IndexFold | SearchNeedle | IndexFold vs Go |
|------|-------------:|----------:|-------------:|----------------:|
| 1KB | 32.0 GB/s | 18.5 GB/s | 25.5 GB/s | 58% |
| 64KB | 42.5 GB/s | 40.1 GB/s | 40.4 GB/s | 94% |
| 1MB | 38.4 GB/s | 36.2 GB/s | 36.2 GB/s | 94% |
| JSON 1KB | 2.3 GB/s | 9.8 GB/s | 11.3 GB/s | **4.2x** |
| JSON 64KB | 2.8 GB/s | 17.8 GB/s | 17.9 GB/s | **6.4x** |
| JSON 1MB | 2.8 GB/s | 17.5 GB/s | 17.5 GB/s | **6.3x** |

**Full Comparison (Graviton 3):**

| Size | strings.Index | IndexFold | SearchNeedle | IndexFold vs Go |
|------|-------------:|----------:|-------------:|----------------:|
| 1KB | 31.4 GB/s | 16.5 GB/s | 24.5 GB/s | 53% |
| 64KB | 37.6 GB/s | 32.7 GB/s | 33.0 GB/s | 87% |
| 1MB | 32.8 GB/s | 29.3 GB/s | 29.2 GB/s | 89% |
| JSON 1KB | 2.2 GB/s | 8.3 GB/s | 9.6 GB/s | **3.8x** |
| JSON 64KB | 2.6 GB/s | 16.7 GB/s | 16.8 GB/s | **6.5x** |
| JSON 1MB | 2.6 GB/s | 15.2 GB/s | 15.0 GB/s | **5.9x** |

Key findings:
- **High false-positive scenarios (JSON)**: IndexFold is **4-10x faster** than Go's case-sensitive strings.Index
- **Large inputs (64KB+)**: IndexFold achieves 81-94% of Go's case-sensitive speed
- **Small inputs (1KB)**: SearchNeedle is ~1.5-1.7x faster than IndexFold due to precomputation overhead
- For large inputs, IndexFold and SearchNeedle have nearly identical performance

The 768B threshold between 32-byte and 128-byte loops was empirically tuned by sweeping thresholds from 512B to 2KB on Graviton 3/4. See [docs/NEON_ADAPTIVE_TECHNIQUES.md](docs/NEON_ADAPTIVE_TECHNIQUES.md#loop-threshold-tuning) for details.

#### When Do Custom Rank Tables Help?

The default `byteRank` table uses English letter frequency. For **JSON logs and traces**, this can be suboptimal:

| Byte | Static Rank | JSON Logs | UUID-Heavy Traces |
|------|-------------|-----------|-------------------|
| `"` (double-quote) | 60 (rare) | **#1** (15%) | **#2** (9.5%) |
| `:` (colon) | 70 (rare) | **#2** (5%) | #13 (2.4%) |
| `0` (zero) | 130 (common) | #4 (4.6%) | **#1** (22%) |
| `{` `}` | 20 (very rare) | #17-18 | #21+ |

**Benchmark: UUID-heavy traces** (168KB corpus, Apple M3 Max):

| Needle | Static | Computed | Speedup |
|--------|-------:|---------:|--------:|
| `"span_id":"0002da12` | 22.1 GB/s | 30.3 GB/s | **1.37x** |
| `"parent_id":"0003c` | 21.2 GB/s | 41.2 GB/s | **1.95x** |

**Algorithm**: `MakeNeedleWithRanks` uses an optimized rare-byte pair selection that balances byte rarity with distance separation. When you provide corpus-computed ranks, the algorithm trusts this frequency data and uses full `rarity × distance` scoring to find optimal filter bytes. This is particularly effective for UUID/trace ID searches where the default English-based table would pick common bytes like `"` as "rare".

**When to use custom rank tables**:
- **Best for**: UUID-heavy trace data, hex dumps, structured logs with predictable patterns
- **Biggest wins**: Long needles with distinctive bytes spread across the pattern
- **Setup cost**: One-time computation of 256-byte frequency table per corpus

**Recommendation for logs/traces databases**:
- Compute byte frequencies once per table/partition (256 bytes of metadata)
- Use `MakeNeedleWithRanks` for 30-95% speedup on UUID/trace ID searches
- The algorithm automatically optimizes for both rarity and byte separation

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
