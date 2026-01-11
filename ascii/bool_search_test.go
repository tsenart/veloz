//go:build !noasm && arm64

package ascii

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
)

// =============================================================================
// Reference Implementation for Testing
// =============================================================================

// boolSearchReference is a naive reference implementation for correctness testing.
// It evaluates the boolean expression by doing individual case-insensitive searches.
func boolSearchReference(haystack string, expr BoolExpr) bool {
	return evalExprReference(haystack, expr)
}

func evalExprReference(haystack string, expr BoolExpr) bool {
	switch e := expr.(type) {
	case *ContainsExpr:
		return IndexFold(haystack, e.Pattern) != -1
	case *AndExpr:
		return evalExprReference(haystack, e.Left) && evalExprReference(haystack, e.Right)
	case *OrExpr:
		return evalExprReference(haystack, e.Left) || evalExprReference(haystack, e.Right)
	case *NotExpr:
		return !evalExprReference(haystack, e.Child)
	default:
		panic("unknown expression type")
	}
}

// =============================================================================
// Unit Tests
// =============================================================================

func TestBoolSearchBasic(t *testing.T) {
	tests := []struct {
		name     string
		haystack string
		expr     BoolExpr
		want     bool
	}{
		// Single pattern tests
		{"single_match", "hello world", Contains("world"), true},
		{"single_no_match", "hello world", Contains("xyz"), false},
		{"single_case_insensitive", "Hello World", Contains("WORLD"), true},
		{"single_empty_haystack", "", Contains("abc"), false},

		// AND tests
		{"and_both_match", "hello world", And(Contains("hello"), Contains("world")), true},
		{"and_first_only", "hello there", And(Contains("hello"), Contains("world")), false},
		{"and_second_only", "goodbye world", And(Contains("hello"), Contains("world")), false},
		{"and_neither", "goodbye there", And(Contains("hello"), Contains("world")), false},

		// OR tests
		{"or_both_match", "hello world", Or(Contains("hello"), Contains("world")), true},
		{"or_first_only", "hello there", Or(Contains("hello"), Contains("world")), true},
		{"or_second_only", "goodbye world", Or(Contains("hello"), Contains("world")), true},
		{"or_neither", "goodbye there", Or(Contains("hello"), Contains("world")), false},

		// NOT tests
		{"not_present", "hello world", Not(Contains("xyz")), true},
		{"not_absent", "hello world", Not(Contains("hello")), false},

		// Complex expressions
		{"complex_and_or", "hello world",
			Or(And(Contains("hello"), Contains("world")), Contains("foo")), true},
		{"complex_not_and", "hello world",
			And(Contains("hello"), Not(Contains("xyz"))), true},
		{"complex_nested", "the quick brown fox",
			And(Or(Contains("quick"), Contains("slow")), Not(Contains("lazy"))), true},

		// Case insensitivity
		{"case_mixed", "The QUICK Brown FOX",
			And(Contains("quick"), Contains("fox")), true},

		// Edge cases
		{"single_char_pattern", "abcdefgh", Contains("e"), true},
		{"pattern_at_start", "hello world", Contains("hello"), true},
		{"pattern_at_end", "hello world", Contains("world"), true},
		{"overlapping_patterns", "abcabc", And(Contains("abc"), Contains("cab")), true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bs := MakeBooleanSearch(tt.expr)
			got := bs.Match(tt.haystack)
			if got != tt.want {
				t.Errorf("BooleanSearch.Match(%q) = %v, want %v", tt.haystack, got, tt.want)
			}

			// Verify against reference implementation
			ref := boolSearchReference(tt.haystack, tt.expr)
			if got != ref {
				t.Errorf("BooleanSearch.Match(%q) = %v, reference = %v", tt.haystack, got, ref)
			}
		})
	}
}

func TestBoolSearchPatternCounts(t *testing.T) {
	// Test different pattern counts to exercise both Direct TBL (1-8) and FDR (9-64) engines
	patternCounts := []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 32, 64}

	for _, n := range patternCounts {
		t.Run(fmt.Sprintf("%d_patterns", n), func(t *testing.T) {
			// Create patterns: "pat0", "pat1", ..., "patN-1"
			patterns := make([]string, n)
			for i := 0; i < n; i++ {
				patterns[i] = fmt.Sprintf("pat%d", i)
			}

			// Create OR expression of all patterns
			var expr BoolExpr = Contains(patterns[0])
			for i := 1; i < n; i++ {
				expr = Or(expr, Contains(patterns[i]))
			}

			bs := MakeBooleanSearch(expr)

			// Test: haystack contains pattern in middle
			for i := 0; i < n; i++ {
				haystack := "xxxx" + patterns[i] + "xxxx"
				if !bs.Match(haystack) {
					t.Errorf("Expected match for pattern %d in haystack %q", i, haystack)
				}
			}

			// Test: haystack contains no patterns
			haystack := "this haystack has no matching patterns"
			if bs.Match(haystack) {
				t.Errorf("Expected no match for haystack %q", haystack)
			}
		})
	}
}

func TestBoolSearchMixedCaseSensitivity(t *testing.T) {
	tests := []struct {
		name     string
		haystack string
		expr     BoolExpr
		want     bool
	}{
		// Case-sensitive patterns (when we add support)
		{"ci_match", "Hello World", ContainsCI("HELLO"), true},
		{"ci_no_match", "Hello World", ContainsCI("xyz"), false},

		// Mixed sensitivity in same expression
		{"mixed_both", "Hello World",
			And(ContainsCI("hello"), ContainsCI("world")), true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bs := MakeBooleanSearch(tt.expr)
			got := bs.Match(tt.haystack)
			if got != tt.want {
				t.Errorf("BooleanSearch.Match(%q) = %v, want %v", tt.haystack, got, tt.want)
			}
		})
	}
}

func TestBoolSearchImmediateMasks(t *testing.T) {
	// Test early termination via immediate masks

	t.Run("immediate_true_or", func(t *testing.T) {
		// A OR B OR C: finding any pattern should immediately return true
		expr := Or(Or(Contains("alpha"), Contains("beta")), Contains("gamma"))
		bs := MakeBooleanSearch(expr)

		// Should find "alpha" early and return immediately
		haystack := "alpha" + strings.Repeat("x", 10000)
		if !bs.Match(haystack) {
			t.Error("Expected immediate true for OR expression")
		}
	})

	t.Run("immediate_false_not", func(t *testing.T) {
		// NOT(A) AND NOT(B): finding any pattern should immediately return false
		expr := And(Not(Contains("alpha")), Not(Contains("beta")))
		bs := MakeBooleanSearch(expr)

		// Should find "alpha" early and return false immediately
		haystack := "alpha" + strings.Repeat("x", 10000)
		if bs.Match(haystack) {
			t.Error("Expected immediate false for NOT expression")
		}
	})
}

func TestBoolSearchEdgeCases(t *testing.T) {
	tests := []struct {
		name     string
		haystack string
		expr     BoolExpr
		want     bool
	}{
		// Empty haystack
		{"empty_haystack", "", Contains("abc"), false},
		{"empty_haystack_not", "", Not(Contains("abc")), true},

		// Single byte patterns
		{"single_byte", "abcdef", Contains("c"), true},
		{"single_byte_not_found", "abcdef", Contains("z"), false},

		// Very long patterns
		{"long_pattern", strings.Repeat("ab", 100), Contains(strings.Repeat("ab", 50)), true},
		{"long_pattern_no_match", strings.Repeat("ab", 100), Contains(strings.Repeat("cd", 50)), false},

		// Pattern at boundaries
		{"at_start", "pattern_here", Contains("pattern"), true},
		{"at_end", "here_pattern", Contains("pattern"), true},
		{"exact_match", "pattern", Contains("pattern"), true},

		// Overlapping content
		{"overlap", "ababab", Contains("bab"), true},

		// High-bit bytes (non-ASCII)
		{"high_bit", "hello\x80world", Contains("world"), true},
		{"high_bit_pattern", "hello\x80world", Contains("\x80"), true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bs := MakeBooleanSearch(tt.expr)
			got := bs.Match(tt.haystack)
			if got != tt.want {
				t.Errorf("BooleanSearch.Match(%q) = %v, want %v", tt.haystack, got, tt.want)
			}
		})
	}
}

func TestBoolSearchFloodDetection(t *testing.T) {
	// Test adversarial inputs that would cause excessive false positives

	t.Run("all_same_char", func(t *testing.T) {
		haystack := strings.Repeat("a", 10000) + "xyz"
		expr := Contains("xyz")
		bs := MakeBooleanSearch(expr)

		if !bs.Match(haystack) {
			t.Error("Expected match at end of flood")
		}
	})

	t.Run("repeated_pattern", func(t *testing.T) {
		haystack := strings.Repeat("ab", 5000) + "xyz"
		expr := Contains("xyz")
		bs := MakeBooleanSearch(expr)

		if !bs.Match(haystack) {
			t.Error("Expected match at end of repeated pattern")
		}
	})
}

// =============================================================================
// Fuzz Tests
// =============================================================================

func FuzzBoolSearchSinglePattern(f *testing.F) {
	// Seeds
	f.Add("hello world", "world")
	f.Add("The Quick Brown Fox", "quick")
	f.Add(strings.Repeat("a", 100), "aaa")
	f.Add("xylophone", "xy")
	f.Add("", "abc")
	f.Add("abc", "")
	f.Add("\x80ABC", "abc")
	f.Add("abc\x80def", "def")

	f.Fuzz(func(t *testing.T, haystack, pattern string) {
		if len(pattern) == 0 || len(pattern) > 255 {
			return // Skip invalid patterns
		}

		expr := Contains(pattern)
		bs := MakeBooleanSearch(expr)
		got := bs.Match(haystack)
		want := boolSearchReference(haystack, expr)

		if got != want {
			t.Fatalf("BooleanSearch.Match(%q, Contains(%q)) = %v, want %v",
				haystack, pattern, got, want)
		}
	})
}

func FuzzBoolSearchTwoPatterns(f *testing.F) {
	// Seeds for AND
	f.Add("hello world", "hello", "world", true)
	f.Add("hello there", "hello", "world", true)
	f.Add("abc", "x", "y", true)

	// Seeds for OR
	f.Add("hello world", "hello", "world", false)
	f.Add("hello there", "hello", "world", false)

	f.Fuzz(func(t *testing.T, haystack, pat1, pat2 string, isAnd bool) {
		if len(pat1) == 0 || len(pat1) > 255 || len(pat2) == 0 || len(pat2) > 255 {
			return
		}

		var expr BoolExpr
		if isAnd {
			expr = And(Contains(pat1), Contains(pat2))
		} else {
			expr = Or(Contains(pat1), Contains(pat2))
		}

		bs := MakeBooleanSearch(expr)
		got := bs.Match(haystack)
		want := boolSearchReference(haystack, expr)

		if got != want {
			op := "AND"
			if !isAnd {
				op = "OR"
			}
			t.Fatalf("BooleanSearch.Match(%q, %s(%q, %q)) = %v, want %v",
				haystack, op, pat1, pat2, got, want)
		}
	})
}

func FuzzBoolSearchNot(f *testing.F) {
	f.Add("hello world", "xyz")
	f.Add("hello world", "hello")
	f.Add("", "abc")

	f.Fuzz(func(t *testing.T, haystack, pattern string) {
		if len(pattern) == 0 || len(pattern) > 255 {
			return
		}

		expr := Not(Contains(pattern))
		bs := MakeBooleanSearch(expr)
		got := bs.Match(haystack)
		want := boolSearchReference(haystack, expr)

		if got != want {
			t.Fatalf("BooleanSearch.Match(%q, NOT(Contains(%q))) = %v, want %v",
				haystack, pattern, got, want)
		}
	})
}

func FuzzBoolSearchComplex(f *testing.F) {
	f.Add("hello world foo bar", "hello", "world", "foo", "bar")
	f.Add("the quick brown fox", "quick", "slow", "fox", "dog")

	f.Fuzz(func(t *testing.T, haystack, p1, p2, p3, p4 string) {
		if len(p1) == 0 || len(p1) > 64 ||
			len(p2) == 0 || len(p2) > 64 ||
			len(p3) == 0 || len(p3) > 64 ||
			len(p4) == 0 || len(p4) > 64 {
			return
		}

		// Test: (p1 AND p2) OR (p3 AND NOT(p4))
		expr := Or(
			And(Contains(p1), Contains(p2)),
			And(Contains(p3), Not(Contains(p4))),
		)

		bs := MakeBooleanSearch(expr)
		got := bs.Match(haystack)
		want := boolSearchReference(haystack, expr)

		if got != want {
			t.Fatalf("BooleanSearch.Match complex expression = %v, want %v", got, want)
		}
	})
}

// =============================================================================
// Benchmarks
// =============================================================================

var boolBenchSink bool

// BenchmarkBoolSearchPatternCount benchmarks different pattern counts.
func BenchmarkBoolSearchPatternCount(b *testing.B) {
	sizes := []int{1, 2, 4, 8, 16, 32, 64}
	haystackSize := 64 * 1024 // 64KB

	for _, numPatterns := range sizes {
		// Create patterns that won't match
		patterns := make([]string, numPatterns)
		for i := 0; i < numPatterns; i++ {
			patterns[i] = fmt.Sprintf("xyz%d", i)
		}

		// Build OR expression
		var expr BoolExpr = Contains(patterns[0])
		for i := 1; i < numPatterns; i++ {
			expr = Or(expr, Contains(patterns[i]))
		}

		bs := MakeBooleanSearch(expr)
		haystack := strings.Repeat("abcdefghijklmnopqrstuvw ", haystackSize/24)

		b.Run(fmt.Sprintf("OR_%d_patterns/NoMatch", numPatterns), func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystack)
			}
		})

		// With match at end
		haystackWithMatch := haystack + patterns[numPatterns/2]
		b.Run(fmt.Sprintf("OR_%d_patterns/MatchEnd", numPatterns), func(b *testing.B) {
			b.SetBytes(int64(len(haystackWithMatch)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystackWithMatch)
			}
		})

		// With match at start (early termination)
		haystackWithEarlyMatch := patterns[0] + haystack
		b.Run(fmt.Sprintf("OR_%d_patterns/MatchStart", numPatterns), func(b *testing.B) {
			b.SetBytes(int64(len(haystackWithEarlyMatch)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystackWithEarlyMatch)
			}
		})
	}
}

// BenchmarkBoolSearchExpressionTypes benchmarks different expression types.
func BenchmarkBoolSearchExpressionTypes(b *testing.B) {
	haystackSize := 64 * 1024
	haystack := strings.Repeat("abcdefghijklmnopqrstuvw ", haystackSize/24)

	exprs := map[string]BoolExpr{
		"Single": Contains("xyz123"),
		"AND_2":  And(Contains("xyz"), Contains("abc")),
		"OR_2":   Or(Contains("xyz"), Contains("abc")),
		"NOT":    Not(Contains("xyz")),
		"Complex": Or(
			And(Contains("xyz"), Contains("abc")),
			And(Contains("def"), Not(Contains("ghi"))),
		),
	}

	for name, expr := range exprs {
		bs := MakeBooleanSearch(expr)

		b.Run(name+"/NoMatch", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystack)
			}
		})
	}
}

// BenchmarkBoolSearchVsMultipleIndexFold compares multi-needle to multiple single searches.
func BenchmarkBoolSearchVsMultipleIndexFold(b *testing.B) {
	haystackSize := 64 * 1024
	haystack := strings.Repeat("abcdefghijklmnopqrstuvw ", haystackSize/24)

	patterns := []string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"}

	// Build OR expression for multi-needle
	var expr BoolExpr = Contains(patterns[0])
	for i := 1; i < len(patterns); i++ {
		expr = Or(expr, Contains(patterns[i]))
	}
	bs := MakeBooleanSearch(expr)

	b.Run("BooleanSearch_8_patterns", func(b *testing.B) {
		b.SetBytes(int64(len(haystack)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = bs.Match(haystack)
		}
	})

	b.Run("MultipleIndexFold_8_patterns", func(b *testing.B) {
		b.SetBytes(int64(len(haystack)))
		for i := 0; i < b.N; i++ {
			result := false
			for _, p := range patterns {
				if IndexFold(haystack, p) != -1 {
					result = true
					break
				}
			}
			boolBenchSink = result
		}
	})

	// Also benchmark with needles that are precomputed
	needles := make([]Needle, len(patterns))
	for i, p := range patterns {
		needles[i] = MakeNeedle(p)
	}

	b.Run("MultipleSearchNeedle_8_patterns", func(b *testing.B) {
		b.SetBytes(int64(len(haystack)))
		for i := 0; i < b.N; i++ {
			result := false
			for _, n := range needles {
				if SearchNeedle(haystack, n) != -1 {
					result = true
					break
				}
			}
			boolBenchSink = result
		}
	})
}

// BenchmarkBoolSearchHaystackSize benchmarks various haystack sizes.
func BenchmarkBoolSearchHaystackSize(b *testing.B) {
	sizes := []struct {
		name string
		size int
	}{
		{"1KB", 1024},
		{"16KB", 16 * 1024},
		{"64KB", 64 * 1024},
		{"256KB", 256 * 1024},
		{"1MB", 1024 * 1024},
	}

	// 4-pattern OR expression
	expr := Or(Or(Contains("alpha"), Contains("beta")), Or(Contains("gamma"), Contains("delta")))
	bs := MakeBooleanSearch(expr)

	for _, s := range sizes {
		haystack := strings.Repeat("abcdefghijklmnopqrstuvw ", s.size/24)

		b.Run(s.name+"/NoMatch", func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystack)
			}
		})
	}
}

// BenchmarkBoolSearchAdversarial benchmarks worst-case inputs.
func BenchmarkBoolSearchAdversarial(b *testing.B) {
	haystackSize := 64 * 1024

	// Flood: all same character
	floodHaystack := strings.Repeat("a", haystackSize)
	expr := Or(Or(Contains("aab"), Contains("aba")), Or(Contains("baa"), Contains("abc")))
	bs := MakeBooleanSearch(expr)

	b.Run("Flood_SameChar", func(b *testing.B) {
		b.SetBytes(int64(len(floodHaystack)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = bs.Match(floodHaystack)
		}
	})

	// High false positive: JSON-like data
	jsonPattern := `{"key":"value","cnt":123},`
	jsonHaystack := strings.Repeat(jsonPattern, haystackSize/len(jsonPattern))
	jsonExpr := Or(Or(Contains(`"xyz"`), Contains(`"abc"`)), Or(Contains(`"num"`), Contains(`"foo"`)))
	jsonBs := MakeBooleanSearch(jsonExpr)

	b.Run("JSON_HighFalsePositive", func(b *testing.B) {
		b.SetBytes(int64(len(jsonHaystack)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = jsonBs.Match(jsonHaystack)
		}
	})
}

// BenchmarkBoolSearchEarlyTermination benchmarks early termination scenarios.
func BenchmarkBoolSearchEarlyTermination(b *testing.B) {
	haystackSize := 64 * 1024
	baseHaystack := strings.Repeat("x", haystackSize)

	// Pattern at various positions
	positions := []struct {
		name     string
		position int
	}{
		{"Start", 0},
		{"10%", haystackSize / 10},
		{"50%", haystackSize / 2},
		{"90%", haystackSize * 9 / 10},
		{"End", haystackSize - 10},
	}

	expr := Or(Contains("needle"), Contains("found"))
	bs := MakeBooleanSearch(expr)

	for _, pos := range positions {
		haystack := baseHaystack[:pos.position] + "needle" + baseHaystack[pos.position+6:]

		b.Run("MatchAt_"+pos.name, func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystack)
			}
		})
	}
}

// BenchmarkBoolSearchCaseSensitivity benchmarks case-insensitive vs case-sensitive.
func BenchmarkBoolSearchCaseSensitivity(b *testing.B) {
	haystackSize := 64 * 1024

	// Mixed case haystack
	haystack := strings.Repeat("AbCdEfGhIjKlMnOpQrStUvWxYz ", haystackSize/27)

	// All case-insensitive
	ciExpr := Or(Or(Contains("xyz"), Contains("abc")), Or(Contains("def"), Contains("ghi")))
	ciBs := MakeBooleanSearch(ciExpr)

	b.Run("AllCaseInsensitive", func(b *testing.B) {
		b.SetBytes(int64(len(haystack)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = ciBs.Match(haystack)
		}
	})
}

// BenchmarkBoolSearchLongPatterns benchmarks patterns of various lengths.
func BenchmarkBoolSearchLongPatterns(b *testing.B) {
	haystackSize := 64 * 1024
	haystack := strings.Repeat("abcdefghijklmnopqrstuvwxyz0123456789", haystackSize/36)

	patternLengths := []int{4, 8, 16, 32, 64, 128}

	for _, plen := range patternLengths {
		pattern := strings.Repeat("xyz", plen/3+1)[:plen]
		expr := Contains(pattern)
		bs := MakeBooleanSearch(expr)

		b.Run(fmt.Sprintf("PatternLen_%d", plen), func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystack)
			}
		})
	}
}

// BenchmarkBoolSearchManyPatterns benchmarks large pattern counts for FDR engine.
func BenchmarkBoolSearchManyPatterns(b *testing.B) {
	haystackSize := 64 * 1024
	haystack := strings.Repeat("abcdefghijklmnopqrstuvwxyz ", haystackSize/27)

	patternCounts := []int{9, 16, 32, 48, 64}

	for _, n := range patternCounts {
		patterns := make([]string, n)
		for i := 0; i < n; i++ {
			patterns[i] = fmt.Sprintf("xyzpat%02d", i)
		}

		var expr BoolExpr = Contains(patterns[0])
		for i := 1; i < n; i++ {
			expr = Or(expr, Contains(patterns[i]))
		}
		bs := MakeBooleanSearch(expr)

		b.Run(fmt.Sprintf("FDR_%d_patterns", n), func(b *testing.B) {
			b.SetBytes(int64(len(haystack)))
			for i := 0; i < b.N; i++ {
				boolBenchSink = bs.Match(haystack)
			}
		})
	}
}

// BenchmarkBoolSearchRealWorld benchmarks realistic scenarios.
func BenchmarkBoolSearchRealWorld(b *testing.B) {
	// Log search: find error OR warning OR critical
	logCorpus := buildJSONLogCorpus()
	logExpr := Or(Or(Contains("error"), Contains("warning")), Or(Contains("critical"), Contains("fatal")))
	logBs := MakeBooleanSearch(logExpr)

	b.Run("LogSearch_ErrorOrWarning", func(b *testing.B) {
		b.SetBytes(int64(len(logCorpus)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = logBs.Match(logCorpus)
		}
	})

	// Security audit: find "password" AND NOT "hashed"
	securityExpr := And(Contains("password"), Not(Contains("hashed")))
	securityBs := MakeBooleanSearch(securityExpr)
	securityHaystack := strings.Repeat("user login attempt with password reset ", 1000)

	b.Run("SecurityAudit_PasswordNotHashed", func(b *testing.B) {
		b.SetBytes(int64(len(securityHaystack)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = securityBs.Match(securityHaystack)
		}
	})

	// Code search: find "func" AND "error" AND "return"
	codeExpr := And(And(Contains("func"), Contains("error")), Contains("return"))
	codeBs := MakeBooleanSearch(codeExpr)
	codeHaystack := strings.Repeat("func doSomething() { if err != nil { return err } }\n", 1000)

	b.Run("CodeSearch_FuncErrorReturn", func(b *testing.B) {
		b.SetBytes(int64(len(codeHaystack)))
		for i := 0; i < b.N; i++ {
			boolBenchSink = codeBs.Match(codeHaystack)
		}
	})
}

// =============================================================================
// Randomized Testing
// =============================================================================

func TestBoolSearchRandomized(t *testing.T) {
	rng := rand.New(rand.NewSource(42))

	for i := 0; i < 100; i++ {
		// Random haystack
		haystackLen := rng.Intn(10000) + 100
		haystack := randomString(rng, haystackLen)

		// Random number of patterns (1-16)
		numPatterns := rng.Intn(16) + 1
		patterns := make([]string, numPatterns)
		for j := 0; j < numPatterns; j++ {
			patLen := rng.Intn(20) + 1
			patterns[j] = randomString(rng, patLen)
		}

		// Random expression type
		expr := randomExpr(rng, patterns, 3)

		bs := MakeBooleanSearch(expr)
		got := bs.Match(haystack)
		want := boolSearchReference(haystack, expr)

		if got != want {
			t.Errorf("Iteration %d: BooleanSearch.Match = %v, want %v", i, got, want)
		}
	}
}

func randomString(rng *rand.Rand, n int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = charset[rng.Intn(len(charset))]
	}
	return string(b)
}

func randomExpr(rng *rand.Rand, patterns []string, depth int) BoolExpr {
	if depth == 0 || len(patterns) == 0 {
		return Contains(patterns[rng.Intn(len(patterns))])
	}

	switch rng.Intn(4) {
	case 0: // Contains
		return Contains(patterns[rng.Intn(len(patterns))])
	case 1: // And
		return And(randomExpr(rng, patterns, depth-1), randomExpr(rng, patterns, depth-1))
	case 2: // Or
		return Or(randomExpr(rng, patterns, depth-1), randomExpr(rng, patterns, depth-1))
	case 3: // Not
		return Not(randomExpr(rng, patterns, depth-1))
	}
	return Contains(patterns[0])
}
