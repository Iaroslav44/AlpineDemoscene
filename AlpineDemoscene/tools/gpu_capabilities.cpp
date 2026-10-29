// Development-only capability report. This executable is not shipped in the demo.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_4.h>
#include <cstdio>
#include <string>

static std::string json_string(const wchar_t* source) {
    int count = WideCharToMultiByte(CP_UTF8, 0, source, -1, nullptr, 0, nullptr, nullptr);
    std::string text(count > 0 ? count : 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, source, -1, &text[0], count, nullptr, nullptr);
    std::string escaped = "\"";
    for (size_t i = 0; i + 1 < text.size(); ++i) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        if (c == '\\' || c == '"') escaped += '\\';
        if (c < 32) {
            char code[7]; sprintf_s(code, "\\u%04x", c); escaped += code;
        } else escaped += static_cast<char>(c);
    }
    return escaped + "\"";
}

static void memory_info(IDXGIAdapter3* adapter, DXGI_MEMORY_SEGMENT_GROUP segment) {
    DXGI_QUERY_VIDEO_MEMORY_INFO info{};
    HRESULT hr = adapter->QueryVideoMemoryInfo(0, segment, &info);
    if (FAILED(hr)) { std::printf("null"); return; }
    std::printf("{\"budget_bytes\":%llu,\"current_usage_bytes\":%llu,\"available_for_reservation_bytes\":%llu}",
        info.Budget, info.CurrentUsage, info.AvailableForReservation);
}

int main() {
    MEMORYSTATUSEX memory{}; memory.dwLength = sizeof(memory);
    if (!GlobalMemoryStatusEx(&memory)) return 1;
    IDXGIFactory1* factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)))) return 2;
    std::printf("{\"schema\":1,\"physical_memory_bytes\":%llu,\"available_physical_memory_bytes\":%llu,\"adapters\":[",
        memory.ullTotalPhys, memory.ullAvailPhys);
    bool first = true;
    for (UINT index = 0; ; ++index) {
        IDXGIAdapter1* adapter = nullptr;
        if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) break;
        if (!adapter) { factory->Release(); return 3; }
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc))) { adapter->Release(); factory->Release(); return 4; }
        if (!first) std::printf(","); first = false;
        D3D_FEATURE_LEVEL requested[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0 };
        D3D_FEATURE_LEVEL level{};
        ID3D11Device* device = nullptr;
        HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
            requested, ARRAYSIZE(requested), D3D11_SDK_VERSION, &device, &level, nullptr);
        if (hr == E_INVALIDARG) hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
            requested + 1, ARRAYSIZE(requested) - 1, D3D11_SDK_VERSION, &device, &level, nullptr);
        std::printf("{\"index\":%u,\"name\":%s,\"vendor_id\":%u,\"device_id\":%u,\"software\":%s,"
            "\"dedicated_video_memory_bytes\":%llu,\"dedicated_system_memory_bytes\":%llu,\"shared_system_memory_bytes\":%llu,"
            "\"d3d11_device_created\":%s,\"feature_level\":%u,\"local_memory\":",
            index, json_string(desc.Description).c_str(), desc.VendorId, desc.DeviceId,
            (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? "true" : "false",
            static_cast<unsigned long long>(desc.DedicatedVideoMemory),
            static_cast<unsigned long long>(desc.DedicatedSystemMemory),
            static_cast<unsigned long long>(desc.SharedSystemMemory), SUCCEEDED(hr) ? "true" : "false", static_cast<unsigned>(level));
        IDXGIAdapter3* adapter3 = nullptr;
        if (SUCCEEDED(adapter->QueryInterface(__uuidof(IDXGIAdapter3), reinterpret_cast<void**>(&adapter3)))) {
            memory_info(adapter3, DXGI_MEMORY_SEGMENT_GROUP_LOCAL);
            std::printf(",\"nonlocal_memory\":"); memory_info(adapter3, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL);
            adapter3->Release();
        } else std::printf("null,\"nonlocal_memory\":null");
        std::printf("}");
        if (device) device->Release();
        adapter->Release();
    }
    std::printf("]}\n");
    factory->Release();
    return 0;
}
