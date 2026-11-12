#include "Fixture.h"
#include <openjpeg.h>

int inv_encode_fixture_j2k(const char *path, uint32_t width, uint32_t height,
                           uint32_t frames, const uint16_t *pixels) {
    opj_image_cmptparm_t components[8] = {0};
    if (frames == 0 || frames > 8) return 0;
    for (uint32_t i = 0; i < frames; ++i) {
        components[i].dx = components[i].dy = 1;
        components[i].w = width;
        components[i].h = height;
        components[i].prec = 16;
    }

    opj_image_t *image = opj_image_create(frames, components, OPJ_CLRSPC_UNSPECIFIED);
    opj_codec_t *codec = opj_create_compress(OPJ_CODEC_J2K);
    opj_stream_t *stream = opj_stream_create_default_file_stream(path, OPJ_FALSE);
    int success = 0;
    if (!image || !codec || !stream) goto cleanup;
    image->x1 = width;
    image->y1 = height;
    size_t plane = (size_t)width * height;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        for (size_t i = 0; i < plane; ++i) {
            image->comps[frame].data[i] = pixels[(size_t)frame * plane + i];
        }
    }

    opj_cparameters_t parameters;
    opj_set_default_encoder_parameters(&parameters);
    parameters.numresolution = 3;
    parameters.tcp_numlayers = 1;
    parameters.tcp_rates[0] = 0;
    parameters.cp_disto_alloc = 1;
    parameters.tcp_mct = 0;
    success = opj_setup_encoder(codec, &parameters, image) &&
        opj_start_compress(codec, image, stream) && opj_encode(codec, stream) && opj_end_compress(codec, stream);

cleanup:
    if (stream) opj_stream_destroy(stream);
    if (codec) opj_destroy_codec(codec);
    if (image) opj_image_destroy(image);
    return success;
}
