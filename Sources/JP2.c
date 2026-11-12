#include "JP2.h"
#include <openjpeg.h>
#include <string.h>

struct Input {
    const uint8_t *bytes;
    size_t length;
    size_t position;
};

static OPJ_SIZE_T read_bytes(void *destination, OPJ_SIZE_T count, void *context) {
    struct Input *input = context;
    size_t remaining = input->length - input->position;
    if (remaining == 0) return (OPJ_SIZE_T)-1;
    if (count > remaining) count = remaining;
    memcpy(destination, input->bytes + input->position, count);
    input->position += count;
    return count;
}

static OPJ_OFF_T skip_bytes(OPJ_OFF_T count, void *context) {
    struct Input *input = context;
    if (count < 0 || (uint64_t)count > input->length - input->position) return -1;
    input->position += (size_t)count;
    return count;
}

static OPJ_BOOL seek_bytes(OPJ_OFF_T position, void *context) {
    struct Input *input = context;
    if (position < 0 || (uint64_t)position > input->length) return OPJ_FALSE;
    input->position = (size_t)position;
    return OPJ_TRUE;
}

int inv_decode_j2k(const uint8_t *bytes, size_t length, uint32_t width,
                   uint32_t height, uint32_t frames, uint16_t *pixels) {
    struct Input input = { bytes, length, 0 };
    opj_stream_t *stream = opj_stream_default_create(OPJ_TRUE);
    opj_codec_t *codec = opj_create_decompress(OPJ_CODEC_J2K);
    opj_image_t *image = NULL;
    int success = 0;
    if (!stream || !codec) goto cleanup;

    opj_stream_set_user_data(stream, &input, NULL);
    opj_stream_set_user_data_length(stream, length);
    opj_stream_set_read_function(stream, read_bytes);
    opj_stream_set_skip_function(stream, skip_bytes);
    opj_stream_set_seek_function(stream, seek_bytes);

    opj_dparameters_t options;
    opj_set_default_decoder_parameters(&options);
    if (!opj_setup_decoder(codec, &options) ||
        !opj_decoder_set_strict_mode(codec, OPJ_TRUE) ||
        !opj_read_header(stream, codec, &image) ||
        !image || image->numcomps != frames ||
        !opj_decode(codec, stream, image) || !opj_end_decompress(codec, stream))
        goto cleanup;

    size_t plane = (size_t)width * height;
    for (uint32_t frame = 0; frame < frames; frame++) {
        const opj_image_comp_t *component = &image->comps[frame];
        if (component->w != width || component->h != height || component->sgnd ||
            component->prec != 16 || !component->data) goto cleanup;
        for (size_t i = 0; i < plane; i++) {
            int32_t value = component->data[i];
            if (value < 0 || value > UINT16_MAX) goto cleanup;
            pixels[(size_t)frame * plane + i] = (uint16_t)value;
        }
    }
    success = 1;

cleanup:
    if (image) opj_image_destroy(image);
    if (codec) opj_destroy_codec(codec);
    if (stream) opj_stream_destroy(stream);
    return success;
}
