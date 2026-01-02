#include <stdint.h>
#include <stdbool.h>
#include <x86intrin.h>

// gocc: isAsciiAvx(src string) bool
bool is_ascii_avx(const char *src, uint64_t src_len)
{
  const unsigned char *p = (const unsigned char *)src;
  size_t i = 0;

  // ASCII chars have MSB = 0, so we use movemask to detect any set MSBs
  if (src_len >= 32) {
      // Process 4 vectors at once for better ILP (128 bytes per iteration)
      for (; i + 128 <= src_len; i += 128) {
          __m256i v0 = _mm256_loadu_si256((const __m256i *)(p + i));
          __m256i v1 = _mm256_loadu_si256((const __m256i *)(p + i + 32));
          __m256i v2 = _mm256_loadu_si256((const __m256i *)(p + i + 64));
          __m256i v3 = _mm256_loadu_si256((const __m256i *)(p + i + 96));

          // OR all vectors together - if any byte has MSB set, result will too
          __m256i combined = _mm256_or_si256(_mm256_or_si256(v0, v1),
                                             _mm256_or_si256(v2, v3));

          // Extract MSB of each byte into a 32-bit mask
          if (_mm256_movemask_epi8(combined) != 0) {
              return false;
          }
      }

      // Process remaining 32-byte chunks
      for (; i + 32 <= src_len; i += 32) {
          __m256i chunk = _mm256_loadu_si256((const __m256i *)(p + i));
          if (_mm256_movemask_epi8(chunk) != 0) {
              return false;
          }
      }
  }

  // Scalar fallback for remaining bytes (0-31 bytes)
  const uint64_t hi_mask = 0x8080808080808080ULL;
  for (; i + 8 <= src_len; i += 8) {
      uint64_t chunk;
      __builtin_memcpy(&chunk, p + i, 8);  // Safe unaligned load
      if (chunk & hi_mask) {
          return false;
      }
  }

  uint8_t tail_acc = 0;
  for (; i < src_len; i++)
  {
    tail_acc |= src[i];
  }

  return (tail_acc & 0x80) ? false : true;
}
