#include <stdint.h>
#include <stdbool.h>
#include <x86intrin.h>

// The function returns true (1) if all chars passed in src are
// 7-bit values (0x00..0x7F). Otherwise, it returns false (0).
// gocc: isAsciiAvx(src string) bool
bool is_ascii_avx(const char *src, uint64_t src_len)
{
  __m256i ma;

  uint64_t i = 0;
  while ((i + 32) <= src_len)
  {
    ma = _mm256_loadu_si256((const __m256i *)(src + i));
    if (_mm256_movemask_epi8(ma)) {
      return false;
    }

    i += 32;
  }

  uint8_t tail_acc = 0;
  for (; i < src_len; i++)
  {
    tail_acc |= src[i];
  }
  return (tail_acc & 0x80) ? false : true;
}
