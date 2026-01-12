#include <stdint.h>
#include <stdbool.h>
#include <arm_neon.h>

// IndexAny using 256-bit bitset approach.
// Supports unlimited search chars with consistent O(n) performance.
// The bitset is passed pre-built from Go to avoid stack arrays in C.
//
// gocc: indexAnyNeonBitset(data string, bitset0 uint64, bitset1 uint64, bitset2 uint64, bitset3 uint64) int
int64_t index_any_neon_bitset(unsigned char *data, uint64_t data_len, 
    uint64_t bitset0, uint64_t bitset1, uint64_t bitset2, uint64_t bitset3)
{
    if (data_len == 0) {
        return -1;
    }

    const uint64_t blockSize = 16;
    const unsigned char *data_start = data;
    
    // Build 256-bit bitset from 4 uint64s - fits in 2 NEON registers for TBL2
    uint8x16x2_t bitset;
    bitset.val[0] = vcombine_u8(vcreate_u8(bitset0), vcreate_u8(bitset1));
    bitset.val[1] = vcombine_u8(vcreate_u8(bitset2), vcreate_u8(bitset3));
    
    // Mask to extract bit position (0-7) and index (0-31)
    const uint8x16_t mask7 = vdupq_n_u8(7);
    const uint8x16_t mask31 = vdupq_n_u8(31);
    
    // Bit position lookup table: 1<<0, 1<<1, ..., 1<<7 (repeated for 16 bytes)
    // In little-endian: byte 0 = 0x01, byte 1 = 0x02, ..., byte 7 = 0x80
    const uint8x16_t bit_lut = vcombine_u8(
        vcreate_u8(0x8040201008040201ULL),
        vcreate_u8(0x8040201008040201ULL)
    );
    
    // Process 16 bytes at a time
    for (const unsigned char *data_end = (data + data_len) - (data_len % blockSize); data < data_end; data += blockSize)
    {
        uint8x16_t d = vld1q_u8(data);
        
        // idx = d >> 3 (which byte in 32-byte bitset, masked to 0-31)
        uint8x16_t idx = vandq_u8(vshrq_n_u8(d, 3), mask31);
        
        // bit_pos = d & 7 (which bit within that byte)
        uint8x16_t bit_pos = vandq_u8(d, mask7);
        
        // Look up the bitset byte for each lane
        uint8x16_t bitset_bytes = vqtbl2q_u8(bitset, idx);
        
        // Look up the bit mask for each lane (bit_lut[bit_pos] = 1 << bit_pos)
        uint8x16_t bit_masks = vqtbl1q_u8(bit_lut, bit_pos);
        
        // Check if the bit is set: (bitset_bytes & bit_masks) != 0
        uint8x16_t match = vtstq_u8(bitset_bytes, bit_masks);
        
        // Check if any match found
        uint64_t match64 = vget_lane_u64(vshrn_n_u16(match, 4), 0);
        if (match64) {
            int pos = __builtin_ctzll(match64) / 4;
            return (data - data_start) + pos;
        }
    }
    data_len %= blockSize;
    
    // Handle remainder with scalar bitset lookup
    for (uint64_t i = 0; i < data_len; i++) {
        unsigned char c = data[i];
        uint64_t word;
        switch (c >> 6) {
            case 0: word = bitset0; break;
            case 1: word = bitset1; break;
            case 2: word = bitset2; break;
            default: word = bitset3; break;
        }
        if (word & (1ULL << (c & 63))) {
            return (data - data_start) + i;
        }
    }
    
    return -1;
}



// gocc: ValidString(data string) bool
bool ascii_valid_string(unsigned char *data, uint64_t length)
{
    const uint64_t blockSize = 16; // NEON can process 128 bits (16 bytes) at a time
    const uint64_t ld4BlockSize = blockSize * 4;

    if (length >= blockSize)
    {
        const uint8x16_t msb_mask = vdupq_n_u8(0x80); // Create a mask for the MSB

#ifndef SKIP_LD1x4
        for (const unsigned char *data64_end = (data + length) - (length % ld4BlockSize); data < data64_end; data += ld4BlockSize)
        {
            uint8x16x4_t blocks = vld1q_u8_x4(data);           // Load 64 bytes of data
            blocks.val[0] = vtstq_u8(blocks.val[0], msb_mask); // AND with the mask to isolate MSB
            blocks.val[1] = vtstq_u8(blocks.val[1], msb_mask); // AND with the mask to isolate MSB
            blocks.val[2] = vtstq_u8(blocks.val[2], msb_mask); // AND with the mask to isolate MSB
            blocks.val[3] = vtstq_u8(blocks.val[3], msb_mask); // AND with the mask to isolate MSB

            uint8x16_t result = vorrq_u8(vorrq_u8(blocks.val[0], blocks.val[1]), vorrq_u8(blocks.val[2], blocks.val[3])); // OR the results
            // SHRN can be faster than UMAXV
            if (vget_lane_u64(vshrn_n_u16(result, 4), 0) > 0)
            {
                return false;
            }
        }
        length %= ld4BlockSize;
#endif
        for (const unsigned char *data16_end = (data + length) - (length % blockSize); data < data16_end; data += blockSize)
        {
            uint8x16_t block = vld1q_u8(data);             // Load 16 bytes of data
            uint8x16_t result = vtstq_u8(block, msb_mask); // AND with the mask to isolate MSB
            // SHRN can be faster than UMAXV
            if (vget_lane_u64(vshrn_n_u16(result, 4), 0) > 0)
            {
                return false;
            }
        }
        length %= blockSize;
    }

    if (length & 8)
    {
        uint64_t lo64, hi64;
        uint8_t *data_end = data + length;
        __builtin_memcpy(&lo64, data, sizeof(lo64));
        __builtin_memcpy(&hi64, data_end - 8, sizeof(hi64));

        uint64_t data64 = lo64 | hi64;
        return (data64 & 0x8080808080808080ull) ? false : true;
    }

    if (length & 4)
    {
        uint32_t lo32, hi32;
        uint8_t *data_end = data + length;
        __builtin_memcpy(&lo32, data, sizeof(lo32));
        __builtin_memcpy(&hi32, data_end - 4, sizeof(hi32));

        uint32_t data32 = lo32 | hi32;
        return (data32 & 0x80808080) ? false : true;
    }

    if (length == 0) return true;

    uint32_t data32 = 0;

    // branchless check for 1-3 bytes
    uint8_t *data_end = data + length;
    int idx = length >> 1;
    data32 |= data[0];
    data32 |= data[idx];
    data32 |= data_end[-1];

    return (data32 & 0x80808080) ? false : true;
}

// gocc: IndexMask(data string, mask byte) int
int64_t index_mask(unsigned char *data, uint64_t length, uint8_t mask)
{
    const uint64_t blockSize = 16; // NEON can process 128 bits (16 bytes) at a time
    const uint64_t ld4BlockSize = blockSize * 4;

    const unsigned char *data_start = data;
    
    if (length >= blockSize)
    {
        uint8x16_t mask_vec = vdupq_n_u8(mask); // Create a vector mask
#ifndef SKIP_LD1x4
        for (const unsigned char *data64_end = (data + length) - (length % ld4BlockSize); data < data64_end; data += ld4BlockSize)
        {
            uint8x16x4_t blocks = vld1q_u8_x4(data);       // Load 64 bytes of data
            blocks.val[0] = vtstq_u8(blocks.val[0], mask_vec); // AND with the mask
            blocks.val[1] = vtstq_u8(blocks.val[1], mask_vec); // AND with the mask
            blocks.val[2] = vtstq_u8(blocks.val[2], mask_vec); // AND with the mask
            blocks.val[3] = vtstq_u8(blocks.val[3], mask_vec); // AND with the mask

            uint8x16_t result = vorrq_u8(vorrq_u8(blocks.val[0], blocks.val[1]), vorrq_u8(blocks.val[2], blocks.val[3])); // OR the results
            // SHRN can be faster than UMAXV
            if (vget_lane_u64(vshrn_n_u16(result, 4), 0) > 0)
            {
                // now a few operations to find the index of the first set bit
                for (int j = 0; j < 4; j++)
                {
                    uint64_t data64 = vget_lane_u64(vshrn_n_u16(blocks.val[j], 4), 0);
                    if (data64 != 0)
                    {
                        int64_t offset = j*16 + __builtin_ctzll(data64) / 4;
                        return (data - data_start) + offset;
                    }
                }
            }
        }
        length %= ld4BlockSize;
#endif
        for (const unsigned char *data16_end = (data + length) - (length % blockSize); data < data16_end; data += blockSize)
        {
            uint8x16_t block = vld1q_u8(data);         // Load 16 bytes of data
            uint8x16_t result = vtstq_u8(block, mask_vec); // AND with the mask

            // SHRN can be faster than UMAXV
            uint64_t data64 = vget_lane_u64(vshrn_n_u16(result, 4), 0);
            if (data64 > 0)
            {
                int offset = __builtin_ctzll(data64) / 4;
                return (data - data_start) + offset;
            }
        }
        length %= blockSize;
    }

    uint32_t mask32 = mask;
    mask32 |= mask32 << 8;
    mask32 |= mask32 << 16;

    if (length >= 8)
    {
        uint64_t mask64 = mask32;
        mask64 |= mask64 << 32;
        
        uint64_t data64 = *(uint64_t *)(data);
        data64 &= mask64;
        if (data64 != 0)
        {
            return (data - data_start) + __builtin_ctzll(data64) / 8;
        }
        data += 8;
        length -= 8;
    }

    uint32_t data32;

    if (length >= 4)
    {
        data32 = *(uint32_t *)(data);
        data32 &= mask32;
        if (data32 != 0)
        {
            return (data - data_start) + __builtin_ctz(data32) / 8;
        }
        data += 4;
        length -= 4;
    }

    // Handle the remaining bytes (if any)
    switch (length)
    {
    case 3:
        data32 = *(uint16_t *)(data);
        data32 |= data[2] << 16;
        break;
    case 2:
        data32 = *(uint16_t *)(data);
        break;
    case 1:
        data32 = (uint32_t)*data;
        break;
    default:
        data32 = 0;
        break;
    }

    data32 &= mask32;
    if (data32)
    {
        return (data - data_start) + __builtin_ctz(data32) / 8;
    }

    return -1;
}

static uint8_t uppercasingTable[32] = {
    0,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,
    32,32,32,32,32,32,32,32,32,32,32,0, 0, 0, 0, 0,
};

static inline bool equal_fold_core(unsigned char *a, unsigned char *b, int64_t length,
    const uint8x16x2_t table, const uint8x16_t shift)
{
    const uint64_t blockSize = 16; // NEON can process 128 bits (16 bytes) at a time

    if (length < 0) return false;

    for (const unsigned char *data_bound = (a + length) - (length % blockSize); a < data_bound; a += blockSize, b += blockSize)
    {
        uint8x16_t a_data = vld1q_u8(a); // Load 16 bytes of data
        uint8x16_t b_data = vld1q_u8(b); // Load 16 bytes of data

        a_data = vsubq_u8(a_data, shift);
        a_data = vsubq_u8(a_data, vqtbl2q_u8(table, a_data));

        b_data = vsubq_u8(b_data, shift);
        b_data = vsubq_u8(b_data, vqtbl2q_u8(table, b_data));

        // we should shift the data back, but we just need to compare, so we can skip that
        const uint8x16_t result = vceqq_u8(a_data, b_data);

        // SHRN can be faster than UMAXV
        if (vget_lane_u64(vshrn_n_u16(result, 4), 0) != ~0ull)
        {
            return false;
        }
    }
    length %= blockSize;

    // same as above, but with just half the vector register
    if (length >= 8)
    {
        uint8x8_t a_data = vld1_u8(a);
        uint8x8_t b_data = vld1_u8(b);

        a_data = vsub_u8(a_data, vget_low_u8(shift));
        a_data = vsub_u8(a_data, vqtbl2_u8(table, a_data));

        b_data = vsub_u8(b_data, vget_low_u8(shift));
        b_data = vsub_u8(b_data, vqtbl2_u8(table, b_data));

        // we should shift the data back, but we just need to compare, so we can skip that
        const uint8x8_t result = vceq_u8(a_data, b_data);

        // Check if there's any 0 bytes
        if (vget_lane_u64(result, 0) != ~0ull)
        {
            return false;
        }
        a += 8;
        b += 8;
        length %= 8;
    }

    if (length == 0) {
        return true;
    }

    uint64_t a_data64 = 0;
    uint64_t b_data64 = 0;

    if (length >= 4)
    {
        a_data64 = *(uint32_t *)(a);
        a += 4;
        b_data64 = *(uint32_t *)(b);
        b += 4;
        length -= 4;
    }

    // FIXME: this is reordering the bytes, though does it for both a and b, so it's fine
    switch (length)
    {
    case 3:
        a_data64 <<= 24;
        a_data64 |= *(uint16_t *)(a) << 8;
        a_data64 |= a[2];
        // same for b
        b_data64 <<= 24;
        b_data64 |= *(uint16_t *)(b) << 8;
        b_data64 |= b[2];
        break;
    case 2:
        a_data64 <<= 16;
        a_data64 |= *(uint16_t *)(a);
        // same for b
        b_data64 <<= 16;
        b_data64 |= *(uint16_t *)(b);
        break;
    case 1:
        a_data64 <<= 8;
        a_data64 |= *a;
        // same for b
        b_data64 <<= 8;
        b_data64 |= *b;
        break;
    }

    uint8x8_t a_data = vcreate_u8(a_data64);
    uint8x8_t b_data = vcreate_u8(b_data64);

    a_data = vsub_u8(a_data, vget_low_u8(shift));
    a_data = vsub_u8(a_data, vqtbl2_u8(table, a_data));

    b_data = vsub_u8(b_data, vget_low_u8(shift));
    b_data = vsub_u8(b_data, vqtbl2_u8(table, b_data));

    // we should shift the data back, but we just need to compare, so we can skip that
    const uint8x8_t result = vceq_u8(a_data, b_data);

    // Check if there's any 0 bytes
    if (vget_lane_u64(result, 0) != ~0ull)
    {
        return false;
    }

    return true;
}

// gocc: EqualFold(a, b string) bool
bool equal_fold(unsigned char *a, uint64_t a_len, unsigned char *b, uint64_t b_len)
{
    if (a_len != b_len)
    {
        return false;
    }

    const uint8x16x2_t table = vld1q_u8_x2(uppercasingTable);
    const uint8x16_t shift = vdupq_n_u8(0x60);

    return equal_fold_core(a, b, a_len, table, shift);
}

// loads up to 16 bytes of data into a 128-bit register
static inline uint8x16_t load_data16(const unsigned char *src, int64_t len) {
    if (len >= 16) {
        return vld1q_u8(src);
    } else if (len == 8) {
        return vcombine_u64(vld1_u64((uint64_t *)src), vcreate_u64(0));
    } else if (len <= 0) {
        return vdupq_n_u8(0);
    }

    const uint64_t orig_len = len;
    uint64_t data64 = 0;
    uint64_t data64lo;

    if (len & 8) {
        data64lo = *(uint64_t *)(src);
        src += 8;
        len -= 8;
    }

    if (len & 4) {
        data64 = *(uint32_t *)(src);
        src += 4;
        len -= 4;
    }

    uint64_t tmp;
    switch (len) {
    case 3:
        tmp = *(uint16_t *)(src);
        int shift = 8 * (orig_len & 4);
        data64 |= tmp << shift;
        tmp = src[2];
        data64 |= tmp << (16 + shift);
        break;
    case 2:
        tmp = *(uint16_t *)(src);
        data64 |= tmp << (8 * (orig_len & 4));
        break;
    case 1:
        tmp = *src;
        data64 |= tmp << (8 * (orig_len & 4));
        break;
    }

    if (orig_len < 8) {
        return vcombine_u64(vcreate_u64(data64), vcreate_u64(0));
    }
    return vcombine_u64(vcreate_u64(data64lo), vcreate_u64(data64));
}

// loads up to 16 bytes of data into a 128-bit register
// requires stack space for 2 64-bit integers, gocc has trouble with that
static inline uint8x16_t load_data16_v2(const unsigned char *src, int64_t len) {
    if (len >= 16) {
        return vld1q_u8(src);
    } else if (len <= 0) {
        return vdupq_n_u8(0);
    }

    const uint64_t orig_len = len;
    const uint8_t *src_end = src + len;
    uint64_t buf[2] = {0};

    uint8_t *dst = (uint8_t *)&buf[0];
    uint8_t *dst_end = dst + len;

    if (len & 8) {
        // Copy 8-15 bytes when the 4th bit of length is set (length >= 8)
        uint64_t lo64, hi64;
        __builtin_memcpy(&lo64, src, sizeof(lo64));
        __builtin_memcpy(&hi64, src_end - 8, sizeof(hi64));
        __builtin_memcpy(dst, &lo64, sizeof(lo64));
        __builtin_memcpy(dst_end - 8, &hi64, sizeof(hi64));

        return vld1q_u8(dst);
    }

    if (len & 4) {
        // Copy 4-7 bytes when the 3rd bit of length is set (length >= 4)
        uint32_t lo32, hi32;
        __builtin_memcpy(&lo32, src, sizeof(lo32));
        __builtin_memcpy(&hi32, src_end - 4, sizeof(hi32));
        __builtin_memcpy(dst, &lo32, sizeof(lo32));
        __builtin_memcpy(dst_end - 4, &hi32, sizeof(hi32));

        return vld1q_u8(dst);
    }

    // Copy 1-3 bytes
    int idx = len >> 1;
    dst[0] = src[0];
    dst[idx] = src[idx];
    dst_end[-1] = src_end[-1];

    return vld1q_u8(dst);
}

// =============================================================================
// SIMD Rabin-Karp with Sills' unscaled hash + clausecker's NEON parallelism
// =============================================================================
// Key insight from Sills: Instead of scaling hash each iteration (H_{n+1} = B*H_n + ...),
// use unscaled hash H'_n = H_n * B^n. This moves the multiply out of the critical path.
// Recurrence: H'_{n+1} = H'_n + a_{n+w}*B^{n+w} - a_n*B^n
// To compare: H'_n == target * B^n
//
// Key insight from clausecker: Process 4 parallel hash streams using NEON uint32x4_t.
// Base B=31 is shift-friendly: x*31 = (x<<5) - x

// Case-fold lookup table: 'a'-'z' -> 'A'-'Z', others unchanged
static const uint8_t fold_table[256] = {
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
    96,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255,
};

// Case-fold a byte using lookup table (no branches)
static inline uint8_t fold_byte(uint8_t c) {
    return fold_table[c];
}

// Case-fold 16 bytes using NEON
static inline uint8x16_t fold_bytes_neon(uint8x16_t v) {
    const uint8x16_t char_a = vdupq_n_u8('a');
    const uint8x16_t char_z = vdupq_n_u8('z');
    const uint8x16_t mask = vdupq_n_u8(0xDF);
    
    // is_lower = (v >= 'a') & (v <= 'z')
    uint8x16_t ge_a = vcgeq_u8(v, char_a);
    uint8x16_t le_z = vcleq_u8(v, char_z);
    uint8x16_t is_lower = vandq_u8(ge_a, le_z);
    
    // Clear bit 5 for lowercase letters
    return vbslq_u8(is_lower, vandq_u8(v, mask), v);
}

// Use same prime as Go stdlib for better hash distribution
#define PRIME_RK 16777619

// Compute B^n mod 2^32 using repeated squaring
static inline uint32_t pow_prime(uint64_t n) {
    uint32_t result = 1;
    uint32_t base = PRIME_RK;
    while (n > 0) {
        if (n & 1) result *= base;
        base *= base;
        n >>= 1;
    }
    return result;
}

// Compute hash of needle (case-folded) using standard Rabin-Karp formula
// H = a_0*B^{w-1} + a_1*B^{w-2} + ... + a_{w-1}
static inline uint32_t hash_needle_fold(const unsigned char *needle, int64_t needle_len) {
    uint32_t hash = 0;
    for (int64_t i = 0; i < needle_len; i++) {
        hash = hash * PRIME_RK + fold_table[needle[i]];
    }
    return hash;
}

// =============================================================================
// SIMD Rabin-Karp with reversed polynomial (Matt Sills' optimization)
// =============================================================================
// Standard RK: H[n+1] = B * H[n] + new - B^w * old  (multiply on critical path)
// Reversed:    H'[n+1] = H'[n] + new * B^(n+w) - old * B^n  (only add/sub on critical path)
// Compare:     H'[n] == target * B^n
//
// This eliminates the loop-carried multiply dependency, allowing all multiplications
// to be issued in parallel since they only depend on the input bytes and exponents.

// Compute reversed polynomial hash with case folding: H' = sum(fold(s[j]) * B^j) for j in [0, len)
static inline uint32_t hash_reversed_fold(const unsigned char *s, int64_t len) {
    uint32_t h = 0;
    uint32_t Bj = 1;  // B^j
    for (int64_t j = 0; j < len; j++) {
        h += fold_table[s[j]] * Bj;
        Bj *= PRIME_RK;
    }
    return h;
}

// Standard Rabin-Karp hash function (for position-independent hashes)
static inline uint32_t hash_rk_fold(const unsigned char *s, int64_t len) {
    uint32_t h = 0;
    for (int64_t j = 0; j < len; j++) {
        h = h * PRIME_RK + fold_table[s[j]];
    }
    return h;
}

// gocc: indexFoldRabinKarp(haystack string, needle string) int
int64_t index_fold_rabin_karp_simd(unsigned char *haystack, int64_t haystack_len,
                                    unsigned char *needle, int64_t needle_len)
{
    if (needle_len <= 0) return 0;
    if (haystack_len < needle_len) return -1;
    
    const int64_t search_len = haystack_len - needle_len + 1;
    const int64_t w = needle_len;
    
    // For SIMD verification
    const uint8x16x2_t table = vld1q_u8_x2(uppercasingTable);
    const uint8x16_t vtbl_shift = vdupq_n_u8(0x60);
    
    // Precompute constants for standard Rabin-Karp
    const uint32_t B = PRIME_RK;
    const uint32_t B2 = B * B;
    const uint32_t B3 = B2 * B;
    const uint32_t B4 = B3 * B;
    const uint32_t Bw = pow_prime(w);
    const uint32_t antisigma = -Bw;  // -B^w mod 2^32
    
    // Compute target hash (case-folded)
    const uint32_t target_hash = hash_rk_fold(needle, needle_len);
    
    // For small haystacks, use scalar
    if (search_len <= 8) {
        uint32_t hash = hash_rk_fold(haystack, w);
        
        if (hash == target_hash && equal_fold_core(haystack, needle, needle_len, table, vtbl_shift)) {
            return 0;
        }
        
        for (int64_t i = 1; i < search_len; i++) {
            // Standard roll: hash = hash * B + new + antisigma * old
            hash = hash * B + fold_table[haystack[i + w - 1]] + antisigma * fold_table[haystack[i - 1]];
            
            if (hash == target_hash && equal_fold_core(haystack + i, needle, needle_len, table, vtbl_shift)) {
                return i;
            }
        }
        return -1;
    }
    
    // Compute initial hash at position 0
    uint32_t hash = hash_rk_fold(haystack, w);
    
    // Check position 0
    if (hash == target_hash && equal_fold_core(haystack, needle, needle_len, table, vtbl_shift)) {
        return 0;
    }
    
    // Roll through remaining positions
    for (int64_t i = 1; i < search_len; i++) {
        // Rolling hash: hash = hash * B + new + old * antisigma
        hash = hash * B + fold_table[haystack[i + w - 1]] + antisigma * fold_table[haystack[i - 1]];
        
        if (hash == target_hash && equal_fold_core(haystack + i, needle, needle_len, table, vtbl_shift)) {
            return i;
        }
    }
    
    return -1;
}

static inline int64_t index_fold_1_byte_needle(unsigned char *haystack, uint64_t haystack_len,
    uint8_t needle, const uint8x16x2_t table)
{
    const uint64_t blockSize = 16; // NEON can process 128 bits (16 bytes) at a time
    const uint8x16_t shift = vdupq_n_u8(0x60);

    if (needle >= 'a' && needle <= 'z') needle -= 32;
    // the needle is uppercased and shifted
    const uint8x16_t searched = vdupq_n_u8(needle-0x60);

    const unsigned char *data_start = haystack;

    for (const unsigned char *data_bound = haystack + haystack_len - (haystack_len%blockSize); haystack < data_bound; haystack += blockSize)
    {
        uint8x16_t data = vld1q_u8(haystack);

        data = vsubq_u8(data, shift);
        data = vsubq_u8(data, vqtbl2q_u8(table, data));

        // operating on shifted data
        const uint8x16_t res = vceqq_u8(data, searched);
        const uint8x8_t narrowed = vshrn_n_u16(res, 4);

        uint64_t data64 = vget_lane_u64(narrowed, 0);
        if (data64)
        {
            const int pos = (__builtin_ctzll(data64) / 4);
            if (haystack+pos >= data_bound) return -1;
            return (haystack-data_start) + pos;
        }
    }
    haystack_len %= blockSize;

    if (haystack_len == 0) {
        return -1;
    }

    uint8x16_t data = load_data16(haystack, haystack_len);

    data = vsubq_u8(data, shift);
    data = vsubq_u8(data, vqtbl2q_u8(table, data));

    // operating on shifted data
    const uint8x16_t res = vceqq_u8(data, searched);
    const uint8x8_t narrowed = vshrn_n_u16(res, 4);

    uint64_t data64 = vget_lane_u64(narrowed, 0);
    if (data64)
    {
        const int pos = (__builtin_ctzll(data64) / 4);
        if (pos >= haystack_len) return -1;
        return (haystack-data_start) + pos;
    }

    return -1;
}

static inline uint16x8_t index_fold_prepare_comparer(const uint16_t* needle, const uint8x16_t shift, const uint8x16x2_t table)
{
    uint8x16_t needle8vec = vreinterpretq_u8_u16(vld1q_dup_u16(needle));
    needle8vec = vsubq_u8(needle8vec, shift);
    needle8vec = vsubq_u8(needle8vec, vqtbl2q_u8(table, needle8vec));
    return vreinterpretq_u16_u8(needle8vec);
}

static inline int64_t index_fold_2_byte_needle(unsigned char *haystack, uint64_t haystack_len,
    const uint16_t* needle, const uint8x16x2_t table)
{
    const uint64_t blockSize = 16; // NEON can process 128 bits (16 bytes) at a time
    const uint64_t checked_len = haystack_len - 2;
    const uint8x16_t shift = vdupq_n_u8(0x60);

    const uint16x8_t searched = index_fold_prepare_comparer(needle, shift, table);

    uint8x16_t prev_data = vdupq_n_u8(0);
    uint64_t curr_pos = 0;

    for (const unsigned char *data_bound = haystack + checked_len + 1; haystack <= data_bound; haystack += blockSize, curr_pos += blockSize)
    {
        uint8x16_t data = load_data16(haystack, haystack_len - curr_pos);

        data = vsubq_u8(data, shift);
        data = vsubq_u8(data, vqtbl2q_u8(table, data));

        // operating on shifted data
        const uint16x8_t res1 = vceqq_u16(data, searched);
        const uint16x8_t prev = vextq_u8(prev_data, data, 15);
        const uint16x8_t res2 = vceqq_u16(prev, searched);
        prev_data = data;

        const uint16x8_t combined = vorrq_u16(vshlq_n_u16(res1, 8), vshrq_n_u16(res2, 8));
        const uint8x8_t narrowed = vshrn_n_u16(combined, 4);

        // these represent positions: [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
        uint64_t data64 = vget_lane_u64(narrowed, 0);
        // clear the 0th byte on the first iteration, we made up a 0 on that position
        if (data64 && curr_pos == 0) data64 &= ~(0xF);
        if (data64)
        {
            const int pos = (__builtin_ctzll(data64) / 4) - 1;
            if (haystack+pos >= data_bound) return -1;
            return curr_pos + pos;
        }
    }

    return -1;
}

static inline uint64_t index_fold_process_block(uint8x16_t data, uint8x16_t data_end, const uint16x8_t first2, const uint16x8_t last2,
    const uint8x16x2_t table, const uint8x16_t shift, uint8x16_t* prev_data, uint8x16_t* prev_data_end)
{
    data = vsubq_u8(data, shift);
    data = vsubq_u8(data, vqtbl2q_u8(table, data));

    data_end = vsubq_u8(data_end, shift);
    data_end = vsubq_u8(data_end, vqtbl2q_u8(table, data_end));

    // operating on shifted data
    const uint16x8_t res1 = vandq_u16(vceqq_u16(data, first2), vceqq_u16(data_end, last2));
    const uint16x8_t prev = vextq_u8(*prev_data, data, 15);
    const uint16x8_t prev_end = vextq_u8(*prev_data_end, data_end, 15);
    const uint16x8_t res2 = vandq_u16(vceqq_u16(prev, first2), vceqq_u16(prev_end, last2));
    *prev_data = data;
    *prev_data_end = data_end;

    const uint16x8_t combined = vorrq_u16(vshlq_n_u16(res1, 8), vshrq_n_u16(res2, 8));
    const uint8x8_t narrowed = vshrn_n_u16(combined, 4);

    // the return contains 16 nibbles (0x0 or 0xF), each representing position of a match
    // [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    return vget_lane_u64(narrowed, 0);
}

// =============================================================================
// IndexFoldNeedle - Optimized case-insensitive search with precomputed needle
// =============================================================================
// Combines:
// - memchr's rare byte selection (variable offsets)
// - Sneller's compare+XOR normalization (no table lookup)
// - Sneller's tail masking (no scalar remainder loop)

// Tail masks for handling remainder bytes without scalar loops (Sneller-style)
static const uint8_t tail_mask_table[16][16] __attribute__((aligned(16))) = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 0
    {0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 1
    {0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 2
    {0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 3
    {0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 4
    {0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 5
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 6
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 7
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 8
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, // 9
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00,0x00}, // 10
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00,0x00}, // 11
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00,0x00}, // 12
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00}, // 13
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00}, // 14
    {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00}, // 15
};

// Normalize to lowercase: ~4 instructions, no table lookup
static inline uint8x16_t normalize_lower(uint8x16_t v) {
    const uint8x16_t char_A = vdupq_n_u8('A');
    const uint8x16_t char_Z = vdupq_n_u8('Z');
    const uint8x16_t flip = vdupq_n_u8(0x20);
    
    // is_upper = (v >= 'A') & (v <= 'Z')
    uint8x16_t ge_A = vcgeq_u8(v, char_A);
    uint8x16_t le_Z = vcleq_u8(v, char_Z);
    uint8x16_t is_upper = vandq_u8(ge_A, le_Z);
    
    // OR with 0x20 where uppercase to convert to lowercase
    return vorrq_u8(v, vandq_u8(is_upper, flip));
}

// Compare haystack against pre-normalized (lowercase) needle, return true if equal
// IMPORTANT: 'b' (norm_needle) is already lowercase, so we only normalize 'a' (haystack)
static inline bool equal_fold_normalized(const unsigned char *a, const unsigned char *b, int64_t len) {
    while (len >= 16) {
        uint8x16_t va = normalize_lower(vld1q_u8(a));
        uint8x16_t vb = vld1q_u8(b);  // b is already normalized - don't waste ops!
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        a += 16;
        b += 16;
        len -= 16;
    }
    if (len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[len]);
        uint8x16_t va = vandq_u8(normalize_lower(vld1q_u8(a)), mask);
        uint8x16_t vb = vandq_u8(vld1q_u8(b), mask);  // b is already normalized
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// =============================================================================
// Verification functions for different search modes
// =============================================================================

// Case-sensitive exact comparison using SIMD
// For Index and Searcher.Index (no folding)
static inline bool equal_exact(const unsigned char *a, const unsigned char *b, int64_t len) {
    while (len >= 16) {
        uint8x16_t va = vld1q_u8(a);
        uint8x16_t vb = vld1q_u8(b);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        a += 16;
        b += 16;
        len -= 16;
    }
    if (len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[len]);
        uint8x16_t va = vandq_u8(vld1q_u8(a), mask);
        uint8x16_t vb = vandq_u8(vld1q_u8(b), mask);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// Compare haystack against un-normalized needle using XOR + letter detection
// For IndexFold where needle is not pre-normalized
static inline bool equal_fold_both(const unsigned char *a, const unsigned char *b, int64_t len) {
    const uint8x16_t v_159 = vdupq_n_u8(159);  // -97 as unsigned
    const uint8x16_t v_26 = vdupq_n_u8(26);
    const uint8x16_t v_32 = vdupq_n_u8(0x20);
    
    while (len >= 16) {
        uint8x16_t va = vld1q_u8(a);
        uint8x16_t vb = vld1q_u8(b);
        
        // XOR to find differences
        uint8x16_t diff = veorq_u8(va, vb);
        // Check if diff == 0x20 (case difference)
        uint8x16_t is_case_diff = vceqq_u8(diff, v_32);
        // Check if byte is a letter: (h|0x20) + 159 < 26
        uint8x16_t h_lower = vorrq_u8(va, v_32);
        uint8x16_t h_minus_a = vaddq_u8(h_lower, v_159);
        uint8x16_t is_letter = vcltq_u8(h_minus_a, v_26);
        // Mask = 0x20 if (diff==0x20 && is_letter), else 0
        uint8x16_t case_mask = vandq_u8(vandq_u8(is_case_diff, is_letter), v_32);
        // Apply mask to diff: zeros out case differences for letters
        uint8x16_t final_diff = veorq_u8(diff, case_mask);
        
        if (vmaxvq_u8(final_diff)) return false;
        a += 16;
        b += 16;
        len -= 16;
    }
    if (len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[len]);
        uint8x16_t va = vld1q_u8(a);
        uint8x16_t vb = vld1q_u8(b);
        
        uint8x16_t diff = veorq_u8(va, vb);
        uint8x16_t is_case_diff = vceqq_u8(diff, v_32);
        uint8x16_t h_lower = vorrq_u8(va, v_32);
        uint8x16_t h_minus_a = vaddq_u8(h_lower, v_159);
        uint8x16_t is_letter = vcltq_u8(h_minus_a, v_26);
        uint8x16_t case_mask = vandq_u8(vandq_u8(is_case_diff, is_letter), v_32);
        uint8x16_t final_diff = vandq_u8(veorq_u8(diff, case_mask), mask);
        
        if (vmaxvq_u8(final_diff)) return false;
    }
    return true;
}

// =============================================================================
// Adaptive Index/IndexFold - Parameterized for max performance
// =============================================================================
// Key features:
// 1. Rare byte filtering with optional case-folding (OR 0x20)
// 2. Adaptive switch to 2-byte mode after too many false positives
// 3. Tiered loop structure (128-byte, 32-byte, 16-byte, scalar)
// 4. Syndrome extraction with magic constant 0x4010040140100401
// 5. Parameterized verification function
//
// Four entry points via macro instantiation:
// - FILTER_FOLD=0, VERIFY=equal_exact:          Index (case-sensitive, single call)
// - FILTER_FOLD=0, VERIFY=equal_exact:          Searcher.Index (case-sensitive, amortized)
// - FILTER_FOLD=1, VERIFY=equal_fold_both:      IndexFold (case-insensitive, single call)
// - FILTER_FOLD=1, VERIFY=equal_fold_normalized: Searcher.IndexFold (case-insensitive, amortized)
//
// FILTER_FOLD: 0 = exact matching, 1 = case-folding with OR 0x20
// VERIFY_FN: verification function (equal_exact, equal_fold_both, equal_fold_normalized)

#define INDEX_IMPL(func_name, FILTER_FOLD, VERIFY_FN) \
int64_t func_name( \
    unsigned char *haystack, int64_t haystack_len, \
    uint8_t rare1, int64_t off1, \
    uint8_t rare2, int64_t off2, \
    unsigned char *needle, int64_t needle_len) \
{                                                                              \
    if (haystack_len < needle_len) return -1;                                  \
    if (needle_len <= 0) return 0;                                             \
                                                                               \
    const int64_t search_len = haystack_len - needle_len + 1;                  \
                                                                               \
    /* Setup rare1 mask and target */                                          \
    /* FILTER_FOLD=1: OR 0x20 for letters to case-fold */                      \
    /* FILTER_FOLD=0: always 0x00 (exact match) */                             \
    const bool rare1_is_letter = FILTER_FOLD && (rare1 - 'a') < 26;            \
    const uint8_t rare1_mask = rare1_is_letter ? 0x20 : 0x00;                  \
    const uint8_t rare1_target = rare1;                                        \
                                                                               \
    const uint8x16_t v_mask1 = vdupq_n_u8(rare1_mask);                         \
    const uint8x16_t v_target1 = vdupq_n_u8(rare1_target);                     \
                                                                               \
    /* Magic constant for syndrome extraction (2 bits per byte position) */    \
    const uint8x16_t v_magic = vreinterpretq_u8_u64(vdupq_n_u64(0x4010040140100401ULL)); \
                                                                               \
    /* Constants for vectorized verification (only used if FILTER_FOLD) */     \
    const uint8x16_t v_159 = vdupq_n_u8(159);                                  \
    const uint8x16_t v_26 = vdupq_n_u8(26);                                    \
    const uint8x16_t v_32 = vdupq_n_u8(0x20);                                  \
    (void)v_159; (void)v_26; (void)v_32; /* suppress unused warnings */        \
                                                                               \
    /* Search position tracking */                                             \
    unsigned char *search_ptr = haystack + off1;                               \
    unsigned char *search_start = search_ptr;                                  \
    int64_t remaining = search_len;                                            \
                                                                               \
    /* Failure counter for adaptive mode switch */                             \
    int64_t failures = 0;                                                      \
                                                                               \
    /* ===================================================================== */ \
    /* 1-BYTE MODE: Fast path using single rare byte filtering */              \
    /* ===================================================================== */ \
                                                                               \
    /* FILTER_FOLD=0: skip letter path entirely (always use nonletter/exact)*/ \
    /* FILTER_FOLD=1: dispatch based on letter vs non-letter */                \
    if (!FILTER_FOLD || !rare1_is_letter) goto nonletter_dispatch;             \
                                                                               \
    /* Letter path: 768B threshold for 128-byte vs 32-byte loop */             \
    if (remaining >= 768) goto loop128_letter;                                 \
    if (remaining >= 32) goto loop32_letter;                                   \
    goto loop16_letter;                                                        \
                                                                               \
loop128_letter:                                                                \
    while (remaining >= 128) {                                                 \
        /* Load 128 bytes (8 x 16-byte vectors) */                             \
        uint8x16_t d0 = vld1q_u8(search_ptr);                                  \
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);                             \
        uint8x16_t d2 = vld1q_u8(search_ptr + 32);                             \
        uint8x16_t d3 = vld1q_u8(search_ptr + 48);                             \
        uint8x16_t d4 = vld1q_u8(search_ptr + 64);                             \
        uint8x16_t d5 = vld1q_u8(search_ptr + 80);                             \
        uint8x16_t d6 = vld1q_u8(search_ptr + 96);                             \
        uint8x16_t d7 = vld1q_u8(search_ptr + 112);                            \
        search_ptr += 128;                                                     \
        remaining -= 128;                                                      \
                                                                               \
        /* OR with 0x20 to force lowercase, then compare to target */          \
        uint8x16_t m0 = vceqq_u8(vorrq_u8(d0, v_mask1), v_target1);            \
        uint8x16_t m1 = vceqq_u8(vorrq_u8(d1, v_mask1), v_target1);            \
        uint8x16_t m2 = vceqq_u8(vorrq_u8(d2, v_mask1), v_target1);            \
        uint8x16_t m3 = vceqq_u8(vorrq_u8(d3, v_mask1), v_target1);            \
        uint8x16_t m4 = vceqq_u8(vorrq_u8(d4, v_mask1), v_target1);            \
        uint8x16_t m5 = vceqq_u8(vorrq_u8(d5, v_mask1), v_target1);            \
        uint8x16_t m6 = vceqq_u8(vorrq_u8(d6, v_mask1), v_target1);            \
        uint8x16_t m7 = vceqq_u8(vorrq_u8(d7, v_mask1), v_target1);            \
                                                                               \
        /* OR-reduce all 8 vectors for quick "any match?" check */             \
        uint8x16_t any01 = vorrq_u8(m0, m1);                                   \
        uint8x16_t any23 = vorrq_u8(m2, m3);                                   \
        uint8x16_t any45 = vorrq_u8(m4, m5);                                   \
        uint8x16_t any67 = vorrq_u8(m6, m7);                                   \
        uint8x16_t any0123 = vorrq_u8(any01, any23);                           \
        uint8x16_t any4567 = vorrq_u8(any45, any67);                           \
        uint8x16_t any_all = vorrq_u8(any0123, any4567);                       \
                                                                               \
        /* Fast reduce: add pairwise to scalar */                              \
        uint64x2_t any64 = vpaddq_u64(vreinterpretq_u64_u8(any_all), vreinterpretq_u64_u8(any_all)); \
        if (vgetq_lane_u64(any64, 0) == 0) continue;  /* No matches, continue */ \
                                                                               \
        /* Process matches in first 64 bytes, then second 64 bytes */          \
        uint8x16_t *chunks[8] = {&m0, &m1, &m2, &m3, &m4, &m5, &m6, &m7};      \
        for (int block = 0; block < 2; block++) {                              \
            int base_chunk = block * 4;                                        \
            uint8x16_t block_any = vorrq_u8(                                   \
                vorrq_u8(*chunks[base_chunk], *chunks[base_chunk+1]),          \
                vorrq_u8(*chunks[base_chunk+2], *chunks[base_chunk+3]));       \
            uint64x2_t block64 = vpaddq_u64(vreinterpretq_u64_u8(block_any), vreinterpretq_u64_u8(block_any)); \
            if (vgetq_lane_u64(block64, 0) == 0) continue;                     \
                                                                               \
            for (int c = 0; c < 4; c++) {                                      \
                /* Extract syndrome using magic constant + horizontal add */   \
                uint8x16_t masked = vandq_u8(*chunks[base_chunk + c], v_magic); \
                uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked)); \
                uint8x8_t sum2 = vpadd_u8(sum1, sum1);                         \
                uint32_t syndrome = vget_lane_u32(vreinterpret_u32_u8(sum2), 0); \
                                                                               \
                while (syndrome) {                                             \
                    /* RBIT + CLZ equivalent: find first set bit from LSB */   \
                    int bit_pos = __builtin_ctz(syndrome);                     \
                    int byte_pos = bit_pos >> 1;  /* 2 bits per byte */        \
                                                                               \
                    /* Calculate haystack position */                          \
                    int64_t chunk_offset = (block * 64) + (c * 16) + byte_pos; \
                    int64_t pos_in_search = (search_ptr - 128 - search_start) + chunk_offset; \
                                                                               \
                    if (pos_in_search <= search_len - 1) {                     \
                        unsigned char *candidate = haystack + pos_in_search;   \
                                                                               \
                        /* Vectorized verification using XOR + letter detection */ \
                        int64_t n_remaining = needle_len;                      \
                        unsigned char *h_ptr = candidate;                      \
                        unsigned char *n_ptr = needle;                         \
                        bool match = true;                                     \
                                                                               \
                        while (n_remaining >= 16) {                            \
                            uint8x16_t h = vld1q_u8(h_ptr);                    \
                            uint8x16_t n = vld1q_u8(n_ptr);                    \
                                                                               \
                            /* XOR to find differences */                      \
                            uint8x16_t diff = veorq_u8(h, n);                  \
                            /* Check if diff == 0x20 (case difference) */      \
                            uint8x16_t is_case_diff = vceqq_u8(diff, v_32);    \
                            /* Check if byte is a letter: (h|0x20) + 159 < 26 */ \
                            uint8x16_t h_lower = vorrq_u8(h, v_32);            \
                            uint8x16_t h_minus_a = vaddq_u8(h_lower, v_159);   \
                            uint8x16_t is_letter = vcltq_u8(h_minus_a, v_26);  \
                            /* Mask = 0x20 if (diff==0x20 && is_letter), else 0 */ \
                            uint8x16_t case_mask = vandq_u8(vandq_u8(is_case_diff, is_letter), v_32); \
                            /* Apply mask to diff */                           \
                            uint8x16_t final_diff = veorq_u8(diff, case_mask); \
                            /* Check if any mismatch */                        \
                            if (vmaxvq_u8(final_diff) != 0) {                  \
                                match = false;                                 \
                                break;                                         \
                            }                                                  \
                            h_ptr += 16;                                       \
                            n_ptr += 16;                                       \
                            n_remaining -= 16;                                 \
                        }                                                      \
                                                                               \
                        /* Handle tail with mask */                            \
                        if (match && n_remaining > 0) {                        \
                            uint8x16_t tail_m = vld1q_u8(tail_mask_table[n_remaining]); \
                            uint8x16_t h = vld1q_u8(h_ptr);                    \
                            uint8x16_t n = vld1q_u8(n_ptr);                    \
                            uint8x16_t diff = veorq_u8(h, n);                  \
                            uint8x16_t is_case_diff = vceqq_u8(diff, v_32);    \
                            uint8x16_t h_lower = vorrq_u8(h, v_32);            \
                            uint8x16_t h_minus_a = vaddq_u8(h_lower, v_159);   \
                            uint8x16_t is_letter = vcltq_u8(h_minus_a, v_26);  \
                            uint8x16_t case_mask = vandq_u8(vandq_u8(is_case_diff, is_letter), v_32); \
                            uint8x16_t final_diff = vandq_u8(veorq_u8(diff, case_mask), tail_m); \
                            if (vmaxvq_u8(final_diff) != 0) match = false;     \
                        }                                                      \
                                                                               \
                        if (match) return pos_in_search;                       \
                                                                               \
                        /* Verification failed - update failure counter */     \
                        failures++;                                            \
                        int64_t bytes_scanned = search_ptr - search_start;     \
                        int64_t threshold = 4 + (bytes_scanned >> 8);          \
                        if (failures > threshold) {                            \
                            /* Switch to 2-byte mode, back up to chunk start */ \
                            search_ptr -= 128;                                 \
                            remaining += 128;                                  \
                            goto setup_2byte_mode;                             \
                        }                                                      \
                    }                                                          \
                                                                               \
                    /* Clear this bit and try next */                          \
                    int clear_pos = (byte_pos + 1) << 1;                       \
                    uint32_t clear_mask = (1U << clear_pos) - 1;               \
                    syndrome &= ~clear_mask;                                   \
                }                                                              \
            }                                                                  \
        }                                                                      \
    }                                                                          \
    if (remaining >= 32) goto loop32_letter;                                   \
    goto loop16_letter;                                                        \
                                                                               \
loop32_letter:                                                                 \
    while (remaining >= 32) {                                                  \
        uint8x16_t d0 = vld1q_u8(search_ptr);                                  \
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);                             \
        search_ptr += 32;                                                      \
        remaining -= 32;                                                       \
                                                                               \
        uint8x16_t m0 = vceqq_u8(vorrq_u8(d0, v_mask1), v_target1);            \
        uint8x16_t m1 = vceqq_u8(vorrq_u8(d1, v_mask1), v_target1);            \
                                                                               \
        uint8x16_t any = vorrq_u8(m0, m1);                                     \
        uint64x2_t any64 = vpaddq_u64(vreinterpretq_u64_u8(any), vreinterpretq_u64_u8(any)); \
        if (vgetq_lane_u64(any64, 0) == 0) continue;                           \
                                                                               \
        uint8x16_t *chunks[2] = {&m0, &m1};                                    \
        for (int c = 0; c < 2; c++) {                                          \
            uint8x16_t masked = vandq_u8(*chunks[c], v_magic);                 \
            uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked)); \
            uint8x8_t sum2 = vpadd_u8(sum1, sum1);                             \
            uint32_t syndrome = vget_lane_u32(vreinterpret_u32_u8(sum2), 0);   \
                                                                               \
            while (syndrome) {                                                 \
                int bit_pos = __builtin_ctz(syndrome);                         \
                int byte_pos = bit_pos >> 1;                                   \
                int64_t pos_in_search = (search_ptr - 32 - search_start) + (c * 16) + byte_pos; \
                                                                               \
                if (pos_in_search <= search_len - 1) {                         \
                    unsigned char *candidate = haystack + pos_in_search;       \
                    if (VERIFY_FN(candidate, needle, needle_len)) {            \
                        return pos_in_search;                                  \
                    }                                                          \
                    failures++;                                                \
                    int64_t bytes_scanned = search_ptr - search_start;         \
                    if (failures > 4 + (bytes_scanned >> 8)) {                 \
                        search_ptr -= 32;                                      \
                        remaining += 32;                                       \
                        goto setup_2byte_mode;                                 \
                    }                                                          \
                }                                                              \
                int clear_pos = (byte_pos + 1) << 1;                           \
                syndrome &= ~((1U << clear_pos) - 1);                          \
            }                                                                  \
        }                                                                      \
    }                                                                          \
    goto loop16_letter;                                                        \
                                                                               \
loop16_letter:                                                                 \
    while (remaining >= 16) {                                                  \
        uint8x16_t d = vld1q_u8(search_ptr);                                   \
        search_ptr += 16;                                                      \
        remaining -= 16;                                                       \
                                                                               \
        uint8x16_t m = vceqq_u8(vorrq_u8(d, v_mask1), v_target1);              \
        uint8x16_t masked = vandq_u8(m, v_magic);                              \
        uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked));  \
        uint8x8_t sum2 = vpadd_u8(sum1, sum1);                                 \
        uint32_t syndrome = vget_lane_u32(vreinterpret_u32_u8(sum2), 0);       \
                                                                               \
        while (syndrome) {                                                     \
            int bit_pos = __builtin_ctz(syndrome);                             \
            int byte_pos = bit_pos >> 1;                                       \
            int64_t pos_in_search = (search_ptr - 16 - search_start) + byte_pos; \
                                                                               \
            if (pos_in_search <= search_len - 1) {                             \
                if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                    return pos_in_search;                                      \
                }                                                              \
                failures++;                                                    \
                int64_t bytes_scanned = search_ptr - search_start;             \
                if (failures > 4 + (bytes_scanned >> 8)) {                     \
                    search_ptr -= 16;                                          \
                    remaining += 16;                                           \
                    goto setup_2byte_mode;                                     \
                }                                                              \
            }                                                                  \
            int clear_pos = (byte_pos + 1) << 1;                               \
            syndrome &= ~((1U << clear_pos) - 1);                              \
        }                                                                      \
    }                                                                          \
    goto scalar_letter;                                                        \
                                                                               \
scalar_letter:                                                                 \
    while (remaining > 0) {                                                    \
        uint8_t c = *search_ptr;                                               \
        if ((c | rare1_mask) == rare1_target) {                                \
            int64_t pos_in_search = search_ptr - search_start;                 \
            if (pos_in_search <= search_len - 1) {                             \
                if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                    return pos_in_search;                                      \
                }                                                              \
                failures++;                                                    \
                if (failures > 4 + ((search_ptr - search_start) >> 8)) {       \
                    goto setup_2byte_mode;                                     \
                }                                                              \
            }                                                                  \
        }                                                                      \
        search_ptr++;                                                          \
        remaining--;                                                           \
    }                                                                          \
    return -1;                                                                 \
                                                                               \
/* ========================================================================= */ \
/* NON-LETTER FAST PATH: Skip VORR when rare1 is not a letter */               \
/* ========================================================================= */ \
                                                                               \
nonletter_dispatch:                                                            \
    if (remaining >= 768) goto loop128_nonletter;                              \
    if (remaining >= 32) goto loop32_nonletter;                                \
    goto loop16_nonletter;                                                     \
                                                                               \
loop128_nonletter:                                                             \
    while (remaining >= 128) {                                                 \
        uint8x16_t d0 = vld1q_u8(search_ptr);                                  \
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);                             \
        uint8x16_t d2 = vld1q_u8(search_ptr + 32);                             \
        uint8x16_t d3 = vld1q_u8(search_ptr + 48);                             \
        uint8x16_t d4 = vld1q_u8(search_ptr + 64);                             \
        uint8x16_t d5 = vld1q_u8(search_ptr + 80);                             \
        uint8x16_t d6 = vld1q_u8(search_ptr + 96);                             \
        uint8x16_t d7 = vld1q_u8(search_ptr + 112);                            \
        search_ptr += 128;                                                     \
        remaining -= 128;                                                      \
                                                                               \
        /* Direct compare - no VORR needed for non-letters */                  \
        uint8x16_t m0 = vceqq_u8(d0, v_target1);                               \
        uint8x16_t m1 = vceqq_u8(d1, v_target1);                               \
        uint8x16_t m2 = vceqq_u8(d2, v_target1);                               \
        uint8x16_t m3 = vceqq_u8(d3, v_target1);                               \
        uint8x16_t m4 = vceqq_u8(d4, v_target1);                               \
        uint8x16_t m5 = vceqq_u8(d5, v_target1);                               \
        uint8x16_t m6 = vceqq_u8(d6, v_target1);                               \
        uint8x16_t m7 = vceqq_u8(d7, v_target1);                               \
                                                                               \
        uint8x16_t any = vorrq_u8(vorrq_u8(vorrq_u8(m0, m1), vorrq_u8(m2, m3)), \
                                   vorrq_u8(vorrq_u8(m4, m5), vorrq_u8(m6, m7))); \
        uint64x2_t any64 = vpaddq_u64(vreinterpretq_u64_u8(any), vreinterpretq_u64_u8(any)); \
        if (vgetq_lane_u64(any64, 0) == 0) continue;                           \
                                                                               \
        uint8x16_t *chunks[8] = {&m0, &m1, &m2, &m3, &m4, &m5, &m6, &m7};      \
        for (int c = 0; c < 8; c++) {                                          \
            uint8x16_t masked = vandq_u8(*chunks[c], v_magic);                 \
            uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked)); \
            uint8x8_t sum2 = vpadd_u8(sum1, sum1);                             \
            uint32_t syndrome = vget_lane_u32(vreinterpret_u32_u8(sum2), 0);   \
                                                                               \
            while (syndrome) {                                                 \
                int bit_pos = __builtin_ctz(syndrome);                         \
                int byte_pos = bit_pos >> 1;                                   \
                int64_t pos_in_search = (search_ptr - 128 - search_start) + (c * 16) + byte_pos; \
                                                                               \
                if (pos_in_search <= search_len - 1) {                         \
                    if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                        return pos_in_search;                                  \
                    }                                                          \
                    failures++;                                                \
                    if (failures > 4 + ((search_ptr - search_start) >> 8)) {   \
                        search_ptr -= 128;                                     \
                        remaining += 128;                                      \
                        goto setup_2byte_mode;                                 \
                    }                                                          \
                }                                                              \
                int clear_pos = (byte_pos + 1) << 1;                           \
                syndrome &= ~((1U << clear_pos) - 1);                          \
            }                                                                  \
        }                                                                      \
    }                                                                          \
    if (remaining >= 32) goto loop32_nonletter;                                \
    goto loop16_nonletter;                                                     \
                                                                               \
loop32_nonletter:                                                              \
    while (remaining >= 32) {                                                  \
        uint8x16_t d0 = vld1q_u8(search_ptr);                                  \
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);                             \
        search_ptr += 32;                                                      \
        remaining -= 32;                                                       \
                                                                               \
        uint8x16_t m0 = vceqq_u8(d0, v_target1);                               \
        uint8x16_t m1 = vceqq_u8(d1, v_target1);                               \
                                                                               \
        uint8x16_t any = vorrq_u8(m0, m1);                                     \
        uint64x2_t any64 = vpaddq_u64(vreinterpretq_u64_u8(any), vreinterpretq_u64_u8(any)); \
        if (vgetq_lane_u64(any64, 0) == 0) continue;                           \
                                                                               \
        uint8x16_t *chunks[2] = {&m0, &m1};                                    \
        for (int c = 0; c < 2; c++) {                                          \
            uint8x16_t masked = vandq_u8(*chunks[c], v_magic);                 \
            uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked)); \
            uint8x8_t sum2 = vpadd_u8(sum1, sum1);                             \
            uint32_t syndrome = vget_lane_u32(vreinterpret_u32_u8(sum2), 0);   \
                                                                               \
            while (syndrome) {                                                 \
                int bit_pos = __builtin_ctz(syndrome);                         \
                int byte_pos = bit_pos >> 1;                                   \
                int64_t pos_in_search = (search_ptr - 32 - search_start) + (c * 16) + byte_pos; \
                                                                               \
                if (pos_in_search <= search_len - 1) {                         \
                    if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                        return pos_in_search;                                  \
                    }                                                          \
                    failures++;                                                \
                    if (failures > 4 + ((search_ptr - search_start) >> 8)) {   \
                        search_ptr -= 32;                                      \
                        remaining += 32;                                       \
                        goto setup_2byte_mode;                                 \
                    }                                                          \
                }                                                              \
                int clear_pos = (byte_pos + 1) << 1;                           \
                syndrome &= ~((1U << clear_pos) - 1);                          \
            }                                                                  \
        }                                                                      \
    }                                                                          \
    goto loop16_nonletter;                                                     \
                                                                               \
loop16_nonletter:                                                              \
    while (remaining >= 16) {                                                  \
        uint8x16_t d = vld1q_u8(search_ptr);                                   \
        search_ptr += 16;                                                      \
        remaining -= 16;                                                       \
                                                                               \
        uint8x16_t m = vceqq_u8(d, v_target1);                                 \
        uint8x16_t masked = vandq_u8(m, v_magic);                              \
        uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked));  \
        uint8x8_t sum2 = vpadd_u8(sum1, sum1);                                 \
        uint32_t syndrome = vget_lane_u32(vreinterpret_u32_u8(sum2), 0);       \
                                                                               \
        while (syndrome) {                                                     \
            int bit_pos = __builtin_ctz(syndrome);                             \
            int byte_pos = bit_pos >> 1;                                       \
            int64_t pos_in_search = (search_ptr - 16 - search_start) + byte_pos; \
                                                                               \
            if (pos_in_search <= search_len - 1) {                             \
                if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                    return pos_in_search;                                      \
                }                                                              \
                failures++;                                                    \
                if (failures > 4 + ((search_ptr - search_start) >> 8)) {       \
                    search_ptr -= 16;                                          \
                    remaining += 16;                                           \
                    goto setup_2byte_mode;                                     \
                }                                                              \
            }                                                                  \
            int clear_pos = (byte_pos + 1) << 1;                               \
            syndrome &= ~((1U << clear_pos) - 1);                              \
        }                                                                      \
    }                                                                          \
    /* Scalar fallback for non-letter */                                       \
    while (remaining > 0) {                                                    \
        if (*search_ptr == rare1_target) {                                     \
            int64_t pos_in_search = search_ptr - search_start;                 \
            if (pos_in_search <= search_len - 1) {                             \
                if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                    return pos_in_search;                                      \
                }                                                              \
            }                                                                  \
        }                                                                      \
        search_ptr++;                                                          \
        remaining--;                                                           \
    }                                                                          \
    return -1;                                                                 \
                                                                               \
/* ========================================================================= */ \
/* 2-BYTE MODE: Filter on BOTH rare1 AND rare2 for high false-positive scenarios */ \
/* ========================================================================= */ \
                                                                               \
setup_2byte_mode:;                                                             \
    /* Setup rare2 mask and target - also respects FILTER_FOLD */              \
    const bool rare2_is_letter = FILTER_FOLD && (rare2 - 'a') < 26;            \
    const uint8_t rare2_mask = rare2_is_letter ? 0x20 : 0x00;                  \
    const uint8_t rare2_target = rare2;                                        \
                                                                               \
    const uint8x16_t v_mask2 = vdupq_n_u8(rare2_mask);                         \
    const uint8x16_t v_target2 = vdupq_n_u8(rare2_target);                     \
                                                                               \
    /* 64-byte loop for 2-byte mode (using SHRN for syndrome extraction) */    \
    while (remaining >= 64) {                                                  \
        int64_t search_pos = search_ptr - search_start;                        \
                                                                               \
        /* Load rare1 positions */                                             \
        uint8x16_t r1_0 = vld1q_u8(search_ptr);                                \
        uint8x16_t r1_1 = vld1q_u8(search_ptr + 16);                           \
        uint8x16_t r1_2 = vld1q_u8(search_ptr + 32);                           \
        uint8x16_t r1_3 = vld1q_u8(search_ptr + 48);                           \
                                                                               \
        /* Load rare2 positions (different offset) */                          \
        unsigned char *rare2_ptr = haystack + search_pos + off2;               \
        uint8x16_t r2_0 = vld1q_u8(rare2_ptr);                                 \
        uint8x16_t r2_1 = vld1q_u8(rare2_ptr + 16);                            \
        uint8x16_t r2_2 = vld1q_u8(rare2_ptr + 32);                            \
        uint8x16_t r2_3 = vld1q_u8(rare2_ptr + 48);                            \
                                                                               \
        search_ptr += 64;                                                      \
        remaining -= 64;                                                       \
                                                                               \
        /* Check rare1 matches */                                              \
        uint8x16_t m1_0 = vceqq_u8(vorrq_u8(r1_0, v_mask1), v_target1);        \
        uint8x16_t m1_1 = vceqq_u8(vorrq_u8(r1_1, v_mask1), v_target1);        \
        uint8x16_t m1_2 = vceqq_u8(vorrq_u8(r1_2, v_mask1), v_target1);        \
        uint8x16_t m1_3 = vceqq_u8(vorrq_u8(r1_3, v_mask1), v_target1);        \
                                                                               \
        /* Check rare2 matches */                                              \
        uint8x16_t m2_0 = vceqq_u8(vorrq_u8(r2_0, v_mask2), v_target2);        \
        uint8x16_t m2_1 = vceqq_u8(vorrq_u8(r2_1, v_mask2), v_target2);        \
        uint8x16_t m2_2 = vceqq_u8(vorrq_u8(r2_2, v_mask2), v_target2);        \
        uint8x16_t m2_3 = vceqq_u8(vorrq_u8(r2_3, v_mask2), v_target2);        \
                                                                               \
        /* AND results - position must match BOTH rare bytes */                \
        uint8x16_t both0 = vandq_u8(m1_0, m2_0);                               \
        uint8x16_t both1 = vandq_u8(m1_1, m2_1);                               \
        uint8x16_t both2 = vandq_u8(m1_2, m2_2);                               \
        uint8x16_t both3 = vandq_u8(m1_3, m2_3);                               \
                                                                               \
        /* Quick check using vmaxv */                                          \
        uint8x16_t any = vorrq_u8(vorrq_u8(both0, both1), vorrq_u8(both2, both3)); \
        if (vmaxvq_u8(any) == 0) continue;                                     \
                                                                               \
        /* Extract syndromes using SHRN (4 bits per byte) */                   \
        uint8x16_t *chunks[4] = {&both0, &both1, &both2, &both3};              \
        for (int c = 0; c < 4; c++) {                                          \
            uint64_t syndrome = vget_lane_u64(                                 \
                vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(*chunks[c]), 4)), 0); \
                                                                               \
            while (syndrome) {                                                 \
                int bit_pos = __builtin_ctzll(syndrome);                       \
                int byte_pos = bit_pos >> 2;  /* 4 bits per byte for SHRN */   \
                int64_t pos_in_search = search_pos + (c * 16) + byte_pos;      \
                                                                               \
                if (pos_in_search <= search_len - 1) {                         \
                    if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                        return pos_in_search;                                  \
                    }                                                          \
                }                                                              \
                /* Clear nibble */                                             \
                int clear_pos = ((byte_pos + 1) << 2);                         \
                syndrome &= ~((1ULL << clear_pos) - 1);                        \
            }                                                                  \
        }                                                                      \
    }                                                                          \
                                                                               \
    /* 16-byte 2-byte mode loop */                                             \
    while (remaining >= 16) {                                                  \
        int64_t search_pos = search_ptr - search_start;                        \
                                                                               \
        uint8x16_t r1 = vld1q_u8(search_ptr);                                  \
        uint8x16_t r2 = vld1q_u8(haystack + search_pos + off2);                \
        search_ptr += 16;                                                      \
        remaining -= 16;                                                       \
                                                                               \
        uint8x16_t m1 = vceqq_u8(vorrq_u8(r1, v_mask1), v_target1);            \
        uint8x16_t m2 = vceqq_u8(vorrq_u8(r2, v_mask2), v_target2);            \
        uint8x16_t both = vandq_u8(m1, m2);                                    \
                                                                               \
        uint64_t syndrome = vget_lane_u64(                                     \
            vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(both), 4)), 0); \
                                                                               \
        while (syndrome) {                                                     \
            int bit_pos = __builtin_ctzll(syndrome);                           \
            int byte_pos = bit_pos >> 2;                                       \
            int64_t pos_in_search = (search_pos - 16) + 16 + byte_pos;         \
                                                                               \
            if (pos_in_search <= search_len - 1) {                             \
                if (VERIFY_FN(haystack + pos_in_search, needle, needle_len)) { \
                    return pos_in_search;                                      \
                }                                                              \
            }                                                                  \
            int clear_pos = ((byte_pos + 1) << 2);                             \
            syndrome &= ~((1ULL << clear_pos) - 1);                            \
        }                                                                      \
    }                                                                          \
                                                                               \
    /* Scalar 2-byte mode */                                                   \
    while (remaining > 0) {                                                    \
        int64_t search_pos = search_ptr - search_start;                        \
        uint8_t c1 = *search_ptr;                                              \
        uint8_t c2 = *(haystack + search_pos + off2);                          \
                                                                               \
        if ((c1 | rare1_mask) == rare1_target && (c2 | rare2_mask) == rare2_target) { \
            if (search_pos <= search_len - 1) {                                \
                if (VERIFY_FN(haystack + search_pos, needle, needle_len)) {    \
                    return search_pos;                                         \
                }                                                              \
            }                                                                  \
        }                                                                      \
        search_ptr++;                                                          \
        remaining--;                                                           \
    }                                                                          \
                                                                               \
    return -1;                                                                 \
}

// =============================================================================
// Macro instantiations - generate 4 optimized implementations
// =============================================================================

// Generate the actual implementations (no gocc comments - these are internal)
INDEX_IMPL(index_needle_exact_impl, 0, equal_exact)
INDEX_IMPL(index_needle_fold_both_impl, 1, equal_fold_both)
INDEX_IMPL(search_needle_fold_norm_impl, 1, equal_fold_normalized)

// =============================================================================
// Wrapper functions for gocc (these have the gocc comments gocc needs)
// =============================================================================

// Case-sensitive search (no folding) - for Index
// gocc: IndexNEON(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
__attribute__((noinline))
int64_t index_neon(unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1, uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    return index_needle_exact_impl(haystack, haystack_len, rare1, off1, rare2, off2, needle, needle_len);
}

// Case-insensitive search (fold on-the-fly) - for IndexFold
// gocc: indexFoldNEONC(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
__attribute__((noinline))
int64_t index_fold_neon_c(unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1, uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    return index_needle_fold_both_impl(haystack, haystack_len, rare1, off1, rare2, off2, needle, needle_len);
}

// Case-insensitive search (pre-normalized needle) - for Searcher.IndexFold / SearchNeedle
// gocc: SearchNeedleFold(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
__attribute__((noinline))
int64_t search_needle_fold(unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1, uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    return search_needle_fold_norm_impl(haystack, haystack_len, rare1, off1, rare2, off2, needle, needle_len);
}
