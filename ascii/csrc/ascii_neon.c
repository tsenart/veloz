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
__attribute__((always_inline)) static inline uint8x16_t load_data16(const unsigned char *src, int64_t len) {
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

// =============================================================================
// Fast NEON block-based initial hashing (reduces dependency depth)
// =============================================================================
// Key identity: H(s || t) = H(s) * B^{|t|} + H(t)
// Instead of ~3000 dependent steps, use ~48 steps for 3KB by hashing 64-byte blocks.

// Fold 16 bytes ASCII: 'a'..'z' -> 'A'..'Z'
static inline uint8x16_t fold16_ascii_rk(uint8x16_t v,
                                         uint8x16_t va, uint8x16_t vz, uint8x16_t v20)
{
    uint8x16_t x = vsubq_u8(v, va);
    uint8x16_t m = vcleq_u8(x, vz);
    return vsubq_u8(v, vandq_u8(m, v20));
}

// Fold 8 bytes ASCII
static inline uint8x8_t fold8_ascii_rk(uint8x8_t v,
                                       uint8x8_t va, uint8x8_t vz, uint8x8_t v20)
{
    uint8x8_t x = vsub_u8(v, va);
    uint8x8_t m = vcle_u8(x, vz);
    return vsub_u8(v, vand_u8(m, v20));
}

// Compute hash of 16 folded bytes: b0*B^15 + b1*B^14 + ... + b15
static inline uint32_t hash16_from_folded(uint8x16_t b,
                                          uint32x4_t maskFF,
                                          uint32_t B, uint32_t B2, uint32_t B3,
                                          uint32x4_t w16 /* {B^12, B^8, B^4, 1} */)
{
    // Treat as 4x 32-bit words: word0 = bytes 0..3, word1 = bytes 4..7, etc.
    uint32x4_t w = vreinterpretq_u32_u8(b);

    // Extract byte-columns across 4 words:
    // v0 lanes: [b0,b4,b8,b12], v1: [b1,b5,b9,b13], ...
    uint32x4_t v0 = vandq_u32(w, maskFF);
    uint32x4_t v1 = vandq_u32(vshrq_n_u32(w, 8), maskFF);
    uint32x4_t v2 = vandq_u32(vshrq_n_u32(w, 16), maskFF);
    uint32x4_t v3 = vshrq_n_u32(w, 24);

    // q lane j = b[4j+0]*B^3 + b[4j+1]*B^2 + b[4j+2]*B + b[4j+3]
    uint32x4_t q = vmlaq_n_u32(v3, v2, B);
    q = vmlaq_n_u32(q, v1, B2);
    q = vmlaq_n_u32(q, v0, B3);

    // hash16 = q0*B^12 + q1*B^8 + q2*B^4 + q3
    uint32x4_t prod = vmulq_u32(q, w16);
    return vaddvq_u32(prod);
}

// Compute hash of 64 bytes with folding
static inline uint32_t hash64_fold_neon(const uint8_t *p,
                                        uint8x16_t va, uint8x16_t vz, uint8x16_t v20,
                                        uint32x4_t maskFF,
                                        uint32_t B, uint32_t B2, uint32_t B3,
                                        uint32x4_t w16, uint32x4_t w64 /* {B^48, B^32, B^16, 1} */)
{
    uint8x16_t b0 = fold16_ascii_rk(vld1q_u8(p +  0), va, vz, v20);
    uint8x16_t b1 = fold16_ascii_rk(vld1q_u8(p + 16), va, vz, v20);
    uint8x16_t b2 = fold16_ascii_rk(vld1q_u8(p + 32), va, vz, v20);
    uint8x16_t b3 = fold16_ascii_rk(vld1q_u8(p + 48), va, vz, v20);

    uint32_t h0 = hash16_from_folded(b0, maskFF, B, B2, B3, w16);
    uint32_t h1 = hash16_from_folded(b1, maskFF, B, B2, B3, w16);
    uint32_t h2 = hash16_from_folded(b2, maskFF, B, B2, B3, w16);
    uint32_t h3 = hash16_from_folded(b3, maskFF, B, B2, B3, w16);

    // hash64 = h0*B^48 + h1*B^32 + h2*B^16 + h3
    uint32x4_t hv = (uint32x4_t){h0, h1, h2, h3};
    return vaddvq_u32(vmulq_u32(hv, w64));
}

// Compute two hashes in one pass (needle and hay[0:w]) for better ILP
static inline void hash2_rk_fold_neon_fast(const uint8_t *a,
                                           const uint8_t *b,
                                           int64_t len,
                                           uint32_t *out_a,
                                           uint32_t *out_b)
{
    const uint32_t B   = PRIME_RK;
    const uint32_t B2  = B * B;
    const uint32_t B3  = B2 * B;
    const uint32_t B4  = B2 * B2;
    const uint32_t B8  = B4 * B4;
    const uint32_t B12 = B8 * B4;
    const uint32_t B16 = B8 * B8;
    const uint32_t B32 = B16 * B16;
    const uint32_t B48 = B32 * B16;
    const uint32_t B64 = B32 * B32;

    const uint32x4_t maskFF = vdupq_n_u32(0xFFu);
    const uint32x4_t w16 = (uint32x4_t){ B12, B8, B4, 1u };
    const uint32x4_t w64 = (uint32x4_t){ B48, B32, B16, 1u };

    const uint8x16_t va16  = vdupq_n_u8('a');
    const uint8x16_t vz16  = vdupq_n_u8('z' - 'a');
    const uint8x16_t v20_16= vdupq_n_u8(0x20u);

    uint32_t ha = 0u, hb = 0u;
    int64_t i = 0;

    // 64-byte blocks: dependency depth ~ len/64
    for (; i + 64 <= len; i += 64) {
        uint32_t ba = hash64_fold_neon(a + i, va16, vz16, v20_16,
                                       maskFF, B, B2, B3, w16, w64);
        uint32_t bb = hash64_fold_neon(b + i, va16, vz16, v20_16,
                                       maskFF, B, B2, B3, w16, w64);
        ha = ha * B64 + ba;
        hb = hb * B64 + bb;
    }

    // 16-byte blocks
    for (; i + 16 <= len; i += 16) {
        uint8x16_t fa = fold16_ascii_rk(vld1q_u8(a + i), va16, vz16, v20_16);
        uint8x16_t fb = fold16_ascii_rk(vld1q_u8(b + i), va16, vz16, v20_16);

        uint32_t ba = hash16_from_folded(fa, maskFF, B, B2, B3, w16);
        uint32_t bb = hash16_from_folded(fb, maskFF, B, B2, B3, w16);

        ha = ha * B16 + ba;
        hb = hb * B16 + bb;
    }

    // tail bytes
    for (; i < len; i++) {
        ha = ha * B + fold_table[a[i]];
        hb = hb * B + fold_table[b[i]];
    }

    *out_a = ha;
    *out_b = hb;
}

// SIMD Rabin-Karp with stride-4 parallelism
// Key insight: Process 4 hash positions per iteration using NEON uint32x4_t.
// The only loop-carried dependency is H = H*B^4 + S, amortising mul latency by 4.
// All the folding and t[k] computation is independent of H.
//
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
    
    // Precompute constants
    const uint32_t B = PRIME_RK;
    const uint32_t B2 = B * B;
    const uint32_t B3 = B2 * B;
    const uint32_t B4 = B2 * B2;
    const uint32_t Bw = pow_prime(w);
    const uint32_t antisigma = 0u - Bw;  // -B^w mod 2^32
    
    // Fast initial hashes: compute needle and hay[0:w] together using NEON block hashing
    // This reduces dependency depth from ~w to ~w/64 for long needles
    uint32_t target_hash, h0;
    hash2_rk_fold_neon_fast(needle, haystack, w, &target_hash, &h0);
    
    // For small search_len, use scalar
    if (search_len < 4) {
        uint32_t h = h0;
        if (h == target_hash && equal_fold_core(haystack, needle, needle_len, table, vtbl_shift)) {
            return 0;
        }
        for (int64_t i = 1; i < search_len; i++) {
            uint32_t oldc = fold_table[haystack[i - 1]];
            uint32_t newc = fold_table[haystack[i + w - 1]];
            h = h * B + newc + antisigma * oldc;
            if (h == target_hash && equal_fold_core(haystack + i, needle, needle_len, table, vtbl_shift)) {
                return i;
            }
        }
        return -1;
    }
    
    // Build initial 4 hashes (pos 0..3) with 3 scalar rolls from h0
    uint32_t h1 = h0 * B + fold_table[haystack[w + 0]] + antisigma * fold_table[haystack[0]];
    uint32_t h2 = h1 * B + fold_table[haystack[w + 1]] + antisigma * fold_table[haystack[1]];
    uint32_t h3 = h2 * B + fold_table[haystack[w + 2]] + antisigma * fold_table[haystack[2]];
    
    uint32x4_t H = (uint32x4_t){ h0, h1, h2, h3 };
    
    // Hoist vector constants
    const uint32x4_t vB   = vdupq_n_u32(B);
    const uint32x4_t vB2  = vdupq_n_u32(B2);
    const uint32x4_t vB3  = vdupq_n_u32(B3);
    const uint32x4_t vB4  = vdupq_n_u32(B4);
    const uint32x4_t vAnti = vdupq_n_u32(antisigma);
    const uint32x4_t vTgt = vdupq_n_u32(target_hash);
    
    // Folding constants for 16-byte NEON path
    const uint8x16_t va16   = vdupq_n_u8('a');
    const uint8x16_t vz16   = vdupq_n_u8('z' - 'a');
    const uint8x16_t v20_16 = vdupq_n_u8(0x20);
    
    int64_t pos = 0;
    
    for (;;) {
        // 1) Check 4 candidates in parallel
        uint32x4_t eq = vceqq_u32(H, vTgt);
        if (vmaxvq_u32(eq)) {
            // Check lanes in order to preserve earliest match semantics
            if (vgetq_lane_u32(eq, 0) && equal_fold_core(haystack + pos + 0, needle, needle_len, table, vtbl_shift)) return pos + 0;
            if (vgetq_lane_u32(eq, 1) && equal_fold_core(haystack + pos + 1, needle, needle_len, table, vtbl_shift)) return pos + 1;
            if (vgetq_lane_u32(eq, 2) && equal_fold_core(haystack + pos + 2, needle, needle_len, table, vtbl_shift)) return pos + 2;
            if (vgetq_lane_u32(eq, 3) && equal_fold_core(haystack + pos + 3, needle, needle_len, table, vtbl_shift)) return pos + 3;
        }
        
        // No more starts after this block
        if (pos + 4 >= search_len) break;
        
        // Fast vector update needs 8 bytes at hay[pos+w..pos+w+7]
        // If too close to end, finish with scalar tail
        if (pos > search_len - 9) break;
        
        // 2) Load 16 old bytes and 16 new bytes (we only use 8, but 16-byte loads are same cost)
        uint8x16_t old16b = vld1q_u8(haystack + pos);
        uint8x16_t new16b = vld1q_u8(haystack + pos + w);
        
        // 3) Fold ASCII to uppercase with NEON (no table lookup)
        {
            uint8x16_t x = vsubq_u8(old16b, va16);
            uint8x16_t m = vcleq_u8(x, vz16);
            old16b = vsubq_u8(old16b, vandq_u8(m, v20_16));
        }
        {
            uint8x16_t x = vsubq_u8(new16b, va16);
            uint8x16_t m = vcleq_u8(x, vz16);
            new16b = vsubq_u8(new16b, vandq_u8(m, v20_16));
        }
        
        // 4) Widen low 8 bytes -> two vectors of 4x u32
        uint16x8_t old16 = vmovl_u8(vget_low_u8(old16b));
        uint16x8_t new16 = vmovl_u8(vget_low_u8(new16b));
        
        uint32x4_t old0 = vmovl_u16(vget_low_u16(old16));   // old[pos+0..3]
        uint32x4_t old1 = vmovl_u16(vget_high_u16(old16));  // old[pos+4..7]
        uint32x4_t new0 = vmovl_u16(vget_low_u16(new16));   // new[pos+0..3]
        uint32x4_t new1 = vmovl_u16(vget_high_u16(new16));  // new[pos+4..7]
        
        // 5) t[k] = new[k] + antisigma*old[k]
        uint32x4_t t0 = vmlaq_u32(new0, old0, vAnti);  // t[pos+0..3]
        uint32x4_t t1 = vmlaq_u32(new1, old1, vAnti);  // t[pos+4..7]
        
        // 6) Build sliding windows using EXT:
        //    T0 = [t0,t1,t2,t3], T1 = [t1,t2,t3,t4], T2 = [t2,t3,t4,t5], T3 = [t3,t4,t5,t6]
        uint32x4_t T0 = t0;
        uint32x4_t T1 = vextq_u32(t0, t1, 1);
        uint32x4_t T2 = vextq_u32(t0, t1, 2);
        uint32x4_t T3 = vextq_u32(t0, t1, 3);
        
        // 7) S = T0*B^3 + T1*B^2 + T2*B + T3
        uint32x4_t S = T3;
        S = vmlaq_u32(S, T2, vB);
        S = vmlaq_u32(S, T1, vB2);
        S = vmlaq_u32(S, T0, vB3);
        
        // 8) Advance all 4 hashes: H = H*B^4 + S
        H = vmlaq_u32(S, H, vB4);
        
        pos += 4;
    }
    
    // Scalar tail from the last hash we have (lane 3 = hash at pos+3)
    {
        uint32_t h = vgetq_lane_u32(H, 3);
        int64_t i = pos + 3;
        
        for (int64_t j = i + 1; j < search_len; j++) {
            uint32_t oldc = fold_table[haystack[j - 1]];
            uint32_t newc = fold_table[haystack[j + w - 1]];
            h = h * B + newc + antisigma * oldc;
            if (h == target_hash && equal_fold_core(haystack + j, needle, needle_len, table, vtbl_shift)) {
                return j;
            }
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

// =============================================================================
// Verification functions for different search modes
// =============================================================================
// All take haystack_remaining to support safe loading near end of haystack.
// This enables SIMD search for all needle sizes (including ≤16 bytes).

// Compare haystack against pre-normalized (lowercase) needle, return true if equal
// IMPORTANT: 'b' (norm_needle) is already lowercase, so we only normalize 'a' (haystack)
__attribute__((always_inline)) static inline bool equal_fold_normalized(const unsigned char *a, const unsigned char *b, int64_t len, int64_t haystack_remaining) {
    while (len >= 16 && haystack_remaining >= 16) {
        uint8x16_t va = normalize_lower(vld1q_u8(a));
        uint8x16_t vb = vld1q_u8(b);  // b is already normalized - don't waste ops!
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        a += 16;
        b += 16;
        len -= 16;
        haystack_remaining -= 16;
    }
    if (len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[len]);
        uint8x16_t va = (haystack_remaining >= 16) ? vld1q_u8(a) : load_data16(a, haystack_remaining);
        va = vandq_u8(normalize_lower(va), mask);
        uint8x16_t vb = vandq_u8(vld1q_u8(b), mask);  // b is already normalized
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// Case-sensitive exact comparison using SIMD
// For Index and Searcher.Index (no folding)
__attribute__((always_inline)) static inline bool equal_exact(const unsigned char *a, const unsigned char *b, int64_t len, int64_t haystack_remaining) {
    while (len >= 16 && haystack_remaining >= 16) {
        uint8x16_t va = vld1q_u8(a);
        uint8x16_t vb = vld1q_u8(b);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
        a += 16;
        b += 16;
        len -= 16;
        haystack_remaining -= 16;
    }
    if (len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[len]);
        uint8x16_t va = (haystack_remaining >= 16) ? vld1q_u8(a) : load_data16(a, haystack_remaining);
        va = vandq_u8(va, mask);
        uint8x16_t vb = vandq_u8(vld1q_u8(b), mask);
        uint8x16_t diff = veorq_u8(va, vb);
        if (vmaxvq_u8(diff)) return false;
    }
    return true;
}

// Compare haystack against un-normalized needle using XOR + letter detection
// For IndexFold where needle is not pre-normalized
__attribute__((always_inline)) static inline bool equal_fold_both(const unsigned char *a, const unsigned char *b, int64_t len, int64_t haystack_remaining) {
    const uint8x16_t v_159 = vdupq_n_u8(159);  // -97 as unsigned
    const uint8x16_t v_26 = vdupq_n_u8(26);
    const uint8x16_t v_32 = vdupq_n_u8(0x20);
    
    while (len >= 16 && haystack_remaining >= 16) {
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
        haystack_remaining -= 16;
    }
    if (len > 0) {
        uint8x16_t mask = vld1q_u8(tail_mask_table[len]);
        uint8x16_t va = (haystack_remaining >= 16) ? vld1q_u8(a) : load_data16(a, haystack_remaining);
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
// 6. NO POINTER ARRAYS - all chunk processing is explicit/unrolled
// 7. vld1q_u8_x4 for 64-byte batched loads
// 8. 64-byte block early exit like handwritten ASM
//
// Four entry points via macro instantiation:
// - FILTER_FOLD=0, VERIFY=equal_exact:          Index (case-sensitive, single call)
// - FILTER_FOLD=0, VERIFY=equal_exact:          Searcher.Index (case-sensitive, amortized)
// - FILTER_FOLD=1, VERIFY=equal_fold_both:      IndexFold (case-insensitive, single call)
// - FILTER_FOLD=1, VERIFY=equal_fold_normalized: Searcher.IndexFold (case-insensitive, amortized)
//
// FILTER_FOLD: 0 = exact matching, 1 = case-folding with OR 0x20
// VERIFY_FN: verification function (equal_exact, equal_fold_both, equal_fold_normalized)

// Fast "any nonzero?" check using VADDP (much faster than UMAXV!)
// Matches handwritten ASM: VADDP V.D2, V.D2, V.D2 then VMOV to scalar
__attribute__((always_inline)) static inline uint64_t any_nonzero(uint8x16_t v) {
    uint64x2_t v64 = vreinterpretq_u64_u8(v);
    uint64x1_t folded = vadd_u64(vget_low_u64(v64), vget_high_u64(v64));
    return vget_lane_u64(folded, 0);
}

// Helper: Extract 32-bit syndrome from match vector using magic constant
__attribute__((always_inline)) static inline uint32_t extract_syndrome(uint8x16_t match_vec, uint8x16_t magic_vec) {
    uint8x16_t masked = vandq_u8(match_vec, magic_vec);
    uint8x8_t sum1 = vpadd_u8(vget_low_u8(masked), vget_high_u8(masked));
    uint8x8_t sum2 = vpadd_u8(sum1, sum1);
    return vget_lane_u32(vreinterpret_u32_u8(sum2), 0);
}

// Extract 64-bit syndrome from 16-byte match vector using SHRN (2 instructions!)
// SHRN $4 gives us 4 bits per input byte-pair with nibble-level precision:
//   High nibble (0xF0) set = even byte matched (position 0, 2, 4, ...)
//   Low nibble (0x0F) set = odd byte matched (position 1, 3, 5, ...)
// This is FASTER than handwritten ASM's PADD approach!
__attribute__((always_inline)) static inline uint64_t extract_syndrome_shrn(uint8x16_t match) {
    uint8x8_t narrowed = vshrn_n_u16(vreinterpretq_u16_u8(match), 4);
    return vget_lane_u64(vreinterpret_u64_u8(narrowed), 0);
}

// Pack 16 nibble bits into 16 bits using parallel bit deposit
// Input: 64-bit value with 1 bit per nibble (after AND with 0x1111...)
// Output: 16-bit value with those bits packed contiguously
__attribute__((always_inline)) static inline uint16_t pack_nibble_bits(uint64_t n) {
    // Each nibble has a single bit set (0 or 1)
    // Nibble i is at bits [4i, 4i+3], we want bit i of output
    // Use parallel extraction: shift and OR
    // 
    // Layout: n = [n15 n14 n13 n12 n11 n10 n9 n8 | n7 n6 n5 n4 n3 n2 n1 n0]
    //         where each nx is a nibble (4 bits) containing 0 or 1
    //
    // We want: result[i] = n[4i] for i in 0..15
    
    // Gather using multiplication by magic constant
    // Each nibble is 0 or 1, multiply gathers them
    // 
    // Alternative: use cascading shifts
    // n = 0x?0?0?0?0?0?0?0?0 where ? is 0 or 1
    // We want to collect the LSB of each nibble
    
    // Step 1: collect pairs of nibbles into bytes
    // bit 0,1 from nibbles 0,1 → byte 0 bits 0,1
    uint64_t t = n;
    t = (t | (t >> 3)) & 0x0303030303030303ULL;  // Pack pairs of nibble-bits into 2 bits per byte
    // Now each byte has bits in positions 0,1
    
    // Step 2: collect pairs of bytes into halfwords  
    t = (t | (t >> 6)) & 0x000F000F000F000FULL;  // Pack pairs of bytes into 4 bits per halfword
    
    // Step 3: collect pairs of halfwords into words
    t = (t | (t >> 12)) & 0x000000FF000000FFULL; // Pack into 8 bits per word
    
    // Step 4: collect into final 16 bits
    t = (t | (t >> 24)) & 0xFFFF;
    
    return (uint16_t)t;
}

// Extract 64-bit bitmask from 4 match vectors using SHRN
// 64 bytes → 64 bits (1 bit per byte)
__attribute__((always_inline)) static inline uint64_t extract_bitmask64(
    uint8x16_t m0, uint8x16_t m1, uint8x16_t m2, uint8x16_t m3) {
    // SHRN gives 8 bytes per 16-byte chunk, with nibble precision
    uint64_t s0 = extract_syndrome_shrn(m0);
    uint64_t s1 = extract_syndrome_shrn(m1);
    uint64_t s2 = extract_syndrome_shrn(m2);
    uint64_t s3 = extract_syndrome_shrn(m3);
    
    // Extract LSB of each nibble
    const uint64_t nibble_lsb = 0x1111111111111111ULL;
    uint64_t n0 = s0 & nibble_lsb;
    uint64_t n1 = s1 & nibble_lsb;
    uint64_t n2 = s2 & nibble_lsb;
    uint64_t n3 = s3 & nibble_lsb;
    
    // Pack each into 16 bits
    uint16_t b0 = pack_nibble_bits(n0);
    uint16_t b1 = pack_nibble_bits(n1);
    uint16_t b2 = pack_nibble_bits(n2);
    uint16_t b3 = pack_nibble_bits(n3);
    
    return (uint64_t)b0 | ((uint64_t)b1 << 16) | ((uint64_t)b2 << 32) | ((uint64_t)b3 << 48);
}

// Helper: Process all matches in a syndrome for a single chunk
// Process a 128-bit combined syndrome (8 bytes per 16-byte chunk = 128 bytes total)
// This encodes all match positions in a single value, avoiding separate chunk processing
// that causes LLVM to pre-compute haystack+chunk_offset pointers
#define PROCESS_COMBINED_SYNDROME_128(syn_lo, syn_hi, base_offset, load_size, \
    search_len, haystack, data_end, needle, needle_len, \
    failures, search_ptr, remaining, search_start, VERIFY_FN) \
do { \
    /* Process lower 64 bytes (syn_lo has 8 bits per chunk, 4 chunks) */ \
    uint64_t _syn_lo = (syn_lo); \
    while (_syn_lo) { \
        int _bit_pos = __builtin_ctzll(_syn_lo); \
        /* Each byte in syndrome represents 16 bytes, each bit = 2 bytes position */ \
        /* bit_pos / 8 = chunk index, bit_pos % 8 / 2 = byte within chunk's first 4 */ \
        /* Actually: shrn gives 1 byte per 16-byte chunk, but we need different encoding */ \
        int64_t _pos = (base_offset) + _bit_pos; \
        if (_pos <= (search_len) - 1) { \
            unsigned char *_candidate = (haystack) + _pos; \
            int64_t _cand_remaining = (data_end) - _candidate; \
            if (VERIFY_FN(_candidate, (needle), (needle_len), _cand_remaining)) { \
                return _pos; \
            } \
            (failures)++; \
            if ((failures) > 4 + (((base_offset) + (load_size)) >> 8)) { \
                (search_ptr) -= (load_size); \
                (remaining) += (load_size); \
                goto setup_2byte_mode; \
            } \
        } \
        _syn_lo &= _syn_lo - 1; /* Clear lowest bit */ \
    } \
    /* Process upper 64 bytes */ \
    uint64_t _syn_hi = (syn_hi); \
    while (_syn_hi) { \
        int _bit_pos = __builtin_ctzll(_syn_hi); \
        int64_t _pos = (base_offset) + 64 + _bit_pos; \
        if (_pos <= (search_len) - 1) { \
            unsigned char *_candidate = (haystack) + _pos; \
            int64_t _cand_remaining = (data_end) - _candidate; \
            if (VERIFY_FN(_candidate, (needle), (needle_len), _cand_remaining)) { \
                return _pos; \
            } \
            (failures)++; \
            if ((failures) > 4 + (((base_offset) + (load_size)) >> 8)) { \
                (search_ptr) -= (load_size); \
                (remaining) += (load_size); \
                goto setup_2byte_mode; \
            } \
        } \
        _syn_hi &= _syn_hi - 1; \
    } \
} while(0)

// Simple syndrome processor for 32-byte loops (keeps 2 chunks separate)  
#define PROCESS_SYNDROME_SIMPLE(syndrome, chunk_offset, base_offset, load_size, \
    search_len, haystack, data_end, needle, needle_len, \
    failures, search_ptr, remaining, search_start, VERIFY_FN) \
do { \
    uint32_t _syn = (syndrome); \
    while (_syn) { \
        int _bit_pos = __builtin_ctz(_syn); \
        int _byte_pos = _bit_pos >> 1; \
        int64_t _pos = (base_offset) + (chunk_offset) + _byte_pos; \
        if (_pos <= (search_len) - 1) { \
            unsigned char *_candidate = (haystack) + _pos; \
            int64_t _cand_remaining = (data_end) - _candidate; \
            if (VERIFY_FN(_candidate, (needle), (needle_len), _cand_remaining)) { \
                return _pos; \
            } \
            (failures)++; \
            if ((failures) > 4 + (((base_offset) + (load_size)) >> 8)) { \
                (search_ptr) -= (load_size); \
                (remaining) += (load_size); \
                goto setup_2byte_mode; \
            } \
        } \
        int _clear_pos = (_byte_pos + 1) << 1; \
        _syn &= ~((1U << _clear_pos) - 1); \
    } \
} while(0)

#define INDEX_IMPL(func_name, FILTER_FOLD, VERIFY_FN) \
__attribute__((always_inline)) static inline int64_t func_name( \
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
    const bool rare1_is_letter = FILTER_FOLD && (unsigned)(rare1 - 'a') < 26; \
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
    unsigned char *data_end = haystack + haystack_len;                         \
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
    while (remaining >= 128 && search_ptr + 128 <= data_end) {                 \
        /* Compute base offset once - reduces live variables */                \
        int64_t base_offset = search_ptr - search_start;                       \
        uint8x16x4_t batch0 = vld1q_u8_x4(search_ptr);                         \
        uint8x16x4_t batch1 = vld1q_u8_x4(search_ptr + 64);                    \
        search_ptr += 128;                                                     \
        remaining -= 128;                                                      \
                                                                               \
        /* OR with 0x20 and compare - first 64 bytes */                        \
        uint8x16_t m0 = vceqq_u8(vorrq_u8(batch0.val[0], v_mask1), v_target1); \
        uint8x16_t m1 = vceqq_u8(vorrq_u8(batch0.val[1], v_mask1), v_target1); \
        uint8x16_t m2 = vceqq_u8(vorrq_u8(batch0.val[2], v_mask1), v_target1); \
        uint8x16_t m3 = vceqq_u8(vorrq_u8(batch0.val[3], v_mask1), v_target1); \
        /* Second 64 bytes */                                                  \
        uint8x16_t m4 = vceqq_u8(vorrq_u8(batch1.val[0], v_mask1), v_target1); \
        uint8x16_t m5 = vceqq_u8(vorrq_u8(batch1.val[1], v_mask1), v_target1); \
        uint8x16_t m6 = vceqq_u8(vorrq_u8(batch1.val[2], v_mask1), v_target1); \
        uint8x16_t m7 = vceqq_u8(vorrq_u8(batch1.val[3], v_mask1), v_target1); \
                                                                               \
        /* OR-reduce all 8 vectors for quick "any match?" check */             \
        uint8x16_t any0123 = vorrq_u8(vorrq_u8(m0, m1), vorrq_u8(m2, m3));     \
        uint8x16_t any4567 = vorrq_u8(vorrq_u8(m4, m5), vorrq_u8(m6, m7));     \
        uint8x16_t any_all = vorrq_u8(any0123, any4567);                       \
        if (any_nonzero(any_all) == 0) continue;                                 \
                                                                               \
        /* Build 128-bit syndrome: 1 bit per byte position */                  \
        /* This prevents LLVM from pre-computing haystack+offset pointers */   \
        uint64_t syn_lo = extract_bitmask64(m0, m1, m2, m3);                   \
        uint64_t syn_hi = extract_bitmask64(m4, m5, m6, m7);                   \
        PROCESS_COMBINED_SYNDROME_128(syn_lo, syn_hi, base_offset, 128,        \
            search_len, haystack, data_end, needle, needle_len, failures,      \
            search_ptr, remaining, search_start, VERIFY_FN);                   \
    }                                                                          \
    if (remaining >= 32) goto loop32_letter;                                   \
    goto loop16_letter;                                                        \
                                                                               \
loop32_letter:                                                                 \
    while (remaining >= 32 && search_ptr + 32 <= data_end) {                   \
        int64_t base_offset = search_ptr - search_start;                       \
        uint8x16_t d0 = vld1q_u8(search_ptr);                                  \
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);                             \
        search_ptr += 32;                                                      \
        remaining -= 32;                                                       \
                                                                               \
        uint8x16_t m0 = vceqq_u8(vorrq_u8(d0, v_mask1), v_target1);            \
        uint8x16_t m1 = vceqq_u8(vorrq_u8(d1, v_mask1), v_target1);            \
                                                                               \
        uint8x16_t any = vorrq_u8(m0, m1);                                     \
        if (any_nonzero(any) == 0) continue;                                     \
                                                                               \
        /* Process chunks explicitly - NO POINTER ARRAYS */                    \
        uint32_t syn0 = extract_syndrome(m0, v_magic);                         \
        if (syn0) PROCESS_SYNDROME_SIMPLE(syn0, 0, base_offset, 32,            \
            search_len, haystack, data_end, needle, needle_len, failures, search_ptr, remaining, search_start, VERIFY_FN); \
        uint32_t syn1 = extract_syndrome(m1, v_magic);                         \
        if (syn1) PROCESS_SYNDROME_SIMPLE(syn1, 16, base_offset, 32,           \
            search_len, haystack, data_end, needle, needle_len, failures, search_ptr, remaining, search_start, VERIFY_FN); \
    }                                                                          \
    goto loop16_letter;                                                        \
                                                                               \
loop16_letter:                                                                 \
    while (remaining >= 16 && search_ptr + 16 <= data_end) {                   \
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
                unsigned char *candidate = haystack + pos_in_search;           \
                int64_t cand_remaining = data_end - candidate;                 \
                if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
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
                unsigned char *candidate = haystack + pos_in_search;           \
                int64_t cand_remaining = data_end - candidate;                 \
                if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
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
    while (remaining >= 128 && search_ptr + 128 <= data_end) {                 \
        /* Compute base offset once - reduces live variables */                \
        int64_t base_offset = search_ptr - search_start;                       \
        uint8x16x4_t batch0 = vld1q_u8_x4(search_ptr);                         \
        uint8x16x4_t batch1 = vld1q_u8_x4(search_ptr + 64);                    \
        search_ptr += 128;                                                     \
        remaining -= 128;                                                      \
                                                                               \
        /* Direct compare - no VORR needed for non-letters */                  \
        uint8x16_t m0 = vceqq_u8(batch0.val[0], v_target1);                    \
        uint8x16_t m1 = vceqq_u8(batch0.val[1], v_target1);                    \
        uint8x16_t m2 = vceqq_u8(batch0.val[2], v_target1);                    \
        uint8x16_t m3 = vceqq_u8(batch0.val[3], v_target1);                    \
        uint8x16_t m4 = vceqq_u8(batch1.val[0], v_target1);                    \
        uint8x16_t m5 = vceqq_u8(batch1.val[1], v_target1);                    \
        uint8x16_t m6 = vceqq_u8(batch1.val[2], v_target1);                    \
        uint8x16_t m7 = vceqq_u8(batch1.val[3], v_target1);                    \
                                                                               \
        /* OR-reduce all 8 vectors for quick "any match?" check */             \
        uint8x16_t any0123 = vorrq_u8(vorrq_u8(m0, m1), vorrq_u8(m2, m3));     \
        uint8x16_t any4567 = vorrq_u8(vorrq_u8(m4, m5), vorrq_u8(m6, m7));     \
        uint8x16_t any_all = vorrq_u8(any0123, any4567);                       \
        if (any_nonzero(any_all) == 0) continue;                                 \
                                                                               \
        /* Build 128-bit syndrome: 1 bit per byte position */                  \
        uint64_t syn_lo = extract_bitmask64(m0, m1, m2, m3);                   \
        uint64_t syn_hi = extract_bitmask64(m4, m5, m6, m7);                   \
        PROCESS_COMBINED_SYNDROME_128(syn_lo, syn_hi, base_offset, 128,        \
            search_len, haystack, data_end, needle, needle_len, failures,      \
            search_ptr, remaining, search_start, VERIFY_FN);                   \
    }                                                                          \
    if (remaining >= 32) goto loop32_nonletter;                                \
    goto loop16_nonletter;                                                     \
                                                                               \
loop32_nonletter:                                                              \
    while (remaining >= 32 && search_ptr + 32 <= data_end) {                   \
        int64_t base_offset = search_ptr - search_start;                       \
        uint8x16_t d0 = vld1q_u8(search_ptr);                                  \
        uint8x16_t d1 = vld1q_u8(search_ptr + 16);                             \
        search_ptr += 32;                                                      \
        remaining -= 32;                                                       \
                                                                               \
        uint8x16_t m0 = vceqq_u8(d0, v_target1);                               \
        uint8x16_t m1 = vceqq_u8(d1, v_target1);                               \
                                                                               \
        uint8x16_t any = vorrq_u8(m0, m1);                                     \
        if (any_nonzero(any) == 0) continue;                                     \
                                                                               \
        /* Process chunks explicitly - NO POINTER ARRAYS */                    \
        uint32_t syn0 = extract_syndrome(m0, v_magic);                         \
        if (syn0) PROCESS_SYNDROME_SIMPLE(syn0, 0, base_offset, 32,            \
            search_len, haystack, data_end, needle, needle_len, failures, search_ptr, remaining, search_start, VERIFY_FN); \
        uint32_t syn1 = extract_syndrome(m1, v_magic);                         \
        if (syn1) PROCESS_SYNDROME_SIMPLE(syn1, 16, base_offset, 32,           \
            search_len, haystack, data_end, needle, needle_len, failures, search_ptr, remaining, search_start, VERIFY_FN); \
    }                                                                          \
    goto loop16_nonletter;                                                     \
                                                                               \
loop16_nonletter:                                                              \
    while (remaining >= 16 && search_ptr + 16 <= data_end) {                   \
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
                unsigned char *candidate = haystack + pos_in_search;           \
                int64_t cand_remaining = data_end - candidate;                 \
                if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
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
                unsigned char *candidate = haystack + pos_in_search;           \
                int64_t cand_remaining = data_end - candidate;                 \
                if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
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
    const bool rare2_is_letter = FILTER_FOLD && (unsigned)(rare2 - 'a') < 26; \
    const uint8_t rare2_mask = rare2_is_letter ? 0x20 : 0x00;                  \
    const uint8_t rare2_target = rare2;                                        \
                                                                               \
    const uint8x16_t v_mask2 = vdupq_n_u8(rare2_mask);                         \
    const uint8x16_t v_target2 = vdupq_n_u8(rare2_target);                     \
                                                                               \
    /* Compute rare2 offset relative to search_ptr: off2 - off1 */              \
    const int64_t off2_delta = off2 - off1;                                    \
                                                                               \
    /* 64-byte loop for 2-byte mode (using SHRN for syndrome extraction) */    \
    /* Need to ensure both rare1 and rare2 reads stay in bounds */             \
    while (remaining >= 64 && search_ptr + 64 <= data_end &&                   \
           search_ptr + off2_delta + 64 <= data_end) {                         \
        int64_t search_pos = search_ptr - search_start;                        \
                                                                               \
        /* Load rare1 positions */                                             \
        uint8x16_t r1_0 = vld1q_u8(search_ptr);                                \
        uint8x16_t r1_1 = vld1q_u8(search_ptr + 16);                           \
        uint8x16_t r1_2 = vld1q_u8(search_ptr + 32);                           \
        uint8x16_t r1_3 = vld1q_u8(search_ptr + 48);                           \
                                                                               \
        /* Load rare2 positions: search_ptr + (off2 - off1) */                 \
        unsigned char *rare2_ptr = search_ptr + off2_delta;                    \
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
        if (any_nonzero(any) == 0) continue;                                     \
                                                                               \
        /* Extract syndromes using SHRN - unrolled to avoid pointer array */    \
        uint64_t syn0 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(both0), 4)), 0); \
        uint64_t syn1 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(both1), 4)), 0); \
        uint64_t syn2 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(both2), 4)), 0); \
        uint64_t syn3 = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(both3), 4)), 0); \
                                                                               \
        /* Process each chunk's syndrome */                                    \
        uint64_t syndromes[4] = {syn0, syn1, syn2, syn3};                      \
        for (int c = 0; c < 4; c++) {                                          \
            uint64_t syndrome = syndromes[c];                                  \
            while (syndrome) {                                                 \
                int bit_pos = __builtin_ctzll(syndrome);                       \
                int byte_pos = bit_pos >> 2;  /* 4 bits per byte for SHRN */   \
                int64_t pos_in_search = search_pos + (c * 16) + byte_pos;      \
                                                                               \
                if (pos_in_search <= search_len - 1) {                         \
                    unsigned char *candidate = haystack + pos_in_search;       \
                    int64_t cand_remaining = data_end - candidate;             \
                    if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
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
    while (remaining >= 16 && search_ptr + 16 <= data_end &&                   \
           search_ptr + off2_delta + 16 <= data_end) {                         \
        int64_t search_pos = search_ptr - search_start;                        \
                                                                               \
        uint8x16_t r1 = vld1q_u8(search_ptr);                                  \
        uint8x16_t r2 = vld1q_u8(search_ptr + off2_delta);                     \
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
            int64_t pos_in_search = search_pos + byte_pos;                     \
                                                                               \
            if (pos_in_search <= search_len - 1) {                             \
                unsigned char *candidate = haystack + pos_in_search;           \
                int64_t cand_remaining = data_end - candidate;                 \
                if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
                    return pos_in_search;                                      \
                }                                                              \
            }                                                                  \
            int clear_pos = ((byte_pos + 1) << 2);                             \
            syndrome &= ~((1ULL << clear_pos) - 1);                            \
        }                                                                      \
    }                                                                          \
                                                                               \
    /* Scalar 2-byte mode - ensure rare2 read is in bounds */                  \
    while (remaining > 0 && search_ptr + off2_delta < data_end) {              \
        int64_t search_pos = search_ptr - search_start;                        \
        uint8_t c1 = *search_ptr;                                              \
        uint8_t c2 = *(search_ptr + off2_delta);                               \
                                                                               \
        if ((c1 | rare1_mask) == rare1_target && (c2 | rare2_mask) == rare2_target) { \
            if (search_pos <= search_len - 1) {                                \
                unsigned char *candidate = haystack + search_pos;              \
                int64_t cand_remaining = data_end - candidate;                 \
                if (VERIFY_FN(candidate, needle, needle_len, cand_remaining)) { \
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
// Macro instantiations - generate internal implementations
// =============================================================================

// Internal implementations (always_inline static via macro)
INDEX_IMPL(index_needle_exact_impl, 0, equal_exact)
INDEX_IMPL(index_needle_fold_both_impl, 1, equal_fold_both)
INDEX_IMPL(search_needle_fold_norm_impl, 1, equal_fold_normalized)

// =============================================================================
// Wrapper functions for gocc (these have the gocc comments gocc needs)
// =============================================================================
// Use volatile to prevent tail-call optimization which breaks gocc label handling

// Case-sensitive search (no folding) - for Index
// gocc: IndexNEON(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
__attribute__((noinline)) int64_t index_neon(unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1, uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    volatile int64_t result = index_needle_exact_impl(haystack, haystack_len, rare1, off1, rare2, off2, needle, needle_len);
    return result;
}

// Case-insensitive search (fold on-the-fly) - for IndexFold
// gocc: indexFoldNEONC(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
__attribute__((noinline)) int64_t index_fold_neon_c(unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1, uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    volatile int64_t result = index_needle_fold_both_impl(haystack, haystack_len, rare1, off1, rare2, off2, needle, needle_len);
    return result;
}

// Case-insensitive search (pre-normalized needle) - for Searcher.IndexFold / SearchNeedle
// gocc: SearchNeedleFold(haystack string, rare1 byte, off1 int, rare2 byte, off2 int, needle string) int
__attribute__((noinline)) int64_t search_needle_fold(unsigned char *haystack, int64_t haystack_len,
    uint8_t rare1, int64_t off1, uint8_t rare2, int64_t off2,
    unsigned char *needle, int64_t needle_len)
{
    volatile int64_t result = search_needle_fold_norm_impl(haystack, haystack_len, rare1, off1, rare2, off2, needle, needle_len);
    return result;
}
