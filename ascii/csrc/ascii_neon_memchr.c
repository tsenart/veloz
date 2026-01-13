// NEON substring search - zero stack frame implementation
// All verification inlined to avoid function pointer overhead and spilling

#include <stdint.h>
#include <stdbool.h>
#include <arm_neon.h>

// =============================================================================
// INLINE VERIFICATION - always_inline ensures no call overhead
// =============================================================================

// SIMD verify with case-folding for both haystack and needle
__attribute__((always_inline))
static inline bool verify_fold_both(
    const unsigned char *hay, const unsigned char *needle,
    int64_t len, int64_t hay_remaining)
{
    if (len > hay_remaining) return false;
    
    const uint8x16_t v_32 = vdupq_n_u8(0x20);
    const uint8x16_t v_159 = vdupq_n_u8(159);
    const uint8x16_t v_26 = vdupq_n_u8(26);
    
    while (len >= 16) {
        uint8x16_t vh = vld1q_u8(hay);
        uint8x16_t vn = vld1q_u8(needle);
        uint8x16_t diff = veorq_u8(vh, vn);
        uint8x16_t is_case_diff = vceqq_u8(diff, v_32);
        uint8x16_t h_lower = vorrq_u8(vh, v_32);
        uint8x16_t h_minus_a = vaddq_u8(h_lower, v_159);
        uint8x16_t is_letter = vcltq_u8(h_minus_a, v_26);
        uint8x16_t case_mask = vandq_u8(vandq_u8(is_case_diff, is_letter), v_32);
        uint8x16_t final_diff = veorq_u8(diff, case_mask);
        if (vmaxvq_u8(final_diff)) return false;
        hay += 16; needle += 16; len -= 16;
    }
    
    for (int64_t i = 0; i < len; i++) {
        unsigned char h = hay[i];
        unsigned char n = needle[i];
        if (h >= 'A' && h <= 'Z') h |= 0x20;
        if (n >= 'A' && n <= 'Z') n |= 0x20;
        if (h != n) return false;
    }
    return true;
}

// SIMD verify for pre-normalized needle (needle already lowercase)
__attribute__((always_inline))
static inline bool verify_fold_normalized(
    const unsigned char *hay, const unsigned char *needle,
    int64_t len, int64_t hay_remaining)
{
    if (len > hay_remaining) return false;
    
    const uint8x16_t v_32 = vdupq_n_u8(0x20);
    
    while (len >= 16) {
        uint8x16_t vh = vld1q_u8(hay);
        uint8x16_t vn = vld1q_u8(needle);
        uint8x16_t vh_fold = vorrq_u8(vh, v_32);
        uint8x16_t diff = veorq_u8(vh_fold, vn);
        if (vmaxvq_u8(diff)) return false;
        hay += 16; needle += 16; len -= 16;
    }
    
    for (int64_t i = 0; i < len; i++) {
        unsigned char h = hay[i];
        unsigned char n = needle[i];
        if (h >= 'A' && h <= 'Z') h |= 0x20;
        if (h != n) return false;
    }
    return true;
}

// =============================================================================
// RABIN-KARP for tiny haystacks
// =============================================================================

__attribute__((always_inline))
static inline int64_t rabin_karp_fold(
    const unsigned char *haystack, int64_t haystack_len,
    const unsigned char *needle, int64_t needle_len)
{
    if (needle_len == 0) return 0;
    if (haystack_len < needle_len) return -1;
    
    for (int64_t i = 0; i <= haystack_len - needle_len; i++) {
        bool match = true;
        for (int64_t j = 0; j < needle_len && match; j++) {
            unsigned char h = haystack[i + j];
            unsigned char n = needle[j];
            if (h >= 'A' && h <= 'Z') h |= 0x20;
            if (n >= 'A' && n <= 'Z') n |= 0x20;
            if (h != n) match = false;
        }
        if (match) return i;
    }
    return -1;
}

__attribute__((always_inline))
static inline int64_t rabin_karp_fold_normalized(
    const unsigned char *haystack, int64_t haystack_len,
    const unsigned char *needle, int64_t needle_len)
{
    if (needle_len == 0) return 0;
    if (haystack_len < needle_len) return -1;
    
    for (int64_t i = 0; i <= haystack_len - needle_len; i++) {
        bool match = true;
        for (int64_t j = 0; j < needle_len && match; j++) {
            unsigned char h = haystack[i + j];
            unsigned char n = needle[j];
            if (h >= 'A' && h <= 'Z') h |= 0x20;
            if (h != n) match = false;
        }
        if (match) return i;
    }
    return -1;
}

// =============================================================================
// PUBLIC API: IndexFold - unified 64-byte loop, zero stack frame target
// =============================================================================

// gocc: IndexFoldMemchr(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
int64_t index_fold_memchr(
    unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1,
    uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    if (needle_len == 0) return 0;
    if (haystack_len < needle_len) return -1;
    if (haystack_len < 16) {
        return rabin_karp_fold(haystack, haystack_len, needle, needle_len);
    }
    
    const int64_t search_len = haystack_len - needle_len + 1;
    const unsigned char *data_end = haystack + haystack_len;
    
    register bool rare1_is_letter = (unsigned)(rare1 - 'a') < 26;
    register uint8_t rare1_mask = rare1_is_letter ? 0x20 : 0x00;
    
    const uint8x16_t v_mask = vdupq_n_u8(rare1_mask);
    const uint8x16_t v_target = vdupq_n_u8(rare1);
    
    const unsigned char *p = haystack + off1;
    const unsigned char *search_start = p;
    int64_t remaining = search_len;
    
    // 128-byte main loop for large inputs
    while (remaining >= 128 && p + 128 <= data_end) {
        // Load and compare first 64 bytes
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t v1 = vld1q_u8(p + 16);
        uint8x16_t v2 = vld1q_u8(p + 32);
        uint8x16_t v3 = vld1q_u8(p + 48);
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        uint8x16_t c1 = vceqq_u8(vorrq_u8(v1, v_mask), v_target);
        uint8x16_t c2 = vceqq_u8(vorrq_u8(v2, v_mask), v_target);
        uint8x16_t c3 = vceqq_u8(vorrq_u8(v3, v_mask), v_target);
        uint8x16_t or0123 = vorrq_u8(vorrq_u8(c0, c1), vorrq_u8(c2, c3));
        
        // Load and compare second 64 bytes
        uint8x16_t v4 = vld1q_u8(p + 64);
        uint8x16_t v5 = vld1q_u8(p + 80);
        uint8x16_t v6 = vld1q_u8(p + 96);
        uint8x16_t v7 = vld1q_u8(p + 112);
        uint8x16_t c4 = vceqq_u8(vorrq_u8(v4, v_mask), v_target);
        uint8x16_t c5 = vceqq_u8(vorrq_u8(v5, v_mask), v_target);
        uint8x16_t c6 = vceqq_u8(vorrq_u8(v6, v_mask), v_target);
        uint8x16_t c7 = vceqq_u8(vorrq_u8(v7, v_mask), v_target);
        uint8x16_t or4567 = vorrq_u8(vorrq_u8(c4, c5), vorrq_u8(c6, c7));
        
        // Quick check: any matches in 128 bytes?
        uint8x16_t any_all = vorrq_u8(or0123, or4567);
        uint64x2_t any64 = vreinterpretq_u64_u8(any_all);
        if ((vgetq_lane_u64(any64, 0) | vgetq_lane_u64(any64, 1)) == 0) {
            p += 128;
            remaining -= 128;
            continue;
        }
        
        // Process first 64 bytes if any matches
        uint64x2_t first64 = vreinterpretq_u64_u8(or0123);
        if (vgetq_lane_u64(first64, 0) | vgetq_lane_u64(first64, 1)) {
            uint64_t syn;
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c1), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 16 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c2), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 32 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c3), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 48 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
        }
        
        // Process second 64 bytes if any matches
        uint64x2_t second64 = vreinterpretq_u64_u8(or4567);
        if (vgetq_lane_u64(second64, 0) | vgetq_lane_u64(second64, 1)) {
            uint64_t syn;
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c4), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 64 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c5), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 80 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c6), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 96 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c7), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 112 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
        }
        
        p += 128;
        remaining -= 128;
    }
    
    // 64-byte loop for remaining
    while (remaining >= 64 && p + 64 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t v1 = vld1q_u8(p + 16);
        uint8x16_t v2 = vld1q_u8(p + 32);
        uint8x16_t v3 = vld1q_u8(p + 48);
        
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        uint8x16_t c1 = vceqq_u8(vorrq_u8(v1, v_mask), v_target);
        uint8x16_t c2 = vceqq_u8(vorrq_u8(v2, v_mask), v_target);
        uint8x16_t c3 = vceqq_u8(vorrq_u8(v3, v_mask), v_target);
        
        uint8x16_t any_all = vorrq_u8(vorrq_u8(c0, c1), vorrq_u8(c2, c3));
        uint64x2_t any64 = vreinterpretq_u64_u8(any_all);
        
        if ((vgetq_lane_u64(any64, 0) | vgetq_lane_u64(any64, 1)) == 0) {
            p += 64;
            remaining -= 64;
            continue;
        }
        
        uint64_t syn;
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c1), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 16 + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c2), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 32 + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c3), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 48 + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        
        p += 64;
        remaining -= 64;
    }
    
    // 32-byte tail
    while (remaining >= 32 && p + 32 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t v1 = vld1q_u8(p + 16);
        
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        uint8x16_t c1 = vceqq_u8(vorrq_u8(v1, v_mask), v_target);
        
        uint8x16_t any = vorrq_u8(c0, c1);
        uint64x2_t any64 = vreinterpretq_u64_u8(any);
        uint64_t any_scalar = vgetq_lane_u64(any64, 0) | vgetq_lane_u64(any64, 1);
        
        if (any_scalar == 0) {
            p += 32;
            remaining -= 32;
            continue;
        }
        
        uint64_t syn0 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
        uint64_t syn1 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c1), 4)), 0);
        
        while (syn0) {
            int bit = __builtin_ctzll(syn0);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + bpos;
            if (pos >= 0 && pos < search_len) {
                const unsigned char *cand = haystack + pos;
                int64_t crem = data_end - cand;
                if (verify_fold_both(cand, needle, needle_len, crem)) return pos;
            }
            syn0 &= ~(0xFULL << (bpos * 4));
        }
        
        while (syn1) {
            int bit = __builtin_ctzll(syn1);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 16 + bpos;
            if (pos >= 0 && pos < search_len) {
                const unsigned char *cand = haystack + pos;
                int64_t crem = data_end - cand;
                if (verify_fold_both(cand, needle, needle_len, crem)) return pos;
            }
            syn1 &= ~(0xFULL << (bpos * 4));
        }
        
        p += 32;
        remaining -= 32;
    }
    
    // 16-byte loop for tail
    while (remaining >= 16 && p + 16 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        
        uint64x2_t c64 = vreinterpretq_u64_u8(c0);
        if ((vgetq_lane_u64(c64, 0) | vgetq_lane_u64(c64, 1)) == 0) {
            p += 16;
            remaining -= 16;
            continue;
        }
        
        uint64_t syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_both(haystack + pos, needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        p += 16;
        remaining -= 16;
    }
    
    // Scalar tail (< 16 bytes)
    while (remaining > 0 && p < data_end) {
        unsigned char c = *p;
        if ((c | rare1_mask) == rare1) {
            int64_t pos = p - search_start;
            if (pos >= 0 && pos < search_len) {
                const unsigned char *cand = haystack + pos;
                int64_t crem = data_end - cand;
                if (verify_fold_both(cand, needle, needle_len, crem)) return pos;
            }
        }
        p++;
        remaining--;
    }
    
    return -1;
}

// =============================================================================
// PUBLIC API: Searcher.IndexFold (needle pre-normalized)
// =============================================================================

// gocc: SearcherIndexFoldMemchr(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, normNeedle string) int
int64_t searcher_index_fold_memchr(
    unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1,
    uint8_t rare2, int64_t off2,
    unsigned char *norm_needle, int64_t needle_len)
{
    if (needle_len == 0) return 0;
    if (haystack_len < needle_len) return -1;
    if (haystack_len < 16) {
        return rabin_karp_fold_normalized(haystack, haystack_len, norm_needle, needle_len);
    }
    
    const int64_t search_len = haystack_len - needle_len + 1;
    const unsigned char *data_end = haystack + haystack_len;
    
    bool rare1_is_letter = (unsigned)(rare1 - 'a') < 26;
    uint8_t rare1_mask = rare1_is_letter ? 0x20 : 0x00;
    
    const uint8x16_t v_mask = vdupq_n_u8(rare1_mask);
    const uint8x16_t v_target = vdupq_n_u8(rare1);
    
    const unsigned char *p = haystack + off1;
    const unsigned char *search_start = p;
    int64_t remaining = search_len;
    
    // 128-byte main loop for large inputs
    while (remaining >= 128 && p + 128 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t v1 = vld1q_u8(p + 16);
        uint8x16_t v2 = vld1q_u8(p + 32);
        uint8x16_t v3 = vld1q_u8(p + 48);
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        uint8x16_t c1 = vceqq_u8(vorrq_u8(v1, v_mask), v_target);
        uint8x16_t c2 = vceqq_u8(vorrq_u8(v2, v_mask), v_target);
        uint8x16_t c3 = vceqq_u8(vorrq_u8(v3, v_mask), v_target);
        uint8x16_t or0123 = vorrq_u8(vorrq_u8(c0, c1), vorrq_u8(c2, c3));
        
        uint8x16_t v4 = vld1q_u8(p + 64);
        uint8x16_t v5 = vld1q_u8(p + 80);
        uint8x16_t v6 = vld1q_u8(p + 96);
        uint8x16_t v7 = vld1q_u8(p + 112);
        uint8x16_t c4 = vceqq_u8(vorrq_u8(v4, v_mask), v_target);
        uint8x16_t c5 = vceqq_u8(vorrq_u8(v5, v_mask), v_target);
        uint8x16_t c6 = vceqq_u8(vorrq_u8(v6, v_mask), v_target);
        uint8x16_t c7 = vceqq_u8(vorrq_u8(v7, v_mask), v_target);
        uint8x16_t or4567 = vorrq_u8(vorrq_u8(c4, c5), vorrq_u8(c6, c7));
        
        uint8x16_t any_all = vorrq_u8(or0123, or4567);
        uint64x2_t any64 = vreinterpretq_u64_u8(any_all);
        if ((vgetq_lane_u64(any64, 0) | vgetq_lane_u64(any64, 1)) == 0) {
            p += 128;
            remaining -= 128;
            continue;
        }
        
        uint64x2_t first64 = vreinterpretq_u64_u8(or0123);
        if (vgetq_lane_u64(first64, 0) | vgetq_lane_u64(first64, 1)) {
            uint64_t syn;
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c1), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 16 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c2), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 32 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c3), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 48 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
        }
        
        uint64x2_t second64 = vreinterpretq_u64_u8(or4567);
        if (vgetq_lane_u64(second64, 0) | vgetq_lane_u64(second64, 1)) {
            uint64_t syn;
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c4), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 64 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c5), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 80 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c6), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 96 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
            syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c7), 4)), 0);
            while (syn) {
                int bit = __builtin_ctzll(syn);
                int bpos = bit >> 2;
                int64_t pos = (p - search_start) + 112 + bpos;
                if (pos >= 0 && pos < search_len) {
                    if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
                }
                syn &= ~(0xFULL << (bpos * 4));
            }
        }
        
        p += 128;
        remaining -= 128;
    }
    
    // 64-byte loop for remaining
    while (remaining >= 64 && p + 64 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t v1 = vld1q_u8(p + 16);
        uint8x16_t v2 = vld1q_u8(p + 32);
        uint8x16_t v3 = vld1q_u8(p + 48);
        
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        uint8x16_t c1 = vceqq_u8(vorrq_u8(v1, v_mask), v_target);
        uint8x16_t c2 = vceqq_u8(vorrq_u8(v2, v_mask), v_target);
        uint8x16_t c3 = vceqq_u8(vorrq_u8(v3, v_mask), v_target);
        
        uint8x16_t any_all = vorrq_u8(vorrq_u8(c0, c1), vorrq_u8(c2, c3));
        uint64x2_t any64 = vreinterpretq_u64_u8(any_all);
        
        if ((vgetq_lane_u64(any64, 0) | vgetq_lane_u64(any64, 1)) == 0) {
            p += 64;
            remaining -= 64;
            continue;
        }
        
        uint64_t syn;
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c1), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 16 + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c2), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 32 + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c3), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 48 + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        
        p += 64;
        remaining -= 64;
    }
    
    // 32-byte tail
    while (remaining >= 32 && p + 32 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t v1 = vld1q_u8(p + 16);
        
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        uint8x16_t c1 = vceqq_u8(vorrq_u8(v1, v_mask), v_target);
        
        uint8x16_t any = vorrq_u8(c0, c1);
        uint64x2_t any64 = vreinterpretq_u64_u8(any);
        uint64_t any_scalar = vgetq_lane_u64(any64, 0) | vgetq_lane_u64(any64, 1);
        
        if (any_scalar == 0) {
            p += 32;
            remaining -= 32;
            continue;
        }
        
        uint64_t syn0 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
        uint64_t syn1 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c1), 4)), 0);
        
        while (syn0) {
            int bit = __builtin_ctzll(syn0);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + bpos;
            if (pos >= 0 && pos < search_len) {
                const unsigned char *cand = haystack + pos;
                int64_t crem = data_end - cand;
                if (verify_fold_normalized(cand, norm_needle, needle_len, crem)) return pos;
            }
            syn0 &= ~(0xFULL << (bpos * 4));
        }
        
        while (syn1) {
            int bit = __builtin_ctzll(syn1);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + 16 + bpos;
            if (pos >= 0 && pos < search_len) {
                const unsigned char *cand = haystack + pos;
                int64_t crem = data_end - cand;
                if (verify_fold_normalized(cand, norm_needle, needle_len, crem)) return pos;
            }
            syn1 &= ~(0xFULL << (bpos * 4));
        }
        
        p += 32;
        remaining -= 32;
    }
    
    // 16-byte loop for tail
    while (remaining >= 16 && p + 16 <= data_end) {
        uint8x16_t v0 = vld1q_u8(p);
        uint8x16_t c0 = vceqq_u8(vorrq_u8(v0, v_mask), v_target);
        
        uint64x2_t c64 = vreinterpretq_u64_u8(c0);
        if ((vgetq_lane_u64(c64, 0) | vgetq_lane_u64(c64, 1)) == 0) {
            p += 16;
            remaining -= 16;
            continue;
        }
        
        uint64_t syn = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(c0), 4)), 0);
        while (syn) {
            int bit = __builtin_ctzll(syn);
            int bpos = bit >> 2;
            int64_t pos = (p - search_start) + bpos;
            if (pos >= 0 && pos < search_len) {
                if (verify_fold_normalized(haystack + pos, norm_needle, needle_len, data_end - haystack - pos)) return pos;
            }
            syn &= ~(0xFULL << (bpos * 4));
        }
        p += 16;
        remaining -= 16;
    }
    
    // Scalar tail (< 16 bytes)
    while (remaining > 0 && p < data_end) {
        unsigned char c = *p;
        if ((c | rare1_mask) == rare1) {
            int64_t pos = p - search_start;
            if (pos >= 0 && pos < search_len) {
                const unsigned char *cand = haystack + pos;
                int64_t crem = data_end - cand;
                if (verify_fold_normalized(cand, norm_needle, needle_len, crem)) return pos;
            }
        }
        p++;
        remaining--;
    }
    
    return -1;
}
