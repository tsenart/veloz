#include <stdint.h>
#include <stdbool.h>
#include <arm_neon.h>

// =============================================================================
// Modular NEON Substring Search Kernels
// =============================================================================
// Architecture: Go driver orchestrates staged kernels:
//   Stage 1: 1-byte search (early exit on too many false positives)
//   Stage 2: 2-byte search (early exit on too many false positives)
//   Stage 3: SIMD Rabin-Karp (guaranteed linear)
//
// Result encoding (uint64):
//   Bit 63: exceeded flag (1 = too many false positives)
//   Bits 0-62: position (signed, -1 = not found, >=0 = match or resume position)
//
// Interpretation:
//   exceeded=0, pos>=0: match found at pos
//   exceeded=0, pos<0:  no match found (-1)
//   exceeded=1, pos>=0: too many false positives, resume from pos
// =============================================================================

// Tail mask table for handling partial vectors (1-15 bytes)
static const uint8_t tail_mask_table[16][16] __attribute__((aligned(16))) = {
    {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00},
    {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00},
};

// =============================================================================
// Result encoding macros
// =============================================================================
#define EXCEEDED_FLAG (1ULL << 63)
#define RESULT_FOUND(pos) ((uint64_t)(pos))
#define RESULT_NOT_FOUND ((uint64_t)-1)
#define RESULT_EXCEEDED(pos) (((uint64_t)(pos)) | EXCEEDED_FLAG)

// =============================================================================
// Verification functions
// =============================================================================

// Case-sensitive exact comparison
__attribute__((always_inline)) static inline bool verify_exact(
    const unsigned char *haystack, const unsigned char *needle, 
    int64_t needle_len, int64_t haystack_remaining) 
{
    while (needle_len >= 16 && haystack_remaining >= 16) {
        uint8x16_t va = vld1q_u8(haystack);
        uint8x16_t vb = vld1q_u8(needle);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        haystack += 16;
        needle += 16;
        needle_len -= 16;
        haystack_remaining -= 16;
    }
    if (needle_len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[needle_len]);
        uint8x16_t va = vld1q_u8(haystack);
        va = vandq_u8(va, mask);
        uint8x16_t vb = vandq_u8(vld1q_u8(needle), mask);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// Case-insensitive with pre-normalized (lowercase) needle
// Haystack is normalized on-the-fly, needle already lowercase
__attribute__((always_inline)) static inline bool verify_fold_prenorm(
    const unsigned char *haystack, const unsigned char *needle,
    int64_t needle_len, int64_t haystack_remaining)
{
    const uint8x16_t char_A = vdupq_n_u8('A');
    const uint8x16_t char_Z = vdupq_n_u8('Z');
    const uint8x16_t flip = vdupq_n_u8(0x20);
    
    while (needle_len >= 16 && haystack_remaining >= 16) {
        uint8x16_t va = vld1q_u8(haystack);
        uint8x16_t ge_A = vcgeq_u8(va, char_A);
        uint8x16_t le_Z = vcleq_u8(va, char_Z);
        uint8x16_t is_upper = vandq_u8(ge_A, le_Z);
        va = vorrq_u8(va, vandq_u8(is_upper, flip));
        
        uint8x16_t vb = vld1q_u8(needle);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        haystack += 16;
        needle += 16;
        needle_len -= 16;
        haystack_remaining -= 16;
    }
    if (needle_len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[needle_len]);
        uint8x16_t va = vld1q_u8(haystack);
        uint8x16_t ge_A = vcgeq_u8(va, char_A);
        uint8x16_t le_Z = vcleq_u8(va, char_Z);
        uint8x16_t is_upper = vandq_u8(ge_A, le_Z);
        va = vorrq_u8(va, vandq_u8(is_upper, flip));
        va = vandq_u8(va, mask);
        uint8x16_t vb = vandq_u8(vld1q_u8(needle), mask);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// Case-insensitive with raw needle (not pre-normalized)
// Both haystack AND needle are normalized on-the-fly
__attribute__((always_inline)) static inline bool verify_fold(
    const unsigned char *haystack, const unsigned char *needle,
    int64_t needle_len, int64_t haystack_remaining)
{
    const uint8x16_t char_A = vdupq_n_u8('A');
    const uint8x16_t char_Z = vdupq_n_u8('Z');
    const uint8x16_t flip = vdupq_n_u8(0x20);
    
    while (needle_len >= 16 && haystack_remaining >= 16) {
        uint8x16_t va = vld1q_u8(haystack);
        uint8x16_t ge_A = vcgeq_u8(va, char_A);
        uint8x16_t le_Z = vcleq_u8(va, char_Z);
        uint8x16_t is_upper = vandq_u8(ge_A, le_Z);
        va = vorrq_u8(va, vandq_u8(is_upper, flip));
        
        uint8x16_t vb = vld1q_u8(needle);
        uint8x16_t ge_A_b = vcgeq_u8(vb, char_A);
        uint8x16_t le_Z_b = vcleq_u8(vb, char_Z);
        uint8x16_t is_upper_b = vandq_u8(ge_A_b, le_Z_b);
        vb = vorrq_u8(vb, vandq_u8(is_upper_b, flip));
        
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        haystack += 16;
        needle += 16;
        needle_len -= 16;
        haystack_remaining -= 16;
    }
    if (needle_len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[needle_len]);
        uint8x16_t va = vld1q_u8(haystack);
        uint8x16_t ge_A = vcgeq_u8(va, char_A);
        uint8x16_t le_Z = vcleq_u8(va, char_Z);
        uint8x16_t is_upper = vandq_u8(ge_A, le_Z);
        va = vorrq_u8(va, vandq_u8(is_upper, flip));
        va = vandq_u8(va, mask);
        
        uint8x16_t vb = vld1q_u8(needle);
        uint8x16_t ge_A_b = vcgeq_u8(vb, char_A);
        uint8x16_t le_Z_b = vcleq_u8(vb, char_Z);
        uint8x16_t is_upper_b = vandq_u8(ge_A_b, le_Z_b);
        vb = vorrq_u8(vb, vandq_u8(is_upper_b, flip));
        vb = vandq_u8(vb, mask);
        
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// =============================================================================
// Helper: Fast "any nonzero?" check
// =============================================================================
__attribute__((always_inline)) static inline uint64_t any_nonzero(uint8x16_t v) {
    uint64x2_t v64 = vreinterpretq_u64_u8(v);
    uint64x2_t folded = vpaddq_u64(v64, v64);
    return vgetq_lane_u64(folded, 0);
}

// =============================================================================
// STAGE 1: 1-Byte Search Kernels
// =============================================================================

// 1-byte search with case folding for letters
// Uses OR 0x20 to fold haystack bytes before compare (letters only)
// For non-letters, uses exact match (mask = 0x00)
// Derives rare1 from needle[off1] (needle must be pre-normalized to lowercase)
// gocc: indexFold1Byte(haystack string, needle string, off1 int) uint64
uint64_t index_fold_1byte(
    unsigned char *haystack, int64_t haystack_len,
    unsigned char *needle, int64_t needle_len,
    int64_t off1)
{
    if (haystack_len < needle_len) return RESULT_NOT_FOUND;
    if (needle_len == 0) return RESULT_FOUND(0);
    
    const uint8_t rare1 = needle[off1];
    const int rare1_is_letter = (unsigned)(rare1 - 'a') < 26;
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint8x16_t v_mask = vdupq_n_u8(rare1_is_letter ? 0x20 : 0x00);
    const uint8x16_t v_target = vdupq_n_u8(rare1);
    
    unsigned char *search_ptr = haystack + off1;
    unsigned char *search_start = search_ptr;
    unsigned char *data_end = haystack + haystack_len;
    int64_t remaining = search_len;
    int64_t failures = 0;
    
    // 32-byte loop
    // Threshold: 16 failures warmup + 1 per 16 bytes scanned (like memchr's 50-invocation warmup)
    while (remaining >= 32) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        
        uint8x16_t d0 = vld1q_u8(search_ptr);
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);
        search_ptr += 32;
        remaining -= 32;
        
        uint8x16_t m0 = vceqq_u8(vorrq_u8(d0, v_mask), v_target);
        uint8x16_t m1 = vceqq_u8(vorrq_u8(d1, v_mask), v_target);
        
        uint8x16_t any = vorrq_u8(m0, m1);
        if (any_nonzero(any) == 0) continue;
        
        // Process using SHRN for syndrome (4 bits per byte)
        uint8x8_t n0 = vshrn_n_u16(vreinterpretq_u16_u8(m0), 4);
        uint64_t syn0 = vget_lane_u64(vreinterpret_u64_u8(n0), 0);
        while (syn0) {
            int bit_pos = __builtin_ctzll(syn0);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 32 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn0 &= ~((1ULL << clear_pos) - 1);
        }
        
        uint8x8_t n1 = vshrn_n_u16(vreinterpretq_u16_u8(m1), 4);
        uint64_t syn1 = vget_lane_u64(vreinterpret_u64_u8(n1), 0);
        while (syn1) {
            int bit_pos = __builtin_ctzll(syn1);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn1 &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // 16-byte loop
    while (remaining >= 16) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        
        uint8x16_t d = vld1q_u8(search_ptr);
        search_ptr += 16;
        remaining -= 16;
        
        uint8x16_t m = vceqq_u8(vorrq_u8(d, v_mask), v_target);
        uint8x8_t n = vshrn_n_u16(vreinterpretq_u16_u8(m), 4);
        uint64_t syn = vget_lane_u64(vreinterpret_u64_u8(n), 0);
        
        while (syn) {
            int bit_pos = __builtin_ctzll(syn);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // Scalar loop
    const uint8_t scalar_mask = rare1_is_letter ? 0x20 : 0x00;
    while (remaining > 0) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        int64_t pos = search_ptr - haystack - off1;
        
        uint8_t c = *search_ptr;
        if ((c | scalar_mask) == rare1 && pos >= 0 && pos < search_len) {
            unsigned char *candidate = haystack + pos;
            int64_t cand_remaining = data_end - candidate;
            if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                return RESULT_FOUND(pos);
            }
            failures++;
            if (failures > threshold) {
                return RESULT_EXCEEDED(pos + 1);
            }
        }
        search_ptr++;
        remaining--;
    }
    
    return RESULT_NOT_FOUND;
}

// 1-byte search for exact matching (no case folding)
// Derives rare1 from needle[off1]
// gocc: indexExact1Byte(haystack string, needle string, off1 int) uint64
uint64_t index_exact_1byte(
    unsigned char *haystack, int64_t haystack_len,
    unsigned char *needle, int64_t needle_len,
    int64_t off1)
{
    if (haystack_len < needle_len) return RESULT_NOT_FOUND;
    if (needle_len == 0) return RESULT_FOUND(0);
    
    const uint8_t rare1 = needle[off1];
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint8x16_t v_target = vdupq_n_u8(rare1);
    
    unsigned char *search_ptr = haystack + off1;
    unsigned char *search_start = search_ptr;
    unsigned char *data_end = haystack + haystack_len;
    int64_t remaining = search_len;
    int64_t failures = 0;
    
    // 32-byte loop
    // Threshold: 16 failures warmup + 1 per 16 bytes scanned
    while (remaining >= 32) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        
        uint8x16_t d0 = vld1q_u8(search_ptr);
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);
        search_ptr += 32;
        remaining -= 32;
        
        uint8x16_t m0 = vceqq_u8(d0, v_target);
        uint8x16_t m1 = vceqq_u8(d1, v_target);
        
        uint8x16_t any = vorrq_u8(m0, m1);
        if (any_nonzero(any) == 0) continue;
        
        uint8x8_t n0 = vshrn_n_u16(vreinterpretq_u16_u8(m0), 4);
        uint64_t syn0 = vget_lane_u64(vreinterpret_u64_u8(n0), 0);
        while (syn0) {
            int bit_pos = __builtin_ctzll(syn0);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 32 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn0 &= ~((1ULL << clear_pos) - 1);
        }
        
        uint8x8_t n1 = vshrn_n_u16(vreinterpretq_u16_u8(m1), 4);
        uint64_t syn1 = vget_lane_u64(vreinterpret_u64_u8(n1), 0);
        while (syn1) {
            int bit_pos = __builtin_ctzll(syn1);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn1 &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // 16-byte loop
    while (remaining >= 16) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        
        uint8x16_t d = vld1q_u8(search_ptr);
        search_ptr += 16;
        remaining -= 16;
        
        uint8x16_t m = vceqq_u8(d, v_target);
        uint8x8_t n = vshrn_n_u16(vreinterpretq_u16_u8(m), 4);
        uint64_t syn = vget_lane_u64(vreinterpret_u64_u8(n), 0);
        
        while (syn) {
            int bit_pos = __builtin_ctzll(syn);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // Scalar loop
    while (remaining > 0) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        int64_t pos = search_ptr - haystack - off1;
        
        if (*search_ptr == rare1 && pos >= 0 && pos < search_len) {
            unsigned char *candidate = haystack + pos;
            int64_t cand_remaining = data_end - candidate;
            if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                return RESULT_FOUND(pos);
            }
            failures++;
            if (failures > threshold) {
                return RESULT_EXCEEDED(pos + 1);
            }
        }
        search_ptr++;
        remaining--;
    }
    
    return RESULT_NOT_FOUND;
}

// =============================================================================
// STAGE 2: 2-Byte Search Kernels
// =============================================================================

// 2-byte search with case folding (pre-normalized lowercase needle)
// Derives rare bytes from needle[off1] and needle[off1 + off2Delta]
// gocc: indexFold2Byte(haystack string, needle string, off1 int, off2Delta int) uint64
uint64_t index_fold_2byte(
    unsigned char *haystack, int64_t haystack_len,
    unsigned char *needle, int64_t needle_len,
    int64_t off1, int64_t off2_delta)
{
    if (haystack_len < needle_len) return RESULT_NOT_FOUND;
    if (needle_len == 0) return RESULT_FOUND(0);
    
    const uint8_t rare1 = needle[off1];
    const uint8_t rare2 = needle[off1 + off2_delta];
    const uint8_t mask1 = ((unsigned)(rare1 - 'a') < 26) ? 0x20 : 0x00;
    const uint8_t mask2 = ((unsigned)(rare2 - 'a') < 26) ? 0x20 : 0x00;
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint8x16_t v_mask1 = vdupq_n_u8(mask1);
    const uint8x16_t v_target1 = vdupq_n_u8(rare1);
    const uint8x16_t v_mask2 = vdupq_n_u8(mask2);
    const uint8x16_t v_target2 = vdupq_n_u8(rare2);
    
    unsigned char *search_ptr = haystack + off1;
    int64_t remaining = search_len;
    int64_t failures = 0;
    
    // 64-byte loop
    // Threshold: 32 failures warmup + 1 per 8 bytes scanned
    while (remaining >= 64) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        
        uint8x16_t r1_0 = vld1q_u8(search_ptr);
        uint8x16_t r1_1 = vld1q_u8(search_ptr + 16);
        uint8x16_t r1_2 = vld1q_u8(search_ptr + 32);
        uint8x16_t r1_3 = vld1q_u8(search_ptr + 48);
        
        uint8x16_t r2_0 = vld1q_u8(search_ptr + off2_delta);
        uint8x16_t r2_1 = vld1q_u8(search_ptr + off2_delta + 16);
        uint8x16_t r2_2 = vld1q_u8(search_ptr + off2_delta + 32);
        uint8x16_t r2_3 = vld1q_u8(search_ptr + off2_delta + 48);
        
        search_ptr += 64;
        remaining -= 64;
        
        uint8x16_t m1_0 = vceqq_u8(vorrq_u8(r1_0, v_mask1), v_target1);
        uint8x16_t m1_1 = vceqq_u8(vorrq_u8(r1_1, v_mask1), v_target1);
        uint8x16_t m1_2 = vceqq_u8(vorrq_u8(r1_2, v_mask1), v_target1);
        uint8x16_t m1_3 = vceqq_u8(vorrq_u8(r1_3, v_mask1), v_target1);
        
        uint8x16_t m2_0 = vceqq_u8(vorrq_u8(r2_0, v_mask2), v_target2);
        uint8x16_t m2_1 = vceqq_u8(vorrq_u8(r2_1, v_mask2), v_target2);
        uint8x16_t m2_2 = vceqq_u8(vorrq_u8(r2_2, v_mask2), v_target2);
        uint8x16_t m2_3 = vceqq_u8(vorrq_u8(r2_3, v_mask2), v_target2);
        
        uint8x16_t both0 = vandq_u8(m1_0, m2_0);
        uint8x16_t both1 = vandq_u8(m1_1, m2_1);
        uint8x16_t both2 = vandq_u8(m1_2, m2_2);
        uint8x16_t both3 = vandq_u8(m1_3, m2_3);
        
        uint8x16_t any = vorrq_u8(vorrq_u8(both0, both1), vorrq_u8(both2, both3));
        if (any_nonzero(any) == 0) continue;
        
        uint8x16_t chunks[4] = {both0, both1, both2, both3};
        for (int chunk = 0; chunk < 4; chunk++) {
            uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(chunks[chunk]), 4);
            uint64_t syndrome = vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
            
            while (syndrome) {
                int bit_pos = __builtin_ctzll(syndrome);
                int byte_pos = bit_pos >> 2;
                int64_t pos = (search_ptr - 64 - haystack) + chunk * 16 + byte_pos - off1;
                
                if (pos >= 0 && pos < search_len) {
                    unsigned char *candidate = haystack + pos;
                    int64_t cand_remaining = haystack_len - pos;
                    if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                        return RESULT_FOUND(pos);
                    }
                    failures++;
                    if (failures > threshold) {
                        return RESULT_EXCEEDED(pos + 1);
                    }
                }
                int clear_pos = ((byte_pos + 1) << 2);
                syndrome &= ~((1ULL << clear_pos) - 1);
            }
        }
    }
    
    // 16-byte loop
    while (remaining >= 16) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        
        uint8x16_t r1 = vld1q_u8(search_ptr);
        uint8x16_t r2 = vld1q_u8(search_ptr + off2_delta);
        search_ptr += 16;
        remaining -= 16;
        
        uint8x16_t m1 = vceqq_u8(vorrq_u8(r1, v_mask1), v_target1);
        uint8x16_t m2 = vceqq_u8(vorrq_u8(r2, v_mask2), v_target2);
        uint8x16_t both = vandq_u8(m1, m2);
        
        uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(both), 4);
        uint64_t syndrome = vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
        
        while (syndrome) {
            int bit_pos = __builtin_ctzll(syndrome);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = haystack_len - pos;
                if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syndrome &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // Scalar loop
    while (remaining > 0) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        int64_t pos = search_ptr - haystack - off1;
        
        uint8_t c1 = *search_ptr;
        uint8_t c2 = *(search_ptr + off2_delta);
        
        if (((c1 | mask1) == rare1) && ((c2 | mask2) == rare2) && pos >= 0 && pos < search_len) {
            unsigned char *candidate = haystack + pos;
            int64_t cand_remaining = haystack_len - pos;
            if (verify_fold_prenorm(candidate, needle, needle_len, cand_remaining)) {
                return RESULT_FOUND(pos);
            }
            failures++;
            if (failures > threshold) {
                return RESULT_EXCEEDED(pos + 1);
            }
        }
        search_ptr++;
        remaining--;
    }
    
    return RESULT_NOT_FOUND;
}

// 2-byte search for exact matching (no case folding)
// Derives rare bytes from needle[off1] and needle[off1 + off2Delta]
// gocc: indexExact2Byte(haystack string, needle string, off1 int, off2Delta int) uint64
uint64_t index_exact_2byte(
    unsigned char *haystack, int64_t haystack_len,
    unsigned char *needle, int64_t needle_len,
    int64_t off1, int64_t off2_delta)
{
    if (haystack_len < needle_len) return RESULT_NOT_FOUND;
    if (needle_len == 0) return RESULT_FOUND(0);
    
    const uint8_t rare1 = needle[off1];
    const uint8_t rare2 = needle[off1 + off2_delta];
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint8x16_t v_target1 = vdupq_n_u8(rare1);
    const uint8x16_t v_target2 = vdupq_n_u8(rare2);
    
    unsigned char *search_ptr = haystack + off1;
    int64_t remaining = search_len;
    int64_t failures = 0;
    
    // 64-byte loop
    // Threshold: 32 failures warmup + 1 per 8 bytes scanned
    while (remaining >= 64) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        
        uint8x16_t r1_0 = vld1q_u8(search_ptr);
        uint8x16_t r1_1 = vld1q_u8(search_ptr + 16);
        uint8x16_t r1_2 = vld1q_u8(search_ptr + 32);
        uint8x16_t r1_3 = vld1q_u8(search_ptr + 48);
        
        uint8x16_t r2_0 = vld1q_u8(search_ptr + off2_delta);
        uint8x16_t r2_1 = vld1q_u8(search_ptr + off2_delta + 16);
        uint8x16_t r2_2 = vld1q_u8(search_ptr + off2_delta + 32);
        uint8x16_t r2_3 = vld1q_u8(search_ptr + off2_delta + 48);
        
        search_ptr += 64;
        remaining -= 64;
        
        uint8x16_t m1_0 = vceqq_u8(r1_0, v_target1);
        uint8x16_t m1_1 = vceqq_u8(r1_1, v_target1);
        uint8x16_t m1_2 = vceqq_u8(r1_2, v_target1);
        uint8x16_t m1_3 = vceqq_u8(r1_3, v_target1);
        
        uint8x16_t m2_0 = vceqq_u8(r2_0, v_target2);
        uint8x16_t m2_1 = vceqq_u8(r2_1, v_target2);
        uint8x16_t m2_2 = vceqq_u8(r2_2, v_target2);
        uint8x16_t m2_3 = vceqq_u8(r2_3, v_target2);
        
        uint8x16_t both0 = vandq_u8(m1_0, m2_0);
        uint8x16_t both1 = vandq_u8(m1_1, m2_1);
        uint8x16_t both2 = vandq_u8(m1_2, m2_2);
        uint8x16_t both3 = vandq_u8(m1_3, m2_3);
        
        uint8x16_t any = vorrq_u8(vorrq_u8(both0, both1), vorrq_u8(both2, both3));
        if (any_nonzero(any) == 0) continue;
        
        uint8x16_t chunks[4] = {both0, both1, both2, both3};
        for (int chunk = 0; chunk < 4; chunk++) {
            uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(chunks[chunk]), 4);
            uint64_t syndrome = vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
            
            while (syndrome) {
                int bit_pos = __builtin_ctzll(syndrome);
                int byte_pos = bit_pos >> 2;
                int64_t pos = (search_ptr - 64 - haystack) + chunk * 16 + byte_pos - off1;
                
                if (pos >= 0 && pos < search_len) {
                    unsigned char *candidate = haystack + pos;
                    int64_t cand_remaining = haystack_len - pos;
                    if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                        return RESULT_FOUND(pos);
                    }
                    failures++;
                    if (failures > threshold) {
                        return RESULT_EXCEEDED(pos + 1);
                    }
                }
                int clear_pos = ((byte_pos + 1) << 2);
                syndrome &= ~((1ULL << clear_pos) - 1);
            }
        }
    }
    
    // 16-byte loop
    while (remaining >= 16) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        
        uint8x16_t r1 = vld1q_u8(search_ptr);
        uint8x16_t r2 = vld1q_u8(search_ptr + off2_delta);
        search_ptr += 16;
        remaining -= 16;
        
        uint8x16_t m1 = vceqq_u8(r1, v_target1);
        uint8x16_t m2 = vceqq_u8(r2, v_target2);
        uint8x16_t both = vandq_u8(m1, m2);
        
        uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(both), 4);
        uint64_t syndrome = vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
        
        while (syndrome) {
            int bit_pos = __builtin_ctzll(syndrome);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = haystack_len - pos;
                if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syndrome &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // Scalar loop
    while (remaining > 0) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        int64_t pos = search_ptr - haystack - off1;
        
        if (*search_ptr == rare1 && *(search_ptr + off2_delta) == rare2 && pos >= 0 && pos < search_len) {
            unsigned char *candidate = haystack + pos;
            int64_t cand_remaining = haystack_len - pos;
            if (verify_exact(candidate, needle, needle_len, cand_remaining)) {
                return RESULT_FOUND(pos);
            }
            failures++;
            if (failures > threshold) {
                return RESULT_EXCEEDED(pos + 1);
            }
        }
        search_ptr++;
        remaining--;
    }
    
    return RESULT_NOT_FOUND;
}

// =============================================================================
// RAW VARIANTS: For ad-hoc searches without pre-normalized needle
// These lowercase rare bytes inline and use verify_fold (folds both strings)
// =============================================================================

// Helper: lowercase a byte if it's an uppercase letter
#define TO_LOWER(c) ((unsigned)((c) - 'A') < 26 ? (c) | 0x20 : (c))

// 1-byte search with case folding, raw needle (not pre-normalized)
// gocc: indexFold1ByteRaw(haystack string, needle string, off1 int) uint64
uint64_t index_fold_1byte_raw(
    unsigned char *haystack, int64_t haystack_len,
    unsigned char *needle, int64_t needle_len,
    int64_t off1)
{
    if (haystack_len < needle_len) return RESULT_NOT_FOUND;
    if (needle_len == 0) return RESULT_FOUND(0);
    
    // Lowercase the rare byte on-the-fly
    const uint8_t rare1_raw = needle[off1];
    const uint8_t rare1 = TO_LOWER(rare1_raw);
    const int rare1_is_letter = (unsigned)(rare1 - 'a') < 26;
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint8x16_t v_mask = vdupq_n_u8(rare1_is_letter ? 0x20 : 0x00);
    const uint8x16_t v_target = vdupq_n_u8(rare1);
    
    unsigned char *search_ptr = haystack + off1;
    unsigned char *search_start = search_ptr;
    unsigned char *data_end = haystack + haystack_len;
    int64_t remaining = search_len;
    int64_t failures = 0;
    
    // 32-byte loop
    while (remaining >= 32) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        
        uint8x16_t d0 = vld1q_u8(search_ptr);
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);
        search_ptr += 32;
        remaining -= 32;
        
        uint8x16_t m0 = vceqq_u8(vorrq_u8(d0, v_mask), v_target);
        uint8x16_t m1 = vceqq_u8(vorrq_u8(d1, v_mask), v_target);
        
        uint8x16_t any = vorrq_u8(m0, m1);
        if (any_nonzero(any) == 0) continue;
        
        uint8x8_t n0 = vshrn_n_u16(vreinterpretq_u16_u8(m0), 4);
        uint64_t syn0 = vget_lane_u64(vreinterpret_u64_u8(n0), 0);
        while (syn0) {
            int bit_pos = __builtin_ctzll(syn0);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 32 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn0 &= ~((1ULL << clear_pos) - 1);
        }
        
        uint8x8_t n1 = vshrn_n_u16(vreinterpretq_u16_u8(m1), 4);
        uint64_t syn1 = vget_lane_u64(vreinterpret_u64_u8(n1), 0);
        while (syn1) {
            int bit_pos = __builtin_ctzll(syn1);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn1 &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // 16-byte loop
    while (remaining >= 16) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        
        uint8x16_t d = vld1q_u8(search_ptr);
        search_ptr += 16;
        remaining -= 16;
        
        uint8x16_t m = vceqq_u8(vorrq_u8(d, v_mask), v_target);
        uint8x8_t n = vshrn_n_u16(vreinterpretq_u16_u8(m), 4);
        uint64_t syn = vget_lane_u64(vreinterpret_u64_u8(n), 0);
        
        while (syn) {
            int bit_pos = __builtin_ctzll(syn);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = data_end - candidate;
                if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syn &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // Scalar tail
    uint8_t scalar_mask = rare1_is_letter ? 0x20 : 0x00;
    while (remaining > 0) {
        int64_t bytes_scanned = search_ptr - search_start;
        int64_t threshold = 16 + (bytes_scanned >> 4);
        int64_t pos = search_ptr - haystack - off1;
        
        if (((*search_ptr | scalar_mask) == rare1) && pos >= 0 && pos < search_len) {
            unsigned char *candidate = haystack + pos;
            int64_t cand_remaining = data_end - candidate;
            if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                return RESULT_FOUND(pos);
            }
            failures++;
            if (failures > threshold) {
                return RESULT_EXCEEDED(pos + 1);
            }
        }
        search_ptr++;
        remaining--;
    }
    
    return RESULT_NOT_FOUND;
}

// 2-byte search with case folding, raw needle (not pre-normalized)
// gocc: indexFold2ByteRaw(haystack string, needle string, off1 int, off2Delta int) uint64
uint64_t index_fold_2byte_raw(
    unsigned char *haystack, int64_t haystack_len,
    unsigned char *needle, int64_t needle_len,
    int64_t off1, int64_t off2_delta)
{
    if (haystack_len < needle_len) return RESULT_NOT_FOUND;
    if (needle_len == 0) return RESULT_FOUND(0);
    
    // Lowercase the rare bytes on-the-fly
    const uint8_t rare1_raw = needle[off1];
    const uint8_t rare2_raw = needle[off1 + off2_delta];
    const uint8_t rare1 = TO_LOWER(rare1_raw);
    const uint8_t rare2 = TO_LOWER(rare2_raw);
    const int rare1_is_letter = (unsigned)(rare1 - 'a') < 26;
    const int rare2_is_letter = (unsigned)(rare2 - 'a') < 26;
    const uint8_t mask1 = rare1_is_letter ? 0x20 : 0x00;
    const uint8_t mask2 = rare2_is_letter ? 0x20 : 0x00;
    const int64_t search_len = haystack_len - needle_len + 1;
    const uint8x16_t v_mask1 = vdupq_n_u8(mask1);
    const uint8x16_t v_mask2 = vdupq_n_u8(mask2);
    const uint8x16_t v_target1 = vdupq_n_u8(rare1);
    const uint8x16_t v_target2 = vdupq_n_u8(rare2);
    
    unsigned char *search_ptr = haystack + off1;
    int64_t remaining = search_len;
    int64_t failures = 0;
    
    // 64-byte loop
    while (remaining >= 64) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        
        uint8x16_t r1_0 = vld1q_u8(search_ptr);
        uint8x16_t r1_1 = vld1q_u8(search_ptr + 16);
        uint8x16_t r1_2 = vld1q_u8(search_ptr + 32);
        uint8x16_t r1_3 = vld1q_u8(search_ptr + 48);
        
        uint8x16_t r2_0 = vld1q_u8(search_ptr + off2_delta);
        uint8x16_t r2_1 = vld1q_u8(search_ptr + off2_delta + 16);
        uint8x16_t r2_2 = vld1q_u8(search_ptr + off2_delta + 32);
        uint8x16_t r2_3 = vld1q_u8(search_ptr + off2_delta + 48);
        
        search_ptr += 64;
        remaining -= 64;
        
        uint8x16_t m1_0 = vceqq_u8(vorrq_u8(r1_0, v_mask1), v_target1);
        uint8x16_t m1_1 = vceqq_u8(vorrq_u8(r1_1, v_mask1), v_target1);
        uint8x16_t m1_2 = vceqq_u8(vorrq_u8(r1_2, v_mask1), v_target1);
        uint8x16_t m1_3 = vceqq_u8(vorrq_u8(r1_3, v_mask1), v_target1);
        
        uint8x16_t m2_0 = vceqq_u8(vorrq_u8(r2_0, v_mask2), v_target2);
        uint8x16_t m2_1 = vceqq_u8(vorrq_u8(r2_1, v_mask2), v_target2);
        uint8x16_t m2_2 = vceqq_u8(vorrq_u8(r2_2, v_mask2), v_target2);
        uint8x16_t m2_3 = vceqq_u8(vorrq_u8(r2_3, v_mask2), v_target2);
        
        uint8x16_t both0 = vandq_u8(m1_0, m2_0);
        uint8x16_t both1 = vandq_u8(m1_1, m2_1);
        uint8x16_t both2 = vandq_u8(m1_2, m2_2);
        uint8x16_t both3 = vandq_u8(m1_3, m2_3);
        
        uint8x16_t any = vorrq_u8(vorrq_u8(both0, both1), vorrq_u8(both2, both3));
        if (any_nonzero(any) == 0) continue;
        
        uint8x16_t chunks[4] = {both0, both1, both2, both3};
        for (int chunk = 0; chunk < 4; chunk++) {
            uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(chunks[chunk]), 4);
            uint64_t syndrome = vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
            
            while (syndrome) {
                int bit_pos = __builtin_ctzll(syndrome);
                int byte_pos = bit_pos >> 2;
                int64_t pos = (search_ptr - 64 - haystack) + chunk * 16 + byte_pos - off1;
                
                if (pos >= 0 && pos < search_len) {
                    unsigned char *candidate = haystack + pos;
                    int64_t cand_remaining = haystack_len - pos;
                    if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                        return RESULT_FOUND(pos);
                    }
                    failures++;
                    if (failures > threshold) {
                        return RESULT_EXCEEDED(pos + 1);
                    }
                }
                int clear_pos = ((byte_pos + 1) << 2);
                syndrome &= ~((1ULL << clear_pos) - 1);
            }
        }
    }
    
    // 16-byte loop
    while (remaining >= 16) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        
        uint8x16_t r1 = vld1q_u8(search_ptr);
        uint8x16_t r2 = vld1q_u8(search_ptr + off2_delta);
        search_ptr += 16;
        remaining -= 16;
        
        uint8x16_t m1 = vceqq_u8(vorrq_u8(r1, v_mask1), v_target1);
        uint8x16_t m2 = vceqq_u8(vorrq_u8(r2, v_mask2), v_target2);
        uint8x16_t both = vandq_u8(m1, m2);
        
        uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(both), 4);
        uint64_t syndrome = vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
        
        while (syndrome) {
            int bit_pos = __builtin_ctzll(syndrome);
            int byte_pos = bit_pos >> 2;
            int64_t pos = (search_ptr - 16 - haystack) + byte_pos - off1;
            
            if (pos >= 0 && pos < search_len) {
                unsigned char *candidate = haystack + pos;
                int64_t cand_remaining = haystack_len - pos;
                if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                    return RESULT_FOUND(pos);
                }
                failures++;
                if (failures > threshold) {
                    return RESULT_EXCEEDED(pos + 1);
                }
            }
            int clear_pos = ((byte_pos + 1) << 2);
            syndrome &= ~((1ULL << clear_pos) - 1);
        }
    }
    
    // Scalar loop
    while (remaining > 0) {
        int64_t bytes_scanned = search_len - remaining;
        int64_t threshold = 32 + (bytes_scanned >> 3);
        int64_t pos = search_ptr - haystack - off1;
        
        uint8_t c1 = *search_ptr;
        uint8_t c2 = *(search_ptr + off2_delta);
        
        if (((c1 | mask1) == rare1) && ((c2 | mask2) == rare2) && pos >= 0 && pos < search_len) {
            unsigned char *candidate = haystack + pos;
            int64_t cand_remaining = haystack_len - pos;
            if (verify_fold(candidate, needle, needle_len, cand_remaining)) {
                return RESULT_FOUND(pos);
            }
            failures++;
            if (failures > threshold) {
                return RESULT_EXCEEDED(pos + 1);
            }
        }
        search_ptr++;
        remaining--;
    }
    
    return RESULT_NOT_FOUND;
}
