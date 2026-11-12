#include <metal_stdlib>
using namespace metal;

struct VolumeUniforms {
    float4 right, up, towardViewer, extent, voxel, tone, controls;
    uint4 flags;
};

static float intensity(texture3d<float> volume, float3 uv, bool inverted) {
    constexpr sampler linearFilter(coord::normalized, address::clamp_to_edge, filter::linear);
    float sample = volume.sample(linearFilter, uv).r;
    return inverted ? 1.0f - sample : sample;
}

static bool intersectBox(float3 origin, float3 ray, float3 lower, float3 upper,
                         thread float &near, thread float &far) {
    near = 0;
    far = 3;
    for (uint axis = 0; axis < 3; ++axis) {
        if (upper[axis] <= lower[axis]) return false;
        if (abs(ray[axis]) < 0.000001f) {
            if (origin[axis] < lower[axis] || origin[axis] > upper[axis]) return false;
        } else {
            float start = (lower[axis] - origin[axis]) / ray[axis];
            float end = (upper[axis] - origin[axis]) / ray[axis];
            near = max(near, min(start, end));
            far = min(far, max(start, end));
        }
    }
    return far > near;
}

kernel void raycastVolume(texture3d<float> volume [[texture(0)]],
                          texture2d<float, access::write> target [[texture(1)]],
                          constant VolumeUniforms &u [[buffer(0)]],
                          uint2 pixel [[thread_position_in_grid]]) {
    uint2 size = uint2(target.get_width(), target.get_height());
    if (any(pixel >= size)) return;
    float2 uv = (float2(pixel) + 0.5f - float2(size) * 0.5f) / float(min(size.x, size.y));
    uv /= u.controls.x;
    const float3 background = float3(0.055f, 0.070f, 0.089f);
    float3 color = 0;
    float transmission = 1;

    float3 extent = u.extent.xyz;
    float3 lower = -extent * 0.5f;
    float3 upper = extent * 0.5f;
    uint axis = u.flags.y;
    if (axis < 3) {
        float boundary = mix(lower[axis], upper[axis], u.controls.z);
        if (u.flags.z) lower[axis] = boundary;
        else upper[axis] = boundary;
    }

    float3 origin = u.right.xyz * uv.x - u.up.xyz * uv.y + u.towardViewer.xyz;
    float3 ray = -u.towardViewer.xyz;
    float near, far;
    if (intersectBox(origin, ray, lower, upper, near, far)) {
        bool bone = u.flags.x == 0;
        bool inverted = u.flags.w != 0;
        float shift = u.tone.z * u.tone.w * 0.28f;
        float low = u.tone.x + shift;
        float high = u.tone.y + shift;
        float minVoxel = min(u.voxel.x, min(u.voxel.y, u.voxel.z));
        float maxSteps = u.controls.w;
        uint steps = uint(clamp(ceil((far - near) / (minVoxel * 0.85f)), 1.0f, maxSteps));
        float step = (far - near) / float(steps);
        float stepMM = step * u.extent.w;
        float3 start = (origin + ray * (near + step * 0.5f)) / extent + 0.5f;
        float3 delta = ray * step / extent;
        float3 sampleOffset = u.voxel.xyz / extent;
        float3 inverseSpacing = minVoxel / u.voxel.xyz;
        for (uint index = 0; index < steps && transmission > 0.012f; ++index) {
            float3 p = start + delta * float(index);
            float value = intensity(volume, p, inverted);
            float weight = smoothstep(low, high, value);
            if (!bone) weight *= 1.0f - 0.82f * smoothstep(high, high + u.tone.z * 0.27f, value);
            if (weight < 0.002f) continue;
            float alpha = 1.0f - exp(-weight * stepMM * u.controls.y * (bone ? 3.2f : 0.075f));
            float3 surface = float3(0.90f, 0.51f, 0.39f);
            if (bone) {
                float3 dx = float3(sampleOffset.x, 0, 0);
                float3 dy = float3(0, sampleOffset.y, 0);
                float3 dz = float3(0, 0, sampleOffset.z);
                float3 gradient = float3(intensity(volume, p - dx, inverted) - intensity(volume, p + dx, inverted),
                                         intensity(volume, p - dy, inverted) - intensity(volume, p + dy, inverted),
                                         intensity(volume, p - dz, inverted) - intensity(volume, p + dz, inverted));
                gradient *= inverseSpacing;
                float light = 0.40f;
                float lengthSquared = dot(gradient, gradient);
                if (lengthSquared > 1.0e-10f) {
                    float3 normal = gradient * rsqrt(lengthSquared);
                    float3 source = normalize(u.towardViewer.xyz + 0.5f * u.up.xyz - 0.35f * u.right.xyz);
                    light = 0.35f + 0.65f * max(0.0f, dot(normal, source));
                }
                surface = float3(1.0f, 0.90f, 0.76f) * light;
            } else {
                surface *= 0.65f + 0.35f * weight;
            }
            color += transmission * alpha * surface;
            transmission *= 1.0f - alpha;
        }
    }
    target.write(float4(color + transmission * background, 1.0f), pixel);
}
