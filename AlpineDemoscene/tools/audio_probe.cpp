// Development-only exporter. Links the very same MASM GenerateAudio used by
// the demo; it never creates a graphics device or opens an audio endpoint.
#define NOMINMAX
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <filesystem>
#include <vector>
#include <algorithm>
#include <chrono>
#include "../src/neural_audio.h"
extern "C" {
void GenerateSineTable();
void GenerateAudio();
extern void* audioBuffer;
extern uint32_t noiseState, orchGenerated;
extern float* orchBank;
extern float orchPeak;
}
static constexpr uint32_t rate=44100, frames=rate*128, bankFrames=198450;
static void wave(const std::filesystem::path& path, const int16_t* data, uint32_t n, uint16_t channels=2){
    FILE* f=nullptr; _wfopen_s(&f,path.c_str(),L"wb"); if(!f){std::fprintf(stderr,"Cannot write WAV\n");std::exit(2);}
    const uint32_t bytes=n*channels*2, riff=bytes+36, fmt=16, byteRate=rate*channels*2;
    const uint16_t pcm=1, align=channels*2, bits=16;
    std::fwrite("RIFF",1,4,f);std::fwrite(&riff,4,1,f);std::fwrite("WAVEfmt ",1,8,f);
    std::fwrite(&fmt,4,1,f);std::fwrite(&pcm,2,1,f);std::fwrite(&channels,2,1,f);
    std::fwrite(&rate,4,1,f);std::fwrite(&byteRate,4,1,f);std::fwrite(&align,2,1,f);std::fwrite(&bits,2,1,f);
    std::fwrite("data",1,4,f);std::fwrite(&bytes,4,1,f);std::fwrite(data,1,bytes,f);std::fclose(f);
}
int wmain(int argc,wchar_t** argv){
    auto out=argc>1?std::filesystem::path(argv[1]):std::filesystem::path(L"build/audio_revision");
    std::filesystem::create_directories(out);
    const uint32_t seed=argc>2?uint32_t(std::wcstoul(argv[2],nullptr,0)):0x4a197c3d;
    noiseState=seed?seed:1;
    // The production host initializes both graphics and audio models together.
    // This audio-only QA process loads the exact embedded resource without
    // starting the renderer or silently using a procedural fallback.
    HRSRC modelResource=FindResourceW(nullptr,MAKEINTRESOURCEW(201),MAKEINTRESOURCEW(10));
    HGLOBAL modelData=modelResource?LoadResource(nullptr,modelResource):nullptr;
    const DWORD modelBytes=modelResource?SizeofResource(nullptr,modelResource):0;
    if(!modelData||!NeuralAudioInit(LockResource(modelData),modelBytes)){
        std::fprintf(stderr,"Embedded neural audio model initialization failed\n");return 6;
    }
    audioBuffer=VirtualAlloc(nullptr,frames*4,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    if(!audioBuffer)return 3;
    auto t=std::chrono::steady_clock::now(); GenerateSineTable();GenerateAudio();
    double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-t).count();
    if(!orchGenerated||!orchBank){std::fprintf(stderr,"Orchestra generation failed\n");return 4;}
    wave(out/L"orchestral_house_full.wav",static_cast<int16_t*>(audioBuffer),frames);
    wave(out/L"orchestral_house_excerpt.wav",static_cast<int16_t*>(audioBuffer)+44100*32*2,44100*24);
    uint64_t nonfinite=0;double bankPeak=0;
    for(size_t i=0;i<size_t(bankFrames)*18;++i){float v=orchBank[i];if(!std::isfinite(v))++nonfinite;else bankPeak=std::max(bankPeak,std::abs(double(v)));}
    const wchar_t* names[]={L"violin_C4.wav",L"double_bass_A1.wav",L"trumpet_A4.wav"};
    const unsigned indices[]={3,12,15};
    for(unsigned k=0;k<3;++k){
        uint32_t n=k==1?rate*2:rate*3;
        std::vector<int16_t> pcm(n);
        for(uint32_t i=0;i<n;++i){float v=orchBank[indices[k]*bankFrames+i];float fade=std::min(1.0f,float(n-i)/8820.0f);pcm[i]=int16_t(std::clamp(v*fade*fade*32767,-32767.0f,32767.0f));}
        wave(out/names[k],pcm.data(),n,1);
    }
    FILE* f=nullptr; _wfopen_s(&f,(out/L"generation.json").c_str(),L"w");
    std::fprintf(f,"{\"seed\":%u,\"seconds\":%.6f,\"bank_nonfinite\":%llu,\"bank_peak\":%.9f,\"mix_peak_before_master_gain\":%.9f,\"master_gain\":1.55,\"bank_bytes\":%u,\"frames\":%u,\"sample_rate\":%u}\n",seed,elapsed,(unsigned long long)nonfinite,bankPeak,orchPeak,bankFrames*18*4,frames,rate);
    std::fclose(f);VirtualFree(orchBank,0,MEM_RELEASE);VirtualFree(audioBuffer,0,MEM_RELEASE);
    std::printf("Generated exact production DSP in %.3fs; nonfinite=%llu; bank peak=%.5f; mix peak=%.5f\n",elapsed,(unsigned long long)nonfinite,bankPeak,orchPeak);
    return nonfinite?5:0;
}
