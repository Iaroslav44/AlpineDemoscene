// Native implementation of the URMP-trained MIDI-DDSP timbre subnetwork.
// Architecture/weights: MIDI-DDSP Authors, Apache-2.0; see models/audio/.
// Pitch and expression are authored controls. This is not the full MIDI-DDSP
// pitch/expression generation graph. Source bandwidth is explicitly 16 kHz.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xmmintrin.h>
#include "neural_audio.h"

namespace {
constexpr unsigned kFloatCount = 2348926;
constexpr unsigned kModelBytes = 64 + kFloatCount * 4;
const float* gWeights;
float gSin[4096];
float gCosIr[128][65];
float gResample[1024][32];

float root(float x) { return _mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(x))); }
float absolute(float x) { return x < 0 ? -x : x; }
float minf(float a, float b) { return a < b ? a : b; }
float maxf(float a, float b) { return a > b ? a : b; }
void copy(float* dst, const float* src, unsigned n) {
    for (unsigned i = 0; i < n; ++i) ((volatile float*)dst)[i] = src[i];
}
void zero(float* dst, unsigned n) {
    for (unsigned i = 0; i < n; ++i) ((volatile float*)dst)[i] = 0;
}
float exp2f_local(float x) {
    if (x < -100) return 0;
    if (x > 100) x = 100;
    int n = (int)x;
    if (x < n) --n;
    const float r = (x - n) * 0.6931471805599453f;
    const float p = 1 + r * (1 + r * (0.5f + r * (0.1666666667f + r *
        (0.04166666667f + r * (0.008333333333f + r * (0.001388888889f + r * 0.0001984126984f))))));
    union { unsigned u; float f; } scale;
    scale.u = (unsigned)(n + 127) << 23;
    return p * scale.f;
}
float logf_local(float x) {
    union { unsigned u; float f; } v;
    v.f = x;
    const int e = (int)((v.u >> 23) & 255) - 127;
    v.u = (v.u & 0x7fffff) | 0x3f800000;
    const float z = (v.f - 1) / (v.f + 1), z2 = z * z;
    const float s = z * (1 + z2 * (1.0f / 3 + z2 * (1.0f / 5 + z2 *
        (1.0f / 7 + z2 * (1.0f / 9 + z2 * (1.0f / 11 + z2 / 13))))));
    return 2 * s + e * 0.6931471805599453f;
}
float expSigmoid(float x) {
    const float sigmoid = 1 / (1 + exp2f_local(-x * 1.4426950408889634f));
    return 2 * exp2f_local(logf_local(sigmoid) * 3.321928094887362f) + 1.0e-7f;
}
float sine(float phase) {
    phase -= (int)phase;
    if (phase < 0) phase += 1;
    const float index = phase * 4096;
    const unsigned i = (unsigned)index;
    const float f = index - i;
    return gSin[i & 4095] * (1 - f) + gSin[(i + 1) & 4095] * f;
}
float sinPolynomial(float x) {
    constexpr float pi = 3.14159265358979323846f;
    if (x > pi) x -= 2 * pi;
    if (x > pi * 0.5f) x = pi - x;
    if (x < -pi * 0.5f) x = -pi - x;
    const float q = x * x;
    return x * (1 + q * (-1.0f / 6 + q * (1.0f / 120 + q *
        (-1.0f / 5040 + q * (1.0f / 362880 - q / 39916800)))));
}
bool continued(int (*pump)()) { return !pump || pump() != 0; }

// Input-major tensor layout retained from the checkpoint, four output channels
// per SSE2 vector. SSE2 is mandatory on Windows x64; no AVX requirement.
void denseRow(const float* in, float* out, const float* weights,
              const float* bias, unsigned ni, unsigned no) {
    copy(out, bias, no);
    const unsigned aligned = no & ~3u;
    for (unsigned i = 0; i < ni; ++i) {
        const __m128 a = _mm_set1_ps(in[i]);
        const float* w = weights + i * no;
        unsigned j = 0;
        for (; j < aligned; j += 4) {
            const __m128 y = _mm_add_ps(_mm_loadu_ps(out + j), _mm_mul_ps(a, _mm_loadu_ps(w + j)));
            _mm_storeu_ps(out + j, y);
        }
        for (; j < no; ++j) out[j] += in[i] * w[j];
    }
}

void normalize(float* values, unsigned count, unsigned channels,
               const float* scale, const float* shift, float epsilon,
               bool leaky, const float* residual) {
    double sum = 0;
    for (unsigned i = 0; i < count; ++i) sum += values[i];
    const float mean = (float)(sum / count);
    double variance = 0;
    for (unsigned i = 0; i < count; ++i) {
        const double v = (double)values[i] - mean;
        variance += v * v;
    }
    const float inv = 1 / root((float)(variance / count) + epsilon);
    for (unsigned i = 0; i < count; ++i) {
        float v = (values[i] - mean) * inv * scale[i % channels] + shift[i % channels];
        if (leaky && v < 0) v *= 0.2f;
        values[i] = residual ? v + residual[i] : v;
    }
}

bool conv(const float* in, float* out, const float* weights, const float* bias,
          unsigned frames, unsigned ni, unsigned dilation, bool relu,
          int (*pump)()) {
    for (unsigned t = 0; t < frames; ++t) {
        float* y = out + t * 128;
        copy(y, bias, 128);
        for (int k = 0; k < 3; ++k) {
            const int q = (int)t + (k - 1) * (int)dilation;
            if (q < 0 || q >= (int)frames) continue;
            const float* x = in + q * ni;
            const float* w = weights + k * ni * 128;
            for (unsigned i = 0; i < ni; ++i) {
                const __m128 a = _mm_set1_ps(relu ? maxf(0, x[i]) : x[i]);
                for (unsigned j = 0; j < 128; j += 4) {
                    _mm_storeu_ps(y + j, _mm_add_ps(_mm_loadu_ps(y + j),
                        _mm_mul_ps(a, _mm_loadu_ps(w + i * 128 + j))));
                }
            }
        }
        if ((t & 31) == 31 && !continued(pump)) return false;
    }
    return true;
}
}

extern "C" int NeuralAudioInit(const void* model, unsigned bytes) {
    gWeights = nullptr;
    if (!model || bytes != kModelBytes) return 0;
    const unsigned* h = (const unsigned*)model;
    if (h[0] != 0x3144414e || h[1] != 1 || h[2] != kFloatCount ||
        h[3] != 250 || h[4] != 16000 || h[5] != 60 || h[6] != 65 ||
        h[7] != 20 || h[8] != 5 || h[9] != 512 || h[10] != 128 || h[11] != 20)
        return 0;
    for (unsigned i = 12; i < 16; ++i) if (h[i]) return 0;
    const float* w = (const float*)((const unsigned char*)model + 64);
    for (unsigned i = 0; i < kFloatCount; ++i) {
        union { float f; unsigned u; } bits;
        bits.f = w[i];
        if ((bits.u & 0x7f800000) == 0x7f800000) return 0;
    }
    for (unsigned i = 0; i < 4096; ++i)
        gSin[i] = sinPolynomial(i * (6.2831853071795864769f / 4096));
    for (unsigned n = 0; n < 128; ++n) {
        const unsigned shifted = (n + 64) & 127;
        const float window = 0.5f - 0.5f * sine(n / 128.0f + 0.25f);
        for (unsigned k = 0; k < 65; ++k)
            gCosIr[n][k] = sine((float)(k * shifted) / 128 + 0.25f) *
                ((k == 0 || k == 64) ? 1.0f : 2.0f) * (window / 128);
    }
    // Bandlimited 16 kHz -> output-rate interpolation. Linear interpolation
    // leaves audible spectral images above the model's native Nyquist limit.
    for (unsigned p = 0; p < 1024; ++p) {
        float sum = 0;
        for (int k = 0; k < 32; ++k) {
            const float x = k - 15 - p / 1024.0f;
            const float window = 0.42f + 0.5f * sine(x / 32 + 0.25f) +
                0.08f * sine(x / 16 + 0.25f);
            const float sinc = absolute(x) < 1.0e-6f ? 0.94f :
                sine(x * 0.47f) / (3.14159265358979323846f * x);
            const float v = window * sinc;
            gResample[p][k] = v; sum += v;
        }
        for (unsigned k = 0; k < 32; ++k) gResample[p][k] /= sum;
    }
    gWeights = w;
    return 1;
}

extern "C" int NeuralAudioPredict(const float* controls10, float* raw126,
    unsigned frames, unsigned instrumentId, int (*pump)()) {
    if (!gWeights || !controls10 || !raw126 || frames < 2 || frames > 2000 || instrumentId >= 13)
        return 0;
    for (unsigned i = 0; i < frames * 10; ++i)
        if (!(controls10[i] >= 0 && controls10[i] <= 2)) return 0;
    // Two 512-channel buffers and one 384-channel conditioning buffer; <12 MiB.
    float* memory = (float*)VirtualAlloc(nullptr, (SIZE_T)frames * (512 * 2 + 384) * 4,
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!memory) return 0;
    float* a = memory;
    float* b = a + frames * 512;
    float* condition = b + frames * 512;
    const float* w = gWeights;
    const float* x = controls10;
    unsigned ni = 10;
    bool success = true;
    for (unsigned layer = 0; layer < 5; ++layer) {
        const float* weights = w; w += ni * 512;
        const float* bias = w; w += 512;
        const float* scale = w; w += 512;
        const float* shift = w; w += 512;
        for (unsigned t = 0; t < frames; ++t) {
            denseRow(x + t * ni, a + t * 512, weights, bias, ni, 512);
            normalize(a + t * 512, 512, 512, scale, shift, 0.001f, true, nullptr);
            if ((t & 31) == 31 && !continued(pump)) { success = false; break; }
        }
        if (!success) break;
        x = a; float* swap = a; a = b; b = swap;
        ni = 512;
    }
    if (success) {
        const float* weights = w; w += 512 * 256;
        const float* bias = w; w += 256;
        const float* embedding = w; w += 20 * 64;
        const float* pitchWeights = w; w += 64;
        const float* pitchBias = w; w += 64;
        for (unsigned t = 0; t < frames; ++t) {
            float* c = condition + t * 384;
            denseRow(x + t * 512, c, weights, bias, 512, 256);
            copy(c + 256, embedding + instrumentId * 64, 64);
            for (unsigned j = 0; j < 64; ++j)
                c[320 + j] = controls10[t * 10 + 6] * pitchWeights[j] + pitchBias[j];
        }
        const float* cw = w; w += 3 * 384 * 128;
        const float* cb = w; w += 128;
        success = conv(condition, a, cw, cb, frames, 384, 1, false, pump);
        for (unsigned layer = 0; layer < 20 && success; ++layer) {
            cw = w; w += 3 * 128 * 128;
            cb = w; w += 128;
            const float* scale = w; w += 128;
            const float* shift = w; w += 128;
            success = conv(a, b, cw, cb, frames, 128, 1u << (layer % 5), true, pump);
            if (success) {
                // DDSP Normalize('layer') normalizes the complete time/channel
                // field, unlike Keras LayerNormalization in the FC stack.
                normalize(b, frames * 128, 128, scale, shift, 0.00001f, false, a);
                float* swap = a; a = b; b = swap;
            }
        }
        if (success) {
            const float* scale = w; w += 128;
            const float* shift = w; w += 128;
            normalize(a, frames * 128, 128, scale, shift, 0.00001f, false, nullptr);
            const float* weightsOut = w; w += 128 * 126;
            const float* biasOut = w; w += 126;
            for (unsigned t = 0; t < frames; ++t)
                denseRow(a + t * 128, raw126 + t * 126, weightsOut, biasOut, 128, 126);
            if (w != gWeights + kFloatCount) success = false;
        }
    }
    VirtualFree(memory, 0, MEM_RELEASE);
    return success ? 1 : 0;
}

extern "C" int NeuralAudioMakeSample(float* output, unsigned kind, unsigned midi,
    unsigned outputFrames, unsigned outputRate, unsigned seed, int (*pump)()) {
    if (!output || kind > 2 || midi < 24 || midi > 96 || outputRate < 16000 ||
        outputRate > 96000 || outputFrames < outputRate / 4 || outputFrames > outputRate * 8)
        return 0;
    const unsigned frames = (unsigned)(((unsigned long long)outputFrames * 250 + outputRate - 1) / outputRate);
    if (frames > 2000) return 0;
    const unsigned samples = frames * 64;
    float* mem = (float*)VirtualAlloc(nullptr, ((SIZE_T)frames * (10 + 126 + 60 + 128) + samples + 256) * 4,
        MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!mem) return 0;
    float* controls = mem;
    float* raw = controls + frames * 10;
    float* harmonics = raw + frames * 126;
    float* impulse = harmonics + frames * 60;
    float* audio = impulse + frames * 128;
    const float volume = kind == 2 ? 0.83f : 0.79f;
    const float brightness = kind == 0 ? 0.27f : (kind == 1 ? 0.20f : 0.31f);
    for (unsigned t = 0; t < frames; ++t) {
        float* c = controls + t * 10;
        c[0] = volume; c[1] = 0.12f; c[2] = kind == 1 ? 0.04f : 0.15f;
        c[3] = brightness; c[4] = kind == 2 ? 0.48f : 0.55f; c[5] = 0.35f;
        c[6] = midi / 127.0f; c[7] = t == 0 ? 1.0f : 0.0f;
        c[8] = t == frames - 1 ? 1.0f : 0.0f; c[9] = (t + 1.0f) / frames;
    }
    const unsigned instrumentId = kind == 0 ? 0 : (kind == 1 ? 3 : 9);
    if (!NeuralAudioPredict(controls, raw, frames, instrumentId, pump)) {
        VirtualFree(mem, 0, MEM_RELEASE); return 0;
    }
    const float baseHz = 440 * exp2f_local(((float)midi - 69) / 12);
    for (unsigned t = 0; t < frames; ++t) {
        const float amp = expSigmoid(raw[t * 126]);
        float sum = 0;
        for (unsigned h = 0; h < 60; ++h) {
            const float v = (h + 1) * baseHz < 7900 ? expSigmoid(raw[t * 126 + 1 + h]) : 0;
            harmonics[t * 60 + h] = v; sum += v;
        }
        for (unsigned h = 0; h < 60; ++h) harmonics[t * 60 + h] *= amp / maxf(sum, 1.0e-12f);
        float noise[65];
        for (unsigned k = 0; k < 65; ++k) noise[k] = expSigmoid(raw[t * 126 + 61 + k] - 5);
        for (unsigned n = 0; n < 128; ++n) {
            float v = 0;
            for (unsigned k = 0; k < 65; ++k) v += noise[k] * gCosIr[n][k];
            impulse[t * 128 + n] = v;
        }
    }
    zero(audio, samples + 128);
    unsigned rng = seed ? seed : 1;
    // Time-varying FIR convolution: each 64-sample white-noise block uses its
    // learned 65-bin response, overlap-added and compensated for the 64-sample
    // linear-phase delay. This executes the learned noise spectrum, not a hiss
    // layered at a fixed handwritten level.
    for (unsigned t = 0; t < frames; ++t) {
        const float* ir = impulse + t * 128;
        for (unsigned i = 0; i < 64; ++i) {
            rng = rng * 1664525u + 1013904223u;
            const float noise = ((rng >> 8) * (1.0f / 8388608.0f)) - 1;
            for (unsigned n = 0; n < 128; ++n) audio[t * 64 + i + n] += noise * ir[n];
        }
    }
    float phase = 0;
    for (unsigned i = 0; i < samples; ++i) {
        const unsigned t = i / 64;
        const unsigned next = t + 1 < frames ? t + 1 : t;
        const float blend = 0.5f - 0.5f * sine((i & 63) / 128.0f + 0.25f);
        const float time = i / 16000.0f;
        const float vibrato = (kind == 1 ? 0.0007f : 0.0020f) * minf(1, time * 3) *
            sine(time * (kind == 2 ? 5.0f : 5.45f) + (seed & 255) / 256.0f);
        phase += baseHz * (1 + vibrato) / 16000;
        if (phase >= 1) phase -= 1;
        float value = audio[i + 64];
        for (unsigned h = 0; h < 60; ++h) {
            const float amp = harmonics[t * 60 + h] * (1 - blend) + harmonics[next * 60 + h] * blend;
            value += amp * sine(phase * (h + 1));
        }
        // Click suppression and an explicit release guard for a reusable bank.
        value *= minf(1, i / 160.0f) * minf(1, (samples - 1 - i) / 1600.0f);
        audio[i] = value;
        if ((i & 4095) == 4095 && !continued(pump)) {
            VirtualFree(mem, 0, MEM_RELEASE); return 0;
        }
    }
    float peak = 1.0e-12f;
    for (unsigned i = 0; i < outputFrames; ++i) {
        const double pos = (double)i * 16000 / outputRate;
        const int j = (int)pos;
        const unsigned p = (unsigned)((pos - j) * 1024);
        float v = 0;
        for (int k = 0; k < 32; ++k) {
            const int q = j + k - 15;
            if (q >= 0 && q < (int)samples) v += audio[q] * gResample[p][k];
        }
        output[i] = v; peak = maxf(peak, absolute(v));
    }
    const float gain = 0.82f / peak;
    for (unsigned i = 0; i < outputFrames; ++i) output[i] *= gain;
    VirtualFree(mem, 0, MEM_RELEASE);
    return 1;
}
