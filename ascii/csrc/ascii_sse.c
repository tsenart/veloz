#include <stdint.h>
#include <stdbool.h>
#include <x86intrin.h>

// The function returns true (1) if all chars passed in src are
// 7-bit values (0x00..0x7F). Otherwise, it returns false (0).
// gocc: isAsciiSse(src string) bool
bool is_ascii_sse(unsigned char *src, uint64_t src_len)
{
    // ASCII chars have MSB = 0, so we use ptest to detect any set MSBs
    if (src_len >= 16)
    {
        // Mask with MSB set in each byte position
        const __m128i hi_mask_v = _mm_set1_epi8((char)0x80);

        // Process 4 vectors at once for better ILP (64 bytes per iteration)
        for (const unsigned char *data64_end = (src + src_len) - (src_len % 64); src < data64_end; src += 64)
        {
            __m128i v0 = _mm_loadu_si128((const __m128i *)(src));
            __m128i v1 = _mm_loadu_si128((const __m128i *)(src + 16));
            __m128i v2 = _mm_loadu_si128((const __m128i *)(src + 32));
            __m128i v3 = _mm_loadu_si128((const __m128i *)(src + 48));

            // OR all vectors together - if any byte has MSB set, result will too
            __m128i combined = _mm_or_si128(_mm_or_si128(v0, v1),
                                            _mm_or_si128(v2, v3));

            // PTEST: returns 1 if (combined & hi_mask_v) == 0 (all ASCII)
            if (!_mm_testz_si128(combined, hi_mask_v))
            {
                return false;
            }
        }
        src_len %= 64;

        // Process remaining 16-byte chunks
        for (const unsigned char *data16_end = (src + src_len) - (src_len % 16); src < data16_end; src += 16)
        {
            __m128i chunk = _mm_loadu_si128((const __m128i *)(src));
            if (!_mm_testz_si128(chunk, hi_mask_v))
            {
                return false;
            }
        }
        src_len %= 16;
    }

    // Scalar fallback for remaining bytes (0-15 bytes)
    if (src_len == 0)
        return true;

    if (src_len & 8)
    {
        uint64_t lo64, hi64;
        uint8_t *data_end = src + src_len;
        __builtin_memcpy(&lo64, src, sizeof(lo64));
        __builtin_memcpy(&hi64, data_end - 8, sizeof(hi64));

        uint64_t data64 = lo64 | hi64;
        return (data64 & 0x8080808080808080ull) ? false : true;
    }

    if (src_len & 4)
    {
        uint32_t lo32, hi32;
        uint8_t *data_end = src + src_len;
        __builtin_memcpy(&lo32, src, sizeof(lo32));
        __builtin_memcpy(&hi32, data_end - 4, sizeof(hi32));

        uint32_t data32 = lo32 | hi32;
        return (data32 & 0x80808080) ? false : true;
    }

    uint32_t data32 = 0;

    // branchless check for 1-3 bytes
    uint8_t *data_end = src + src_len;
    int idx = src_len >> 1;
    data32 |= src[0];
    data32 |= src[idx];
    data32 |= data_end[-1];

    return (data32 & 0x80808080) ? false : true;
}