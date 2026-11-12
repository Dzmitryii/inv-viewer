#include <stddef.h>
#include <stdint.h>

// Decodes one raw JPEG 2000 block into consecutive row-major slice planes.
int inv_decode_j2k(const uint8_t *bytes, size_t length, uint32_t width,
                   uint32_t height, uint32_t frames, uint16_t *pixels);
