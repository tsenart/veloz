#include <stdint.h>
#include <stdbool.h>
#include <x86intrin.h>

// The function returns true (1) if all chars passed in src are
// 7-bit values (0x00..0x7F). Otherwise, it returns false (0).
// gocc: isAsciiSse(src string) bool
bool is_ascii_sse(const char *src, uint64_t src_len)
{
  __m128i ma;

  uint64_t i = 0;
  while ((i + 16) <= src_len)
  {
    ma = _mm_loadu_si128((const __m128i *)(src + i));
    if (_mm_movemask_epi8(ma)) {
      return false;
    }

    i += 16;
  }

  uint8_t tail_acc = 0;
  for (; i < src_len; i++)
  {
    tail_acc |= src[i];
  }
  return (tail_acc & 0x80) ? false : true;
}