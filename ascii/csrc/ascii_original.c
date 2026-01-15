#include <stdint.h>
#include <stdbool.h>
#include <arm_neon.h>

// =============================================================================
// Original IndexFold implementation from origin/main
// Uses first2/last2 bytes approach (not rare-byte selection)
// =============================================================================

#define MIN(a, b) ((a) > (b) ? (b) : (a))
#define MAX(a, b) ((a) < (b) ? (b) : (a))

static uint8_t uppercasingTable_orig[32] = {
    0,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,
    32,32,32,32,32,32,32,32,32,32,32,0, 0, 0, 0, 0,
};

static inline bool equal_fold_core_orig(unsigned char *a, unsigned char *b, int64_t length,
    const uint8x16x2_t table, const uint8x16_t shift)
{
    const uint64_t blockSize = 16;

    if (length < 0) return false;

    for (const unsigned char *data_bound = (a + length) - (length % blockSize); a < data_bound; a += blockSize, b += blockSize)
    {
        uint8x16_t a_data = vld1q_u8(a);
        uint8x16_t b_data = vld1q_u8(b);

        a_data = vsubq_u8(a_data, shift);
        a_data = vsubq_u8(a_data, vqtbl2q_u8(table, a_data));

        b_data = vsubq_u8(b_data, shift);
        b_data = vsubq_u8(b_data, vqtbl2q_u8(table, b_data));

        const uint8x16_t result = vceqq_u8(a_data, b_data);

        if (vget_lane_u64(vshrn_n_u16(result, 4), 0) != ~0ull)
        {
            return false;
        }
    }
    length %= blockSize;

    if (length >= 8)
    {
        uint8x8_t a_data = vld1_u8(a);
        uint8x8_t b_data = vld1_u8(b);

        a_data = vsub_u8(a_data, vget_low_u8(shift));
        a_data = vsub_u8(a_data, vqtbl2_u8(table, a_data));

        b_data = vsub_u8(b_data, vget_low_u8(shift));
        b_data = vsub_u8(b_data, vqtbl2_u8(table, b_data));

        const uint8x8_t result = vceq_u8(a_data, b_data);

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

    switch (length)
    {
    case 3:
        a_data64 <<= 24;
        a_data64 |= *(uint16_t *)(a) << 8;
        a_data64 |= a[2];
        b_data64 <<= 24;
        b_data64 |= *(uint16_t *)(b) << 8;
        b_data64 |= b[2];
        break;
    case 2:
        a_data64 <<= 16;
        a_data64 |= *(uint16_t *)(a);
        b_data64 <<= 16;
        b_data64 |= *(uint16_t *)(b);
        break;
    case 1:
        a_data64 <<= 8;
        a_data64 |= *a;
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

    const uint8x8_t result = vceq_u8(a_data, b_data);

    if (vget_lane_u64(result, 0) != ~0ull)
    {
        return false;
    }

    return true;
}

static inline uint8x16_t load_data16_orig(const unsigned char *src, int64_t len) {
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

static inline uint32_t rabin_karp_hash_string_fold_orig(unsigned char *data, uint64_t data_len, uint32_t *pow_ret)
{
    const uint32_t PrimeRK = 16777619;

    uint32_t hash = 0;
    for (uint64_t i = 0; i < data_len; i++)
    {
        uint8_t c = data[i];
        if (c >= 'a' && c <= 'z') {
            c -= 0x80;
        } else {
            c -= 0x60;
        }
        hash = hash * PrimeRK + c;
    }

    uint32_t sq = PrimeRK;
    uint32_t pow = 1;

    for (uint64_t i = data_len; i > 0; i >>= 1)
    {
        if (i & 1) pow *= sq;
        sq *= sq;
    }

    *pow_ret = pow;
    return hash;
}

static inline int64_t index_fold_rabin_karp_core_orig(unsigned char *haystack, const int64_t haystack_len, unsigned char *needle, const int64_t needle_len,
    const uint8x16x2_t table, const uint8x16_t shift)
{
    const uint32_t PrimeRK = 16777619;

    uint32_t hash_needle, pow;
    hash_needle = rabin_karp_hash_string_fold_orig(needle, needle_len, &pow);

    uint32_t hash = 0;
    for (uint64_t i = 0; i < needle_len; i++)
    {
        uint8_t c = haystack[i];
        if (c >= 'a' && c <= 'z') {
            c -= 0x80;
        } else {
            c -= 0x60;
        }
        hash = hash * PrimeRK + c;
    }

    if (hash == hash_needle && equal_fold_core_orig(haystack, needle, needle_len, table, shift))
    {
        return 0;
    }

    for (uint64_t i = needle_len; i < haystack_len; i++)
    {
        uint8_t c = haystack[i];
        if (c >= 'a' && c <= 'z') {
            c -= 0x80;
        } else {
            c -= 0x60;
        }
        hash = hash * PrimeRK + c;
        c = haystack[i - needle_len];
        if (c >= 'a' && c <= 'z') {
            c -= 0x80;
        } else {
            c -= 0x60;
        }
        hash -= pow * c;

        if (hash == hash_needle && equal_fold_core_orig(haystack + i - needle_len + 1, needle, needle_len, table, shift))
        {
            return i - needle_len + 1;
        }
    }

    return -1;
}

static inline int64_t index_fold_1_byte_needle_orig(unsigned char *haystack, uint64_t haystack_len,
    uint8_t needle, const uint8x16x2_t table)
{
    const uint64_t blockSize = 16;
    const uint8x16_t shift = vdupq_n_u8(0x60);

    if (needle >= 'a' && needle <= 'z') needle -= 32;
    const uint8x16_t searched = vdupq_n_u8(needle-0x60);

    const unsigned char *data_start = haystack;

    for (const unsigned char *data_bound = haystack + haystack_len - (haystack_len%blockSize); haystack < data_bound; haystack += blockSize)
    {
        uint8x16_t data = vld1q_u8(haystack);

        data = vsubq_u8(data, shift);
        data = vsubq_u8(data, vqtbl2q_u8(table, data));

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

    uint8x16_t data = load_data16_orig(haystack, haystack_len);

    data = vsubq_u8(data, shift);
    data = vsubq_u8(data, vqtbl2q_u8(table, data));

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

static inline uint16x8_t index_fold_prepare_comparer_orig(const uint16_t* needle, const uint8x16_t shift, const uint8x16x2_t table)
{
    uint8x16_t needle8vec = vreinterpretq_u8_u16(vld1q_dup_u16(needle));
    needle8vec = vsubq_u8(needle8vec, shift);
    needle8vec = vsubq_u8(needle8vec, vqtbl2q_u8(table, needle8vec));
    return vreinterpretq_u16_u8(needle8vec);
}

static inline int64_t index_fold_2_byte_needle_orig(unsigned char *haystack, uint64_t haystack_len,
    const uint16_t* needle, const uint8x16x2_t table)
{
    const uint64_t blockSize = 16;
    const uint64_t checked_len = haystack_len - 2;
    const uint8x16_t shift = vdupq_n_u8(0x60);

    const uint16x8_t searched = index_fold_prepare_comparer_orig(needle, shift, table);

    uint8x16_t prev_data = vdupq_n_u8(0);
    uint64_t curr_pos = 0;

    for (const unsigned char *data_bound = haystack + checked_len + 1; haystack <= data_bound; haystack += blockSize, curr_pos += blockSize)
    {
        uint8x16_t data = load_data16_orig(haystack, haystack_len - curr_pos);

        data = vsubq_u8(data, shift);
        data = vsubq_u8(data, vqtbl2q_u8(table, data));

        const uint16x8_t res1 = vceqq_u16(data, searched);
        const uint16x8_t prev = vextq_u8(prev_data, data, 15);
        const uint16x8_t res2 = vceqq_u16(prev, searched);
        prev_data = data;

        const uint16x8_t combined = vorrq_u16(vshlq_n_u16(res1, 8), vshrq_n_u16(res2, 8));
        const uint8x8_t narrowed = vshrn_n_u16(combined, 4);

        uint64_t data64 = vget_lane_u64(narrowed, 0);
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

static inline uint64_t index_fold_process_block_orig(uint8x16_t data, uint8x16_t data_end, const uint16x8_t first2, const uint16x8_t last2,
    const uint8x16x2_t table, const uint8x16_t shift, uint8x16_t* prev_data, uint8x16_t* prev_data_end)
{
    data = vsubq_u8(data, shift);
    data = vsubq_u8(data, vqtbl2q_u8(table, data));

    data_end = vsubq_u8(data_end, shift);
    data_end = vsubq_u8(data_end, vqtbl2q_u8(table, data_end));

    const uint16x8_t res1 = vandq_u16(vceqq_u16(data, first2), vceqq_u16(data_end, last2));
    const uint16x8_t prev = vextq_u8(*prev_data, data, 15);
    const uint16x8_t prev_end = vextq_u8(*prev_data_end, data_end, 15);
    const uint16x8_t res2 = vandq_u16(vceqq_u16(prev, first2), vceqq_u16(prev_end, last2));
    *prev_data = data;
    *prev_data_end = data_end;

    const uint16x8_t combined = vorrq_u16(vshlq_n_u16(res1, 8), vshrq_n_u16(res2, 8));
    const uint8x8_t narrowed = vshrn_n_u16(combined, 4);

    return vget_lane_u64(narrowed, 0);
}

// gocc: IndexFoldOriginal(haystack, needle string) int
int64_t index_fold_original(unsigned char *haystack, int64_t haystack_len, unsigned char *needle, const int64_t needle_len)
{
    const uint64_t blockSize = 16;

    const uint8x16x2_t table = vld1q_u8_x2(uppercasingTable_orig);
    const uint8x16_t shift = vdupq_n_u8(0x60);

    if (haystack_len < needle_len) return -1;
    if (needle_len <= 0) return 0;
    if (haystack_len == needle_len) {
        return equal_fold_core_orig(haystack, needle, needle_len, table, shift) ? 0 : -1;
    }

    switch (needle_len)
    {
    case 1:
        return index_fold_1_byte_needle_orig(haystack, haystack_len, *(uint8_t *)needle, table);
    case 2:
        return index_fold_2_byte_needle_orig(haystack, haystack_len, (uint16_t *)needle, table);
    }

    // load the first 2 bytes of the needle
    const uint16x8_t first2 = index_fold_prepare_comparer_orig((uint16_t *)needle, shift, table);
    // load the last 2 bytes of the needle
    const uint16x8_t last2 = index_fold_prepare_comparer_orig((uint16_t *)(needle + needle_len - 2), shift, table);

    const unsigned char *data_start = haystack;

    const int64_t checked_len = haystack_len - needle_len;
    uint8x16_t prev_data = vdupq_n_u8(0);
    uint8x16_t prev_data_end = vdupq_n_u8(0);
    uint64_t failures = 0;

    for (const unsigned char *data_bound = haystack + MIN(checked_len - (checked_len%blockSize), haystack_len-blockSize); haystack < data_bound; haystack += blockSize)
    {
        uint8x16_t data = vld1q_u8(haystack);
        uint8x16_t data_end = vld1q_u8(haystack + needle_len - 2);

        uint64_t data64 = index_fold_process_block_orig(data, data_end, first2, last2, table, shift, &prev_data, &prev_data_end);
        if (data64) {
            while (data64)
            {
                int pos = __builtin_ctzll(data64) / 4;
                data64 &= ~(0xFull << (pos * 4));
                if (haystack == data_start && pos == 0) continue;
                pos--;

                if (equal_fold_core_orig(haystack+pos+2, needle+2, MAX(needle_len-4, 0), table, shift))
                {
                    return haystack-data_start + pos;
                }
                failures++;
            }
            const uint64_t advance = blockSize-1;
            if (failures > 4 + ((haystack-data_start+advance)>>4) && haystack+advance < data_bound) {
                haystack += advance;
                int64_t curr_pos = haystack - data_start;
                int64_t rem_len = haystack_len - curr_pos;
                int64_t rk_pos = index_fold_rabin_karp_core_orig(haystack, rem_len, needle, needle_len, table, shift);
                if (rk_pos != -1) {
                    return curr_pos + rk_pos;
                }
                return -1;
            }
        }
    }

    const unsigned char *data_bound = data_start + checked_len + 1;

    for (; haystack <= data_bound; haystack += blockSize)
    {
        const int64_t data_len = haystack_len - (haystack - data_start);
        uint8x16_t data = load_data16_orig(haystack, data_len);
        uint8x16_t data_end = load_data16_orig(haystack + needle_len - 2, data_len - needle_len + 2);

        uint64_t data64 = index_fold_process_block_orig(data, data_end, first2, last2, table, shift, &prev_data, &prev_data_end);
        while (data64)
        {
            int pos = __builtin_ctzll(data64) / 4;
            data64 &= ~(0xFull << (pos * 4));
            if (haystack == data_start && pos == 0) continue;
            pos--;

            if (haystack+pos < data_bound && equal_fold_core_orig(haystack+pos+2, needle+2, MAX(needle_len-4, 0), table, shift))
            {
                return (haystack-data_start) + pos;
            }
        }
    }

    return -1;
}
