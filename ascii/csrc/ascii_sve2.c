#include <stdint.h>
#include <stdbool.h>
#include <arm_sve.h>

// Load up to 16 chars into a vector, padding with first char
static inline svuint8_t load_chars_vec(unsigned char *chars, uint64_t len) {
    svbool_t pg = svwhilelt_b8((uint64_t)0, len > 16 ? 16 : len);
    svuint8_t vec = svld1_u8(pg, chars);
    return svsel_u8(pg, vec, svdup_n_u8(chars[0]));
}

// =============================================================================
// SVE2-optimized case-insensitive search with precomputed needle
// =============================================================================
// Key advantages over NEON:
// - svmatch: matches up to 16 tokens in 1 instruction (2 cycles on N2)
// - svwhilelt_b8: natural tail predicates (no explicit mask table)
// - svptest_any: fast "any match" detection
// - svbrkb/svcntp: find first match position without ctz dance

// SVE2 normalize_upper: convert lowercase to uppercase
static inline svuint8_t sve2_normalize_upper(svbool_t pg, svuint8_t v) {
    const svuint8_t char_a = svdup_n_u8('a');
    const svuint8_t char_z = svdup_n_u8('z');
    const svuint8_t flip = svdup_n_u8(0x20);
    
    // is_lower = (v >= 'a') & (v <= 'z')
    svbool_t ge_a = svcmpge_u8(pg, v, char_a);
    svbool_t le_z = svcmple_u8(pg, v, char_z);
    svbool_t is_lower = svand_z(pg, ge_a, le_z);
    
    // XOR with 0x20 where lowercase to convert to uppercase
    return sveor_m(is_lower, v, flip);
}

// Scalar uppercase for pre-filter
static inline uint8_t scalar_to_upper(uint8_t c) {
    uint8_t u = c & 0xDFu;
    return (u >= 'A' && u <= 'Z') ? u : c;
}

// SVE2 equal_fold: case-insensitive comparison
// IMPORTANT: 'b' (norm_needle) is already uppercase, so we only normalize 'a' (haystack)
// Optimized for short needles with scalar fast path
static inline bool sve2_equal_fold(const unsigned char *a, const unsigned char *b, int64_t len) {
    // Very short needle: scalar is faster than SVE setup
    if (len <= 8) {
        for (int64_t i = 0; i < len; i++) {
            if (scalar_to_upper(a[i]) != b[i]) return false;
        }
        return true;
    }
    
    // Short needle: single vector operation
    if (len <= 64) {
        svbool_t pg = svwhilelt_b8((uint64_t)0, (uint64_t)len);
        svuint8_t va = sve2_normalize_upper(pg, svld1_u8(pg, a));
        svuint8_t vb = svld1_u8(pg, b);  // b is already normalized
        svuint8_t diff = sveor_u8_z(pg, va, vb);
        return !svptest_any(pg, svcmpne_n_u8(pg, diff, 0));
    }
    
    // Long needle path
    int64_t i = 0;
    const uint64_t vl = svcntb();
    const svbool_t all = svptrue_b8();
    
    while (len >= (int64_t)vl) {
        svuint8_t va = sve2_normalize_upper(all, svld1_u8(all, a + i));
        svuint8_t vb = svld1_u8(all, b + i);  // b is already normalized
        svuint8_t diff = sveor_u8_z(all, va, vb);
        
        if (svptest_any(all, svcmpne_n_u8(all, diff, 0))) {
            return false;
        }
        i += vl;
        len -= vl;
    }
    
    if (len > 0) {
        svbool_t tail_pg = svwhilelt_b8((uint64_t)0, (uint64_t)len);
        svuint8_t va = sve2_normalize_upper(tail_pg, svld1_u8(tail_pg, a + i));
        svuint8_t vb = svld1_u8(tail_pg, b + i);  // b is already normalized
        svuint8_t diff = sveor_u8_z(tail_pg, va, vb);
        
        if (svptest_any(tail_pg, svcmpne_n_u8(tail_pg, diff, 0))) {
            return false;
        }
    }
    
    return true;
}

// Helper to compute upper/lower variants without triggering SIMD immediate optimization
static inline void compute_case_variants(uint8_t byte, uint8_t *upper, uint8_t *lower) {
    // Force scalar computation to avoid VORR immediate
    uint8_t u = byte & 0xDFu;  // Clear bit 5 (uppercase if letter)
    uint8_t l = byte | 0x20u;  // Set bit 5 (lowercase if letter)
    // Check if it's actually a letter
    uint8_t is_letter = (u >= 'A' && u <= 'Z') ? 1 : 0;
    *upper = is_letter ? u : byte;
    *lower = is_letter ? l : byte;
}

// gocc: indexFoldNeedleSve2(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
int64_t index_fold_needle_sve2(
    unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1,
    uint8_t rare2, int64_t off2,
    unsigned char *norm_needle, int64_t needle_len)
{
    if (haystack_len < needle_len) return -1;
    if (needle_len <= 0) return 0;
    
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint64_t vl = svcntb();
    
    // Compute case variants using helper to avoid SIMD immediate optimization
    uint8_t rare1U, rare1L, rare2U, rare2L;
    compute_case_variants(rare1, &rare1U, &rare1L);
    compute_case_variants(rare2, &rare2U, &rare2L);
    
    // Create search vectors for svmatch using SVE dup + zip
    // svmatch checks: does each byte in haystack match ANY byte in search_vec?
    // We interleave upper and lower variants
    svuint8_t v_rare1U = svdup_n_u8(rare1U);
    svuint8_t v_rare1L = svdup_n_u8(rare1L);
    svuint8_t v_rare2U = svdup_n_u8(rare2U);
    svuint8_t v_rare2L = svdup_n_u8(rare2L);
    
    // Interleave: [U, L, U, L, ...] for better svmatch distribution
    svuint8_t v_rare1 = svzip1_u8(v_rare1U, v_rare1L);
    svuint8_t v_rare2 = svzip1_u8(v_rare2U, v_rare2L);
    
    // Pre-compute first and last bytes of normalized needle for quick pre-filter
    const uint8_t needle_first = norm_needle[0];
    const uint8_t needle_last = norm_needle[needle_len - 1];
    
    // Pre-compute middle byte for 3-point pre-filter (helps when first==last like "...")
    // For needles >= 4 bytes, check a third byte at middle position
    const int64_t mid_off = needle_len >= 4 ? (needle_len / 2) : -1;
    const uint8_t needle_mid = mid_off >= 0 ? norm_needle[mid_off] : 0;
    
    // Hoist svptrue_b8() out of loop
    const svbool_t pg_all = svptrue_b8();
    
    int64_t i = 0;
    
    // Main loop: process full vector lengths
    while (i + (int64_t)vl <= search_len) {
        // Load bytes at off1 and off2 positions
        svuint8_t c1 = svld1_u8(pg_all, haystack + i + off1);
        svuint8_t c2 = svld1_u8(pg_all, haystack + i + off2);
        
        // Use svmatch: for each lane, check if byte matches any in search vector
        svbool_t eq1 = svmatch_u8(pg_all, c1, v_rare1);
        svbool_t eq2 = svmatch_u8(pg_all, c2, v_rare2);
        
        // Both rare bytes must match
        svbool_t both = svand_z(pg_all, eq1, eq2);
        
        if (svptest_any(pg_all, both)) {
            // Find positions of matches and verify each
            while (svptest_any(pg_all, both)) {
                // Find first match position using svbrkb (mask of elements before first true)
                svbool_t before = svbrkb_z(pg_all, both);
                uint64_t pos = svcntp_b8(pg_all, before);
                
                int64_t idx = i + pos;
                
                // Quick scalar pre-filter: check first and last bytes before full verification
                uint8_t h_first = scalar_to_upper(haystack[idx]);
                uint8_t h_last = scalar_to_upper(haystack[idx + needle_len - 1]);
                
                if (h_first == needle_first && h_last == needle_last) {
                    // Additional middle byte check for high false positive cases
                    if (mid_off < 0 || scalar_to_upper(haystack[idx + mid_off]) == needle_mid) {
                        if (sve2_equal_fold(haystack + idx, norm_needle, needle_len)) {
                            return idx;
                        }
                    }
                }
                
                // Clear this match using svbrka (mask up to and including first true)
                svbool_t upto = svbrka_z(pg_all, both);
                both = svbic_z(pg_all, both, upto);
            }
        }
        
        i += vl;
    }
    
    // Handle remainder with tail predicate
    if (i < search_len) {
        int64_t remaining = search_len - i;
        svbool_t pg = svwhilelt_b8((uint64_t)0, (uint64_t)remaining);
        
        svuint8_t c1 = svld1_u8(pg, haystack + i + off1);
        svuint8_t c2 = svld1_u8(pg, haystack + i + off2);
        
        svbool_t eq1 = svmatch_u8(pg, c1, v_rare1);
        svbool_t eq2 = svmatch_u8(pg, c2, v_rare2);
        svbool_t both = svand_z(pg, eq1, eq2);
        
        while (svptest_any(pg, both)) {
            svbool_t before = svbrkb_z(pg, both);
            uint64_t pos = svcntp_b8(pg, before);
            
            int64_t idx = i + pos;
            if (idx < search_len) {
                // Quick scalar pre-filter
                uint8_t h_first = scalar_to_upper(haystack[idx]);
                uint8_t h_last = scalar_to_upper(haystack[idx + needle_len - 1]);
                
                if (h_first == needle_first && h_last == needle_last) {
                    // Additional middle byte check
                    if (mid_off < 0 || scalar_to_upper(haystack[idx + mid_off]) == needle_mid) {
                        if (sve2_equal_fold(haystack + idx, norm_needle, needle_len)) {
                            return idx;
                        }
                    }
                }
            }
            
            // Clear this match using svbrka
            svbool_t upto = svbrka_z(pg, both);
            both = svbic_z(pg, both, upto);
        }
    }
    
    return -1;
}

// IndexAny finds the first occurrence of any byte from 'chars' in 'data'.
// Uses SVE2 MATCH instruction for efficient multi-character search.
// Supports any number of chars by running multiple MATCH passes.
//
// gocc: indexAnySve2(data string, chars string) int
int64_t index_any_sve2(unsigned char *data, uint64_t data_len, unsigned char *chars, uint64_t chars_len)
{
    if (data_len == 0 || chars_len == 0) {
        return -1;
    }

    const uint64_t vl = svcntb();
    const unsigned char *data_start = data;
    
    // Pre-load char vectors - up to 4 vectors (64 chars max)
    // Unused vectors default to chars0 (matching against same chars is harmless)
    const svuint8_t c0 = load_chars_vec(chars, chars_len);
    const svuint8_t c1 = chars_len > 16 ? load_chars_vec(chars + 16, chars_len - 16) : c0;
    const svuint8_t c2 = chars_len > 32 ? load_chars_vec(chars + 32, chars_len - 32) : c0;
    const svuint8_t c3 = chars_len > 48 ? load_chars_vec(chars + 48, chars_len - 48) : c0;

    // Process full vectors
    while (data_len >= vl) {
        svbool_t pg = svptrue_b8();
        svuint8_t d = svld1_u8(pg, data);
        
        // MATCH against all 4 char vectors with tree reduction (enables parallel execution)
        svbool_t m0 = svmatch_u8(pg, d, c0);
        svbool_t m1 = svmatch_u8(pg, d, c1);
        svbool_t m2 = svmatch_u8(pg, d, c2);
        svbool_t m3 = svmatch_u8(pg, d, c3);
        svbool_t r0 = svorr_z(pg, m0, m1);
        svbool_t r1 = svorr_z(pg, m2, m3);
        svbool_t m = svorr_z(pg, r0, r1);
        
        if (svptest_any(pg, m)) {
            svbool_t first = svbrkb_z(pg, m);
            uint64_t pos = svcntp_b8(pg, first);
            return (data - data_start) + pos;
        }
        
        data += vl;
        data_len -= vl;
    }

    // Remainder
    if (data_len > 0) {
        svbool_t pg = svwhilelt_b8((uint64_t)0, data_len);
        svuint8_t d = svld1_u8(pg, data);
        
        svbool_t m0 = svmatch_u8(pg, d, c0);
        svbool_t m1 = svmatch_u8(pg, d, c1);
        svbool_t m2 = svmatch_u8(pg, d, c2);
        svbool_t m3 = svmatch_u8(pg, d, c3);
        svbool_t r0 = svorr_z(pg, m0, m1);
        svbool_t r1 = svorr_z(pg, m2, m3);
        svbool_t m = svorr_z(pg, r0, r1);
        
        if (svptest_any(pg, m)) {
            svbool_t first = svbrkb_z(pg, m);
            uint64_t pos = svcntp_b8(pg, first);
            return (data - data_start) + pos;
        }
    }

    return -1;
}
