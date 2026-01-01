# veloz

Veloz is a high-performance SIMD-accelerated library for ASCII and UTF-8 string operations in Go. It provides fast validation and case-insensitive string matching, leveraging SIMD instructions on supported architectures for significant performance improvements over standard library implementations.

While amd64 SIMD optimizations are becoming common in the Go ecosystem, arm64 (NEON) support is often overlooked. Veloz focuses on providing first-class SIMD acceleration for arm64, making it ideal for deployment on ARM-based servers like AWS Graviton, Apple Silicon, and other ARM platforms.

The SIMD implementations are written in C and transpiled to Go assembly using [gocc](https://github.com/mhr3/gocc).

## Features

- High-speed ASCII string validation
- Case-insensitive ASCII string comparison (`EqualFold`)
- Case-insensitive ASCII substring search (`IndexFold`)
- Fast UTF-8 validation
- SIMD support for amd64 (AVX2, SSE4.1) and arm64 (NEON)
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
