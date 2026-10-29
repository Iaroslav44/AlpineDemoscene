#pragma once
// Real pretrained MIDI-DDSP timbre decoder. Win64 C ABI; no CUDA/TF dependency.
// A pump returns nonzero to continue, zero to cancel. All functions return 1 on
// success, 0 on invalid input, allocation failure, or cancellation.
extern "C" int NeuralAudioInit(const void* model, unsigned bytes);
extern "C" int NeuralAudioPredict(const float* controls10, float* raw126,
    unsigned frames, unsigned instrumentId, int (*pump)());
extern "C" int NeuralAudioMakeSample(float* output, unsigned kind, unsigned midi,
    unsigned outputFrames, unsigned outputRate, unsigned seed, int (*pump)());

