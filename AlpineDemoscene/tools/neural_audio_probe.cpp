#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>
#include <filesystem>
#include <cmath>
#include "../src/neural_audio.h"

static int cancelCount;
static int cancelPump() { return ++cancelCount < 3; }
static std::vector<char> readFile(const char* path) {
    std::ifstream f(path, std::ios::binary);
    return std::vector<char>(std::istreambuf_iterator<char>(f), {});
}
static void writeFile(const std::filesystem::path& path, const void* data, size_t bytes) {
    std::ofstream f(path, std::ios::binary);
    f.write((const char*)data, bytes);
    if (!f) std::exit(10);
}
static double now() {
    LARGE_INTEGER n, f; QueryPerformanceCounter(&n); QueryPerformanceFrequency(&f);
    return (double)n.QuadPart / f.QuadPart;
}
static void wav(const std::filesystem::path& path, const std::vector<float>& audio) {
    std::vector<unsigned char> data(44 + audio.size() * 2);
    auto u16 = [&](size_t o, unsigned v) { data[o] = (unsigned char)v; data[o+1] = (unsigned char)(v >> 8); };
    auto u32 = [&](size_t o, unsigned v) { u16(o, v); u16(o+2, v >> 16); };
    auto tag = [&](size_t o, const char* s) { for (int i = 0; i < 4; ++i) data[o+i] = s[i]; };
    tag(0,"RIFF"); u32(4,(unsigned)data.size()-8); tag(8,"WAVE"); tag(12,"fmt ");
    u32(16,16); u16(20,1); u16(22,1); u32(24,44100); u32(28,88200); u16(32,2); u16(34,16);
    tag(36,"data"); u32(40,(unsigned)audio.size()*2);
    for (size_t i=0;i<audio.size();++i) u16(44+i*2, (unsigned short)(short)std::lround(audio[i]*32767));
    writeFile(path, data.data(), data.size());
}
int main(int argc, char** argv) {
    if (argc < 3) return 2;
    const auto model = readFile(argv[1]);
    const std::filesystem::path out(argv[2]);
    std::filesystem::create_directories(out);
    if (NeuralAudioInit(model.data(), (unsigned)model.size()-1)) return 3;
    auto invalid = model; invalid[0] ^= 1;
    if (NeuralAudioInit(invalid.data(), (unsigned)invalid.size())) return 4;
    if (!NeuralAudioInit(model.data(), (unsigned)model.size())) return 5;
    constexpr unsigned nf=96;
    std::vector<float> control(nf*10), predicted(nf*126);
    for (unsigned t=0;t<nf;++t) {
        float* c=control.data()+t*10;
        c[0]=0.79f;c[1]=0.12f;c[2]=0.15f;c[3]=0.27f;c[4]=0.55f;c[5]=0.35f;
        c[6]=60.0f/127;c[7]=t==0?1.0f:0.0f;c[8]=t==nf-1?1.0f:0.0f;c[9]=(t+1.0f)/nf;
    }
    if (NeuralAudioPredict(control.data(), predicted.data(), nf, 0, cancelPump)) return 6;
    double start=now();
    if (!NeuralAudioPredict(control.data(),predicted.data(),nf,0,nullptr)) return 7;
    std::printf("network96_seconds=%.6f cancellation_callbacks=%d\n",now()-start,cancelCount);
    writeFile(out/"controls.f32",control.data(),control.size()*4);
    writeFile(out/"raw_native.f32",predicted.data(),predicted.size()*4);
    const unsigned notes[]={60,33,69};
    const char* names[]={"violin_C4","double_bass_A1","trumpet_A4"};
    double timings[3];
    for (unsigned kind=0;kind<3;++kind) {
        std::vector<float> audio(198450);
        start=now();
        if (!NeuralAudioMakeSample(audio.data(),kind,notes[kind],(unsigned)audio.size(),44100,12345+kind,nullptr)) return 8;
        const double elapsed=now()-start;
        timings[kind]=elapsed;
        float peak=0;double rms=0;
        for (float x:audio) {if(!std::isfinite(x))return 9;peak=std::fmax(peak,std::fabs(x));rms+=x*x;}
        std::printf("%s seconds=%.6f peak=%.8f rms=%.8f\n",names[kind],elapsed,peak,std::sqrt(rms/audio.size()));
        wav(out/(std::string(names[kind])+".wav"),audio);
        writeFile(out/(std::string(names[kind])+".f32"),audio.data(),audio.size()*4);
    }
    std::ofstream report(out/"timings.json");
    report << "{\"sample_duration_seconds\":4.5,\"sample_generation_seconds\":["
        << timings[0] << ',' << timings[1] << ',' << timings[2]
        << "],\"truncated_model_rejected\":true,\"invalid_magic_rejected\":true,"
        << "\"cancellation_callbacks_before_abort\":" << cancelCount << "}\n";
    return 0;
}
