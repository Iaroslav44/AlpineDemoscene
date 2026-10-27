; ALPINE DREAMING
; A no-CRT x64 MASM / Direct3D 11 procedural audiovisual intro.
; Native host, compact DXBC shaders and procedural audio live in one EXE.

option casemap:none

EXTERN  ExitProcess:PROC
EXTERN  GetModuleHandleA:PROC
EXTERN  GetStartupInfoA:PROC
EXTERN  VirtualAlloc:PROC
EXTERN  VirtualFree:PROC
EXTERN  QueryPerformanceCounter:PROC
EXTERN  QueryPerformanceFrequency:PROC
EXTERN  FindResourceA:PROC
EXTERN  LoadResource:PROC
EXTERN  LockResource:PROC
EXTERN  SizeofResource:PROC

EXTERN  RegisterClassExA:PROC
EXTERN  CreateWindowExA:PROC
EXTERN  DefWindowProcA:PROC
EXTERN  DestroyWindow:PROC
EXTERN  PostQuitMessage:PROC
EXTERN  LoadCursorA:PROC
EXTERN  ShowWindow:PROC
EXTERN  UpdateWindow:PROC
EXTERN  PeekMessageA:PROC
EXTERN  TranslateMessage:PROC
EXTERN  DispatchMessageA:PROC
EXTERN  GetSystemMetrics:PROC
EXTERN  MessageBoxA:PROC

EXTERN  D3D11CreateDeviceAndSwapChain:PROC

EXTERN  waveOutOpen:PROC
EXTERN  waveOutPrepareHeader:PROC
EXTERN  waveOutWrite:PROC
EXTERN  waveOutReset:PROC
EXTERN  waveOutUnprepareHeader:PROC
EXTERN  waveOutClose:PROC
EXTERN  waveOutGetPosition:PROC

PUBLIC start

; Windows / DXGI / D3D constants
WM_DESTROY                      EQU 0002h
WM_KEYDOWN                      EQU 0100h
WM_QUIT                         EQU 0012h
VK_ESCAPE                       EQU 001Bh
PM_REMOVE                       EQU 0001h
IDC_ARROW                       EQU 32512
WS_POPUP                        EQU 80000000h
WS_VISIBLE                      EQU 10000000h
SW_SHOW                         EQU 5
MB_ICONERROR                    EQU 10h
CW_RENDER_WIDTH                 EQU 1280
CW_RENDER_HEIGHT                EQU 720
CW_LOW_WIDTH                    EQU 1280
CW_LOW_HEIGHT                   EQU 720
SHADOW_SIZE                     EQU 2048
FLIGHT_ELEMENTS                 EQU 61456
FLIGHT_BYTES                    EQU 983296
WATER_SIZE                      EQU 256
INSTANCE_ELEMENTS               EQU 81152
INSTANCE_BYTES                  EQU INSTANCE_ELEMENTS * 16

DXGI_FORMAT_R8G8B8A8_UNORM      EQU 28
DXGI_USAGE_RENDER_TARGET_OUTPUT EQU 20h
D3D_DRIVER_TYPE_HARDWARE        EQU 1
D3D_DRIVER_TYPE_WARP            EQU 5
D3D11_SDK_VERSION               EQU 7
D3D11_USAGE_DEFAULT             EQU 0
D3D11_USAGE_DYNAMIC             EQU 2
D3D11_BIND_CONSTANT_BUFFER      EQU 4
D3D11_BIND_SHADER_RESOURCE      EQU 8
D3D11_BIND_RENDER_TARGET        EQU 20h
D3D11_CPU_ACCESS_WRITE          EQU 10000h
D3D11_MAP_WRITE_DISCARD         EQU 4
D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST EQU 4
DXGI_FORMAT_R16G16B16A16_FLOAT  EQU 10
D3D11_FILTER_MIN_MAG_MIP_LINEAR EQU 15h
D3D11_TEXTURE_ADDRESS_CLAMP     EQU 3
D3D11_COMPARISON_NEVER          EQU 1

MEM_COMMIT                      EQU 1000h
MEM_RESERVE                     EQU 2000h
MEM_RELEASE                     EQU 8000h
PAGE_READWRITE                  EQU 4

WAVE_FORMAT_PCM                 EQU 1
WAVE_MAPPER                     EQU 0FFFFFFFFh
WHDR_BEGINLOOP                  EQU 4
WHDR_ENDLOOP                    EQU 8
TIME_SAMPLES                    EQU 2
AUDIO_RATE                      EQU 44100
AUDIO_SECONDS                   EQU 128
AUDIO_FRAMES                    EQU AUDIO_RATE * AUDIO_SECONDS
AUDIO_BYTES                     EQU AUDIO_FRAMES * 4
STEP_SAMPLES                    EQU 11025
SINE_BITS                       EQU 11
SINE_SIZE                       EQU 2048

IFNDEF QA_TIME_BITS
QA_TIME_BITS                    EQU 00000000h
ENDIF

.data
align 8
className       db "AlpineDreamingClass",0
windowTitle     db "ALPINE DREAMING - cinematic x64 assembly / Direct3D 11 / deep house / ESC exits",0
errorTitle      db "Alpine Dreaming",0
errorText       db "Direct3D 11 initialization failed. A feature-level 11 GPU or WARP is required.",0

; WNDCLASSEXA, 80 bytes on Win64.
align 8
wndClass:
    dd 80, 3
    dq OFFSET WndProc
    dd 0, 0
    dq 0, 0, 0, 0, 0
    dq OFFSET className
    dq 0

; DXGI_SWAP_CHAIN_DESC, 72 bytes.
align 8
swapDesc:
    dd CW_RENDER_WIDTH, CW_RENDER_HEIGHT
    dd 60, 1
    dd DXGI_FORMAT_R8G8B8A8_UNORM, 0, 0
    dd 1, 0
    dd DXGI_USAGE_RENDER_TARGET_OUTPUT
    dd 2
    dd 0
    dq 0
    dd 1, 0, 0, 0

; Output and scene D3D11_VIEWPORTs (both native 1280x720).
align 8
outputViewport:
    dd 00000000h, 00000000h
    dd 44A00000h, 44340000h        ; 1280.0, 720.0
    dd 00000000h, 3F800000h

align 8
lowViewport:
    dd 00000000h, 00000000h
    dd 44A00000h, 44340000h        ; native 1280.0, 720.0
    dd 00000000h, 3F800000h
reflectionViewport:
    dd 0, 0, 44200000h, 43B40000h, 0, 3F800000h ; 640x360

; D3D11_BUFFER_DESC: two float4s, dynamic CPU write.
align 8
constantBufferDesc:
    dd 32
    dd D3D11_USAGE_DYNAMIC
    dd D3D11_BIND_CONSTANT_BUFFER
    dd D3D11_CPU_ACCESS_WRITE
    dd 0, 0

; D3D11_TEXTURE2D_DESCs for the native scene and two HDR histories.
align 8
lowSurfaceDesc:
    dd CW_LOW_WIDTH, CW_LOW_HEIGHT
    dd 1, 1
    dd DXGI_FORMAT_R16G16B16A16_FLOAT
    dd 1, 0
    dd D3D11_USAGE_DEFAULT
    dd D3D11_BIND_SHADER_RESOURCE or D3D11_BIND_RENDER_TARGET
    dd 0, 0

align 8
historySurfaceDesc:
    dd CW_RENDER_WIDTH, CW_RENDER_HEIGHT
    dd 1, 1
    dd DXGI_FORMAT_R16G16B16A16_FLOAT
    dd 1, 0
    dd D3D11_USAGE_DEFAULT
    dd D3D11_BIND_SHADER_RESOURCE or D3D11_BIND_RENDER_TARGET
    dd 0, 0

; D3D11_SAMPLER_DESC: bilinear clamp for temporal history and display.
align 8
postSamplerDesc:
    dd D3D11_FILTER_MIN_MAG_MIP_LINEAR
    dd D3D11_TEXTURE_ADDRESS_CLAMP
    dd D3D11_TEXTURE_ADDRESS_CLAMP
    dd D3D11_TEXTURE_ADDRESS_CLAMP
    dd 00000000h
    dd 1
    dd D3D11_COMPARISON_NEVER
    dd 00000000h, 00000000h, 00000000h, 00000000h
    dd 00000000h
    dd 7F7FFFFFh

; Anisotropic wrap sampling for runtime-generated material arrays.
materialSamplerDesc:
    dd 55h, 1, 1, 1, 0, 8, D3D11_COMPARISON_NEVER
    dd 0, 0, 0, 0, 0, 7F7FFFFFh

align 8
clearHistoryColour dd 00000000h, 00000000h, 00000000h, 00000000h
clearShadowColour dd 3F800000h, 3F800000h, 3F800000h, 3F800000h
nullShaderResources dq 0, 0, 0, 0
requiredFeatureLevel dd 0B000h          ; FL11_0, required for camera compute

align 8
shadowViewport:
    dd 0, 0, 45000000h, 45000000h, 0, 3F800000h
shadowSurfaceDesc:
    dd SHADOW_SIZE, SHADOW_SIZE, 1, 1, 41, 1, 0, 0, 28h, 0, 0 ; R32_FLOAT
terrainSurfaceDesc:
    dd 4096, 4096, 1, 1, 41, 1, 0, 0, 88h, 0, 0 ; R32_FLOAT SRV|UAV
materialSurfaceDesc:
    dd 1024, 1024, 11, 8, 28, 1, 0, 0, 0A8h, 0, 1 ; RGBA8 SRV|RTV|UAV, GENERATE_MIPS
materialUAVDesc:
    dd 28, 5, 0, 0, 8                 ; TEXTURE2DARRAY, mip0, all8 layers
atmosphereSurfaceDesc:
    dd 256, 128, 1, 1, 10, 1, 0, 0, 88h, 0, 0 ; RGBA16F SRV|UAV
cloudVolumeDesc:
    dd 128, 128, 128, 1, 28, 0, 88h, 0, 0 ; D3D11_TEXTURE3D_DESC RGBA8
terrainBoundsDesc:
    dd 4096, 4096, 13, 1, 41, 1, 0, 0, 88h, 0, 0
boundsLevelSRVDesc:
    dd 41, 4, 0, 1, 0, 0            ; R32_FLOAT, TEXTURE2D, one mip only
boundsLevelUAVDesc:
    dd 41, 4, 0, 0, 0
boundsBuildConstants dd 0, 0, 0, 0
farShadowSurfaceDesc:
    dd 1024, 1024, 1, 1, 41, 1, 0, 0, 28h, 0, 0
farShadowDepthDesc:
    dd 1024, 1024, 1, 1, 40, 1, 0, 0, 40h, 0, 0
farShadowViewport:
    dd 0, 0, 44800000h, 44800000h, 0, 3F800000h
reflectionSurfaceDesc:
    dd 640, 360, 1, 1, 10, 1, 0, 0, 28h, 0, 0 ; RGBA16F
reflectionDepthDesc:
    dd 640, 360, 1, 1, 40, 1, 0, 0, 40h, 0, 0
passMainUnavailable dd 0, 0, 0, 0
passMainAvailable dd 0, 3F800000h, 0, 0
passReflection dd 3F800000h, 3F800000h, 0, 0
passFarShadow dd 0, 0, 3F800000h, 0
reflectionBegin REAL4 40.0
reflectionEnd REAL4 108.0
loopSeconds REAL4 128.0
mainDepthDesc:
    dd CW_LOW_WIDTH, CW_LOW_HEIGHT, 1, 1, 40, 1, 0, 0, 40h, 0, 0 ; D32_FLOAT
shadowDepthDesc:
    dd SHADOW_SIZE, SHADOW_SIZE, 1, 1, 40, 1, 0, 0, 40h, 0, 0
cameraBufferDesc:
    dd 240, 0, 88h, 0, 40h, 16          ; 15 float4, including far-shadow frame
batchBufferDesc:
    dd 16, 0, 4, 0, 0, 0               ; default constant buffer, one uint4
cameraSRVDesc:
    dd 0, 1, 0, 15, 0, 0               ; UNKNOWN, BUFFER, 15 elements
cameraUAVDesc:
    dd 0, 1, 0, 15, 0
instanceBufferDesc:
    dd INSTANCE_BYTES, 0, 88h, 0, 40h, 16
instanceSRVDesc:
    dd 0, 1, 0, INSTANCE_ELEMENTS, 0, 0
instanceUAVDesc:
    dd 0, 1, 0, INSTANCE_ELEMENTS, 0
flightBufferDesc:
    dd FLIGHT_BYTES, 0, 88h, 0, 40h, 16
flightSRVDesc:
    dd 0, 1, 0, FLIGHT_ELEMENTS, 0, 0
flightUAVDesc:
    dd 0, 1, 0, FLIGHT_ELEMENTS, 0
waterSurfaceDesc:
    dd WATER_SIZE, WATER_SIZE, 1, 1, 2, 1, 0, 0, 88h, 0, 0 ; RGBA32F SRV|UAV
physicsRate REAL4 60.0
physicsDelta REAL4 0.0166666666667
physicsConstants dd 3C888889h, 0, 0, 0 ; dt,time,mode,integer step as float
meshRasterizerDesc:
    dd 3, 1, 0, 0, 0, 0, 1, 0, 0, 0 ; SOLID, CULL_NONE, depth clip on
postDepthStateDesc:
    dd 0, 0, 8, 0
    db 0FFh, 0FFh, 0, 0
    dd 1, 1, 1, 8, 1, 1, 1, 8
worldDepthStateDesc:
    dd 1, 1, 4, 0                     ; enabled/write-all/LESS_EQUAL/stencil off
    db 0FFh, 0FFh, 0, 0
    dd 1, 1, 1, 8, 1, 1, 1, 8
; Fixed procedural mesh contract shared by main and shadow draws.
; b1 uint4 (absolute instance base, padding), vertex count, instance count, pad.
; SV_InstanceID starts at zero even with nonzero StartInstanceLocation. Supply
; the procedural dispatch base explicitly in b1; both API start offsets are 0.
meshDrawBatches:
    dd 0, 0, 0, 0, 11520, 64, 0, 0
    dd 1000, 0, 0, 0, 15624, 192, 0, 0
    dd 2000, 0, 0, 0, 48, 12288, 0, 0
    dd 20000, 0, 0, 0, 240, 384, 0, 0
    dd 30000, 0, 0, 0, 12288, 4, 0, 0
    dd 40000, 0, 0, 0, 288, 6144, 0, 0
    dd 50000, 0, 0, 0, 432, 6, 0, 0    ; shadow-only residents
; At 3.516m/texel individual blades and residents are subpixel. Near trees use
; their 288-vertex crown envelope only in this far shadow pass.
farMeshDrawBatches:
    dd 0, 0, 0, 0, 11520, 64, 0, 0
    dd 1000, 0, 0, 0, 288, 192, 0, 0
    dd 20000, 0, 0, 0, 240, 384, 0, 0
    dd 30000, 0, 0, 0, 12288, 4, 0, 0
    dd 40000, 0, 0, 0, 288, 6144, 0, 0

; WAVEFORMATEX: 44.1 kHz, stereo, signed 16-bit PCM.
align 8
waveFormat:
    dw WAVE_FORMAT_PCM, 2
    dd AUDIO_RATE, AUDIO_RATE * 4
    dw 4, 16, 0

twoPiOverTable REAL8 0.00306796157577128246
sineAmplitude  REAL8 32760.0
inv65535       REAL4 0.0000152590218967
audioRateF     REAL4 44100.0
qaTimeOffset   dd QA_TIME_BITS

; Exact Q0.32 phase increments for MIDI notes 36..96 at 44.1 kHz.
align 4
noteIncrements dd 6370030,6748811,7150117,7575285,8025735,8502970,9008582,9544261
               dd 10111792,10713070,11350103,12025015,12740059,13497623,14300233,15150569
               dd 16051469,17005939,18017165,19088521,20223584,21426141,22700205,24050030
               dd 25480119,26995246,28600467,30301139,32102938,34011878,36034330,38177043
               dd 40447168,42852281,45400411,48100060,50960238,53990491,57200933,60602278
               dd 64205876,68023757,72068660,76354085,80894335,85704563,90800821,96200119
               dd 101920476,107980983,114401866,121204555,128411753,136047513,144137319,152708170
               dd 161788671,171409126,181601643,192400238,203840952

; Eight-bar modal deep-house loop: Am9 - G6/9 - Fmaj9 - Em7(add11), two
; bars per chord.  Smooth rootless voicings descend while the sub supplies
; each missing root, avoiding both a pop cadence and a lead-like top line.
bassRoots   db 45,43,41,40                 ; A2, G2, F2, E2 (rendered one octave down)
chordVoice1 db 60,59,57,55                 ; C4, B3, A3, G3
chordVoice2 db 64,64,64,62                 ; E4, E4, E4, D4
chordVoice3 db 71,69,67,69                 ; B4, A4, G4, A4

; Eighth-note bass rhythm.  Even positions are deliberate kick gaps;
; odd positions use root, fifth or octave, with rests preventing nursery-rhyme
; regularity.  Values are semitone offsets; 127 is a rest.
bassPattern db 127,0,127,7, 127,127,127,0
            db 127,0,127,127, 127,7,127,0
            db 127,0,127,0, 127,127,127,7
            db 127,0,127,7, 127,0,127,127

.data?
align 16
hInstance               dq ?
hWindow                 dq ?
swapChain               dq ?
d3dDevice               dq ?
d3dContext              dq ?
renderTarget            dq ?
backBuffer              dq ?
vertexShader            dq ?
pixelShader             dq ?
humanShader             dq ?
temporalShader          dq ?
displayShader           dq ?
meshVertexShader        dq ?
meshPixelShader         dq ?
shadowVertexShader      dq ?
shadowPixelShader       dq ?
cameraComputeShader     dq ?
terrainComputeShader    dq ?
flightComputeShader     dq ?
waterComputeShader      dq ?
physicsConstantBuffer   dq ?
flightBuffer            dq ?
flightSRV               dq ?
flightUAV               dq ?
waterTextures           dq 2 dup (?)
waterSRVs               dq 2 dup (?)
waterUAVs               dq 2 dup (?)
waterIndex              dd ?
waterStep               dd ?
physicsTargetStep       dd ?
physicsBinding          dq ?
startupCancelled        dd ?
startupHidden           dd ?
startupInfo             db 104 dup (?) ; STARTUPINFOA, native x64 layout
terrainTexture          dq ?
terrainSRV              dq ?
terrainUAV              dq ?
materialComputeShader   dq ?
materialTextures        dq 2 dup (?)
materialSRVs            dq 2 dup (?)
materialUAVs            dq 2 dup (?)
materialSampler         dq ?
atmosphereComputeShader dq ?
atmosphereTexture       dq ?
atmosphereSRV           dq ?
atmosphereUAV           dq ?
farShadowTexture        dq ?
farShadowSRV            dq ?
farShadowRTV            dq ?
farShadowDepthTexture   dq ?
farShadowDepthView      dq ?
cameraFrameBuffer       dq ?
instanceComputeShader   dq ?
instanceBuffer          dq ?
instanceSRV             dq ?
instanceUAV             dq ?
cloudComputeShader      dq ?
cloudCompositeShader    dq ?
cloudedTexture          dq ?
cloudedSRV              dq ?
cloudedRTV              dq ?
reflectionCloudTexture  dq ?
reflectionCloudSRV      dq ?
reflectionCloudRTV      dq ?
cloudInputBinding       dq ?
cloudOutputBinding      dq ?
cloudViewportBinding    dq ?
postDepthState          dq ?
cloudTexture            dq ?
cloudSRV                dq ?
cloudUAV                dq ?
boundsComputeShader     dq ?
boundsTexture           dq ?
boundsSRV               dq ?
boundsLevelSRVs         dq 13 dup (?)
boundsLevelUAVs         dq 13 dup (?)
batchConstantBuffer     dq ?
passConstantBuffer      dq ?
reflectionTexture       dq ?
reflectionSRV           dq ?
reflectionRTV           dq ?
reflectionDepthTexture  dq ?
reflectionDepthView     dq ?
reflectionEnabled       dd ?
cameraFrameSRV          dq ?
cameraFrameUAV          dq ?
mainDepthTexture        dq ?
mainDepthView           dq ?
shadowDepthTexture      dq ?
shadowDepthView         dq ?
shadowTexture           dq ?
shadowSRV               dq ?
shadowRTV               dq ?
meshRasterizer          dq ?
worldDepthState         dq ?
constantBuffer          dq ?
postSampler             dq ?
lowTexture              dq ?
lowSRV                  dq ?
lowRTV                  dq ?
lowBTexture             dq ?
lowBSRV                 dq ?
lowBRTV                 dq ?
historyTexture0         dq ?
historySRV0             dq ?
historyRTV0             dq ?
historyTexture1         dq ?
historySRV1             dq ?
historyRTV1             dq ?
temporalBindings        dq 2 dup (?)
displayBinding          dq ?
nextRTVBinding          dq ?
featureLevel            dd ?
windowX                 dd ?
windowY                 dd ?
windowW                 dd ?
windowH                 dd ?

resourceVS              dq ?
resourcePS              dq ?
shaderVSPtr             dq ?
shaderPSPtr             dq ?
shaderVSSize            dd ?
shaderPSSize            dd ?

messageData             db 48 dup (?)
mappedData              db 16 dup (?)
qpcFrequency            dq ?
qpcStart                dq ?
qpcNow                  dq ?
currentTime             dd ?
previousTime            dd ?
runSeed                 dd ?
frameCounter            dd ?
historyIndex            dd ?

audioBuffer             dq ?
audioHandle             dq ?
audioEnabled            dd ?
waveHeader              db 48 dup (?)
mmTime                   db 12 dup (?)     ; sizeof(MMTIME), also on Win64

audioStep               dd ?
audioStepPos            dd ?
noiseState              dd ?
noiseFast               dd ?
noiseSlow               dd ?
bassPhase               dd ?
bassModPhase            dd ?
stabPhase1               dd ?
stabPhase2               dd ?
stabPhase3               dd ?
kickPhase               dd ?
bassIncrement           dd ?
bassModIncrement        dd ?
stabIncrement1          dd ?
stabIncrement2          dd ?
stabIncrement3          dd ?
kickIncrement           dd ?
bassActive              dd ?
stabActive              dd ?
synthTempIndex          dd ?

align 16
sineTable               dw SINE_SIZE dup (?)
align 16
delayLeft               dw 65536 dup (?)
delayRight              dw 65536 dup (?)

.code

; -----------------------------------------------------------------------------
; Standard window procedure. Escape is the only control: the piece otherwise
; unfolds without UI, as a demoscene intro should.
; -----------------------------------------------------------------------------
WndProc PROC
    cmp edx, WM_DESTROY
    je  wnd_destroy
    cmp edx, WM_KEYDOWN
    jne wnd_default
    cmp r8d, VK_ESCAPE
    jne wnd_default
    sub rsp, 28h
    call DestroyWindow
    add rsp, 28h
    xor eax, eax
    ret
wnd_destroy:
    sub rsp, 28h
    xor ecx, ecx
    call PostQuitMessage
    add rsp, 28h
    xor eax, eax
    ret
wnd_default:
    sub rsp, 28h
    call DefWindowProcA
    add rsp, 28h
    ret
WndProc ENDP

ReleaseObject PROC
    test rcx, rcx
    jz release_done
    sub rsp, 28h
    mov rax, [rcx]
    call qword ptr [rax+16]
    add rsp, 28h
release_done:
    ret
ReleaseObject ENDP

; Create one Texture2D together with its default SRV and RTV.
; rcx = D3D11_TEXTURE2D_DESC, rdx = texture slot, r8 = SRV slot, r9 = RTV slot.
CreateRenderSurface PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 28h
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12, r9
    mov qword ptr [rsi], 0
    mov qword ptr [rdi], 0
    mov qword ptr [r12], 0

    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, rbx
    xor r8d, r8d
    mov r9, rsi
    call qword ptr [rax+40]              ; CreateTexture2D
    mov ebx, eax
    test eax, eax
    js create_surface_done

    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, [rsi]
    xor r8d, r8d
    mov r9, rdi
    call qword ptr [rax+56]              ; CreateShaderResourceView
    mov ebx, eax
    test eax, eax
    js create_surface_done

    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, [rsi]
    xor r8d, r8d
    mov r9, r12
    call qword ptr [rax+72]              ; CreateRenderTargetView
    mov ebx, eax

create_surface_done:
    mov eax, ebx
    add rsp, 28h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
CreateRenderSurface ENDP

; Load one embedded DXBC resource and create a pixel shader from it.
; ecx = RT_RCDATA id, rdx = ID3D11PixelShader output slot.
LoadEmbeddedPixelShader PROC
    mov r8d, 120
    jmp LoadEmbeddedShader
LoadEmbeddedPixelShader ENDP

LoadEmbeddedVertexShader PROC
    mov r8d, 96
    jmp LoadEmbeddedShader
LoadEmbeddedVertexShader ENDP

LoadEmbeddedComputeShader PROC
    mov r8d, 144
    jmp LoadEmbeddedShader
LoadEmbeddedComputeShader ENDP

LoadEmbeddedShader PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 28h
    mov r12d, r8d
    mov ebx, ecx
    mov rsi, rdx
    mov qword ptr [rsi], 0

    mov rcx, hInstance
    mov edx, ebx
    mov r8d, 10
    call FindResourceA
    test rax, rax
    jz embedded_shader_failed
    mov rdi, rax

    mov rcx, hInstance
    mov rdx, rdi
    call SizeofResource
    test eax, eax
    jz embedded_shader_failed
    mov ebx, eax

    mov rcx, hInstance
    mov rdx, rdi
    call LoadResource
    test rax, rax
    jz embedded_shader_failed
    mov rcx, rax
    call LockResource
    test rax, rax
    jz embedded_shader_failed
    mov rdi, rax

    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, rdi
    mov r8d, ebx
    xor r9d, r9d
    mov qword ptr [rsp+20h], rsi
    call qword ptr [rax+r12]             ; Create{Vertex,Pixel,Compute}Shader
    jmp embedded_shader_done

embedded_shader_failed:
    mov eax, 80004005h
embedded_shader_done:
    add rsp, 28h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
LoadEmbeddedShader ENDP

; rcx = depth texture descriptor, rdx = texture slot, r8 = DSV slot.
CreateDepthSurface PROC
    push rbx
    push rsi
    push rdi
    sub rsp, 20h
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, rbx
    xor r8d, r8d
    mov r9, rsi
    call qword ptr [rax+40]
    test eax, eax
    js depth_surface_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, [rsi]
    xor r8d, r8d
    mov r9, rdi
    call qword ptr [rax+80]              ; CreateDepthStencilView
depth_surface_done:
    add rsp, 20h
    pop rdi
    pop rsi
    pop rbx
    ret
CreateDepthSurface ENDP

DrawSceneBatches PROC
    lea rdx, meshDrawBatches
    jmp DrawBatchTable
DrawSceneBatches ENDP

; ecx=count, rdx=immutable table. Main and far shadow share the same ABI.
DrawBatchTable PROC
    push rbx
    push rsi
    sub rsp, 48h
    mov rbx, rdx
    mov esi, ecx                      ; six main batches, seven shadow batches
draw_batch_loop:
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, batchConstantBuffer
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp+20h], rbx
    mov dword ptr [rsp+28h], 0
    mov dword ptr [rsp+30h], 0
    call qword ptr [rax+384]            ; UpdateSubresource: b1 absolute base
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, [rbx+16]
    mov r8d, [rbx+20]
    xor r9d, r9d
    mov dword ptr [rsp+20h], 0
    call qword ptr [rax+168]             ; DrawInstanced
    add rbx, 32
    dec esi
    jnz draw_batch_loop
    add rsp, 48h
    pop rsi
    pop rbx
    ret
DrawBatchTable ENDP

; Rewrite all eight floats: WRITE_DISCARD never preserves the other fields.
; ecx/edx are bit patterns for this pass's scene width/height. O.w stays the
; previous rendered frame even when b0 is rewritten for a reflection subpass.
UpdateFrameConstants PROC
    push rbx
    push rsi
    sub rsp, 38h
    mov ebx, ecx
    mov esi, edx
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, constantBuffer
    xor r8d, r8d
    mov r9d, D3D11_MAP_WRITE_DISCARD
    mov dword ptr [rsp+20h], 0
    lea r10, mappedData
    mov qword ptr [rsp+28h], r10
    call qword ptr [rax+112]
    test eax, eax
    js frame_constants_done
    mov rax, qword ptr mappedData[0]
    mov [rax], ebx
    mov [rax+4], esi
    movss xmm0, currentTime
    movss dword ptr [rax+8], xmm0
    cvtsi2ss xmm0, frameCounter
    movss dword ptr [rax+12], xmm0
    mov dword ptr [rax+16], 44A00000h
    mov dword ptr [rax+20], 44340000h
    movss xmm0, runSeed
    movss dword ptr [rax+24], xmm0
    movss xmm0, previousTime
    movss dword ptr [rax+28], xmm0
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, constantBuffer
    xor r8d, r8d
    call qword ptr [rax+120]
    xor eax, eax
frame_constants_done:
    add rsp, 38h
    pop rsi
    pop rbx
    ret
UpdateFrameConstants ENDP

; rcx points to one immutable float4 describing reflection/main pass state.
UpdatePassConstants PROC
    sub rsp, 38h
    mov qword ptr [rsp+20h], rcx
    mov dword ptr [rsp+28h], 0
    mov dword ptr [rsp+30h], 0
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, passConstantBuffer
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+384]
    add rsp, 38h
    ret
UpdatePassConstants ENDP

; Startup and long fixed-step catch-up remain cancellable between GPU calls.
; A driver call itself may still be synchronous; this does not claim otherwise.
PumpInitializationMessages PROC
    sub rsp, 28h
pump_init_loop:
    lea rcx, messageData
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov dword ptr [rsp+20h], PM_REMOVE
    call PeekMessageA
    test eax, eax
    jz pump_init_done
    cmp dword ptr messageData[8], WM_QUIT
    je pump_init_cancel
    lea rcx, messageData
    call TranslateMessage
    lea rcx, messageData
    call DispatchMessageA
    jmp pump_init_loop
pump_init_cancel:
    mov startupCancelled, 1
pump_init_done:
    mov eax, startupCancelled
    add rsp, 28h
    ret
PumpInitializationMessages ENDP

; rcx=texture descriptor, rdx/r8/r9=texture/SRV/UAV output slots.
CreateComputeSurface PROC
    push rbx
    push rsi
    push rdi
    push r12
    sub rsp, 28h
    mov rbx, rcx
    mov rsi, rdx
    mov rdi, r8
    mov r12, r9
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, rbx
    xor r8d, r8d
    mov r9, rsi
    call qword ptr [rax+40]
    test eax, eax
    js compute_surface_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, [rsi]
    xor r8d, r8d
    mov r9, rdi
    call qword ptr [rax+56]
    test eax, eax
    js compute_surface_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, [rsi]
    xor r8d, r8d
    mov r9, r12
    cmp dword ptr [rbx+12], 8           ; material arrays need explicit mip0 UAV
    jne compute_default_uav
    lea r8, materialUAVDesc
compute_default_uav:
    call qword ptr [rax+64]
compute_surface_done:
    add rsp, 28h
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
CreateComputeSurface ENDP

UpdatePhysicsConstants PROC
    sub rsp, 38h
    lea rax, physicsConstants
    mov qword ptr [rsp+20h], rax
    mov dword ptr [rsp+28h], 0
    mov dword ptr [rsp+30h], 0
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, physicsConstantBuffer
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+384]
    add rsp, 38h
    ret
UpdatePhysicsConstants ENDP

ResetWaterSimulation PROC
    sub rsp, 28h
    mov waterIndex, 0
    mov waterStep, 0
    mov dword ptr physicsConstants[4], 0
    mov dword ptr physicsConstants[8], 0
    mov dword ptr physicsConstants[12], 0
    call UpdatePhysicsConstants
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, waterSRVs[8]
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, waterComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, waterUAVs
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 32
    mov r8d, 32
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    add rsp, 28h
    ret
ResetWaterSimulation ENDP

; Fixed 60Hz integration follows the audio clock, independent of display FPS.
; Replay starts from deterministic state after backwards seeks or the loop cut.
AdvanceWaterSimulation PROC
    push rbx
    sub rsp, 30h
    movss xmm0, currentTime
    movaps xmm1, xmm0
    divss xmm1, loopSeconds
    cvttss2si eax, xmm1
    cvtsi2ss xmm1, eax
    mulss xmm1, loopSeconds
    subss xmm0, xmm1
    maxss xmm0, clearHistoryColour
    mulss xmm0, physicsRate
    cvttss2si eax, xmm0
    mov physicsTargetStep, eax
    cmp eax, waterStep
    jae water_no_reset
    call ResetWaterSimulation
water_no_reset:
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, waterComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
water_step_loop:
    mov eax, waterStep
    cmp eax, physicsTargetStep
    jae water_step_done
    cvtsi2ss xmm0, eax
    movss dword ptr physicsConstants[12], xmm0
    divss xmm0, physicsRate
    movss dword ptr physicsConstants[4], xmm0
    mov dword ptr physicsConstants[8], 3F800000h
    call UpdatePhysicsConstants
    mov ebx, waterIndex
    lea r9, waterSRVs
    lea r9, [r9+rbx*8]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    call qword ptr [rax+536]
    xor ebx, 1
    lea r9, waterUAVs
    lea r9, [r9+rbx*8]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 32
    mov r8d, 32
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov waterIndex, ebx
    inc waterStep
    test waterStep, 63
    jnz water_step_loop
    call PumpInitializationMessages
    test eax, eax
    jnz water_sim_cancel
    jmp water_step_loop
water_step_done:
    mov ebx, waterIndex
    lea rax, waterSRVs
    mov rax, [rax+rbx*8]
    mov physicsBinding, rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, physicsBinding
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, physicsBinding
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 7
    mov r8d, 1
    lea r9, physicsBinding
    call qword ptr [rax+536]
    xor eax, eax
water_sim_cancel:
    add rsp, 30h
    pop rbx
    ret
AdvanceWaterSimulation ENDP

; rcx=input HDR SRV, rdx=separate HDR RTV, r8=viewport. All opaque geometry,
; including characters, must be present before clouds integrate to its depth.
CompositeClouds PROC
    sub rsp, 28h
    mov cloudInputBinding, rcx
    mov cloudOutputBinding, rdx
    mov cloudViewportBinding, r8
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 2
    lea r9, nullShaderResources
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, cloudOutputBinding
    xor r9d, r9d
    call qword ptr [rax+264]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, postDepthState
    xor r8d, r8d
    call qword ptr [rax+288]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8, cloudViewportBinding
    call qword ptr [rax+352]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, cloudInputBinding
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, vertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, cloudCompositeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+72]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    xor r8d, r8d
    call qword ptr [rax+104]
    add rsp, 28h
    ret
CompositeClouds ENDP

CreateGeneratedVolumes PROC
    push rbx
    sub rsp, 20h
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, cloudVolumeDesc
    xor r8d, r8d
    lea r9, cloudTexture
    call qword ptr [rax+48]            ; CreateTexture3D
    test eax, eax
    js generated_volumes_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, cloudTexture
    xor r8d, r8d
    lea r9, cloudSRV
    call qword ptr [rax+56]
    test eax, eax
    js generated_volumes_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, cloudTexture
    xor r8d, r8d
    lea r9, cloudUAV
    call qword ptr [rax+64]
    test eax, eax
    js generated_volumes_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, terrainBoundsDesc
    xor r8d, r8d
    lea r9, boundsTexture
    call qword ptr [rax+40]
    test eax, eax
    js generated_volumes_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, boundsTexture
    xor r8d, r8d
    lea r9, boundsSRV
    call qword ptr [rax+56]
    test eax, eax
    js generated_volumes_done
    xor ebx, ebx
create_bounds_view_loop:
    mov dword ptr boundsLevelSRVDesc[8], ebx
    mov dword ptr boundsLevelUAVDesc[8], ebx
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, boundsTexture
    lea r8, boundsLevelSRVDesc
    lea r9, boundsLevelSRVs[rbx*8]
    call qword ptr [rax+56]
    test eax, eax
    js generated_volumes_done
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, boundsTexture
    lea r8, boundsLevelUAVDesc
    lea r9, boundsLevelUAVs[rbx*8]
    call qword ptr [rax+64]
    test eax, eax
    js generated_volumes_done
    inc ebx
    cmp ebx, 13
    jb create_bounds_view_loop
generated_volumes_done:
    add rsp, 20h
    pop rbx
    ret
CreateGeneratedVolumes ENDP

GenerateCloudVolume PROC
    sub rsp, 28h
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, cloudComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, cloudUAV
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 16
    mov r8d, 16
    mov r9d, 16
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 13
    mov r8d, 1
    lea r9, cloudSRV
    call qword ptr [rax+64]
    add rsp, 28h
    ret
GenerateCloudVolume ENDP

GenerateTerrainBounds PROC
    push rbx
    push rsi
    sub rsp, 38h
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, physicsConstantBuffer
    call qword ptr [rax+568]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, boundsComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    xor ebx, ebx
generate_bounds_level:
    cvtsi2ss xmm0, ebx
    movss boundsBuildConstants[8], xmm0
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, physicsConstantBuffer
    xor r8d, r8d
    xor r9d, r9d
    lea r10, boundsBuildConstants
    mov qword ptr [rsp+20h], r10
    mov dword ptr [rsp+28h], 0
    mov dword ptr [rsp+30h], 0
    call qword ptr [rax+384]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 14
    mov r8d, 1
    lea r9, nullShaderResources
    test ebx, ebx
    jz bounds_previous_ready
    lea r9, boundsLevelSRVs[rbx*8-8]
bounds_previous_ready:
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, boundsLevelUAVs[rbx*8]
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov ecx, ebx
    mov esi, 4096
    shr esi, cl
    add esi, 7
    shr esi, 3
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, esi
    mov r8d, esi
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    call PumpInitializationMessages
    test eax, eax
    jnz generate_bounds_done
    inc ebx
    cmp ebx, 13
    jb generate_bounds_level
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 14
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 14
    mov r8d, 1
    lea r9, boundsSRV
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 14
    mov r8d, 1
    lea r9, boundsSRV
    call qword ptr [rax+200]
    xor eax, eax
generate_bounds_done:
    add rsp, 38h
    pop rsi
    pop rbx
    ret
GenerateTerrainBounds ENDP

ReleaseGeneratedVolumes PROC
    push rbx
    sub rsp, 20h
    xor ebx, ebx
release_bounds_views:
    mov rcx, boundsLevelSRVs[rbx*8]
    call ReleaseObject
    mov rcx, boundsLevelUAVs[rbx*8]
    call ReleaseObject
    inc ebx
    cmp ebx, 13
    jb release_bounds_views
    mov rcx, boundsSRV
    call ReleaseObject
    mov rcx, boundsTexture
    call ReleaseObject
    mov rcx, boundsComputeShader
    call ReleaseObject
    mov rcx, cloudUAV
    call ReleaseObject
    mov rcx, cloudSRV
    call ReleaseObject
    mov rcx, cloudTexture
    call ReleaseObject
    mov rcx, cloudComputeShader
    call ReleaseObject
    add rsp, 20h
    pop rbx
    ret
ReleaseGeneratedVolumes ENDP

; Cache per-object placement and branch beam response once per frame instead
; of repeating terrain and wind evaluation for every vertex in every pass.
UpdateSceneInstances PROC
    sub rsp, 28h
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 12
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 12
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 12
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, cameraFrameSRV
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, instanceComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, instanceUAV
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 778
    mov r8d, 1
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 12
    mov r8d, 1
    lea r9, instanceSRV
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 12
    mov r8d, 1
    lea r9, instanceSRV
    call qword ptr [rax+200]
    add rsp, 28h
    ret
UpdateSceneInstances ENDP

; A camera-dependent atmosphere cache is rebuilt every frame. Only the LUT
; generator is embedded; the texture never comes from a file or reference.
UpdateAtmosphere PROC
    sub rsp, 28h
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 10
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, cameraFrameSRV
    call qword ptr [rax+536]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, atmosphereComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, atmosphereUAV
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 32
    mov r8d, 16
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+536]            ; avoid SRV/UAV hazard next CameraCS
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 10
    mov r8d, 1
    lea r9, atmosphereSRV
    call qword ptr [rax+64]
    add rsp, 28h
    ret
UpdateAtmosphere ENDP

RenderFarShadow PROC
    sub rsp, 28h
    lea rcx, passFarShadow
    call UpdatePassConstants
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 11
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    xor r8d, r8d
    call qword ptr [rax+288]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, farShadowRTV
    mov r9, farShadowDepthView
    call qword ptr [rax+264]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, farShadowRTV
    lea r8, clearShadowColour
    call qword ptr [rax+400]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, farShadowDepthView
    mov r8d, 1
    movss xmm3, clearShadowColour
    mov dword ptr [rsp+20h], 0
    call qword ptr [rax+424]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, farShadowViewport
    call qword ptr [rax+352]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, shadowVertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, shadowPixelShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+72]
    mov ecx, 5
    lea rdx, farMeshDrawBatches
    call DrawBatchTable
    ; Detach the RTV before exposing its SRV to lighting.
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+264]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 11
    mov r8d, 1
    lea r9, farShadowSRV
    call qword ptr [rax+64]
    lea rcx, passMainUnavailable
    cmp reflectionEnabled, 0
    je far_shadow_restore_pass
    lea rcx, passMainAvailable
far_shadow_restore_pass:
    call UpdatePassConstants
    add rsp, 28h
    ret
RenderFarShadow ENDP


GenerateSineTable PROC
    xor ecx, ecx
sine_loop:
    mov synthTempIndex, ecx
    fild synthTempIndex
    fmul twoPiOverTable
    fsin
    fmul sineAmplitude
    fistp word ptr sineTable[rcx*2]
    inc ecx
    cmp ecx, SINE_SIZE
    jb sine_loop
    ret
GenerateSineTable ENDP

; -----------------------------------------------------------------------------
; 128-second 120 BPM deep-house arrangement, rendered entirely in integer DSP.
; There is deliberately no lead melody: close-voiced chord stabs, a syncopated
; sub and the rhythm section carry the piece.  The six acts begin on bar lines
; at eighth-note steps 0/80/160/240/336/416/512.
; -----------------------------------------------------------------------------
GenerateAudio PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    mov rdi, audioBuffer
    mov r14d, AUDIO_FRAMES
    xor r15d, r15d
    mov audioStep, -1
    mov audioStepPos, STEP_SAMPLES
    mov noiseFast, 0
    mov noiseSlow, 0

audio_frame_loop:
    mov eax, audioStepPos
    inc eax
    cmp eax, STEP_SAMPLES
    jb store_step_position

    xor eax, eax
    mov audioStepPos, eax
    mov eax, audioStep
    inc eax
    and eax, 511
    mov audioStep, eax
    mov esi, eax

    ; Advance the deterministic noise source once at every sequencer edge.
    mov eax, noiseState
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov noiseState, eax

    ; Two bars per chord, eight bars per modal harmonic cycle.
    mov ecx, esi
    shr ecx, 4
    and ecx, 3
    mov r12d, ecx

    ; Bass is silent in the dawn, lake breakdown and final four-bar outro.
    ; Its notes live only in the off-kick gaps defined by bassPattern.
    mov bassActive, 0
    cmp esi, 80
    jb bass_note_ready
    cmp esi, 240
    jb bass_arrangement_on
    cmp esi, 336
    jb bass_note_ready
    cmp esi, 480
    jae bass_note_ready
bass_arrangement_on:
    mov ecx, esi
    and ecx, 31
    movzx edx, byte ptr bassPattern[rcx]
    cmp edx, 127
    je bass_note_ready
    movzx ecx, byte ptr bassRoots[r12]
    add ecx, edx
    sub ecx, 36
    mov eax, dword ptr noteIncrements[rcx*4]
    shr eax, 1                          ; A1/F1/C2/G1 sub register
    mov bassIncrement, eax
    add eax, eax
    mov bassModIncrement, eax           ; very low-index 2:1 FM
    mov bassActive, 1
bass_note_ready:

    ; Load the current rootless Am9/G6/9/Fmaj9/Em7(add11) voicing.
    movzx ecx, byte ptr chordVoice1[r12]
    sub ecx, 36
    mov eax, dword ptr noteIncrements[rcx*4]
    mov stabIncrement1, eax
    movzx ecx, byte ptr chordVoice2[r12]
    sub ecx, 36
    mov eax, dword ptr noteIncrements[rcx*4]
    mov stabIncrement2, eax
    movzx ecx, byte ptr chordVoice3[r12]
    sub ecx, 36
    mov eax, dword ptr noteIncrements[rcx*4]
    mov stabIncrement3, eax

    ; Offbeat stabs.  Intro/break/outro use half density; drops use all four.
    mov stabActive, 0
    test esi, 1
    jz stab_note_ready
    cmp esi, 32
    jb stab_note_ready
    cmp esi, 80
    jb stab_half_density
    cmp esi, 240
    jb stab_note_on
    cmp esi, 304
    jb stab_half_density
    cmp esi, 480
    jb stab_note_on
    cmp esi, 496
    jae stab_note_ready
stab_half_density:
    mov eax, esi
    and eax, 3
    cmp eax, 3
    jne stab_note_ready
stab_note_on:
    mov stabActive, 1
    mov stabPhase1, 0
    mov stabPhase2, 0
    mov stabPhase3, 0
stab_note_ready:

    ; Reset the four-to-the-floor kick oscillator on quarter-note edges.
    test esi, 1
    jnz notes_updated
    mov kickPhase, 0
    mov kickIncrement, 16000000
notes_updated:
    jmp synth_sample

store_step_position:
    mov audioStepPos, eax
synth_sample:
    xor r8d, r8d                        ; harmonic mono body
    xor r9d, r9d                        ; harmonic stereo difference

    ; Rounded sine-sub with just enough low-index FM to remain audible on small
    ; speakers.  The attack and decay both reach zero, so rests stay click-free.
    cmp bassActive, 0
    je bass_done
    mov eax, bassModPhase
    add eax, bassModIncrement
    mov bassModPhase, eax
    mov ecx, eax
    shr ecx, 21
    movsx edx, word ptr sineTable[rcx*2]
    sar edx, 10
    mov eax, bassPhase
    add eax, bassIncrement
    mov bassPhase, eax
    mov ecx, eax
    shr ecx, 21
    add ecx, edx
    and ecx, SINE_SIZE-1
    movsx eax, word ptr sineTable[rcx*2]
    mov ebx, audioStepPos
    imul ebx, 96
    cmp ebx, 22000
    jbe bass_attack_ready
    mov ebx, 22000
bass_attack_ready:
    mov edx, audioStepPos
    lea edx, [rdx+rdx*2]
    neg edx
    add edx, 26000
    jns bass_decay_ready
    xor edx, edx
bass_decay_ready:
    cmp ebx, edx
    jbe bass_env_ready
    mov ebx, edx
bass_env_ready:
    imul eax, ebx
    sar eax, 18
    add r8d, eax
bass_done:

    ; Three short sine stabs.  A -24 dB second harmonic supplies a soft analog
    ; edge without the glassy 14:1 operator that previously dominated the mix.
    cmp stabActive, 0
    je stabs_done
    mov ebx, audioStepPos
    imul ebx, 128
    cmp ebx, 24000
    jbe stab_attack_ready
    mov ebx, 24000
stab_attack_ready:
    mov edx, audioStepPos
    lea edx, [rdx+rdx*2]
    neg edx
    add edx, 28000
    jns stab_decay_ready
    xor edx, edx
stab_decay_ready:
    cmp ebx, edx
    jbe stab_env_ready
    mov ebx, edx
stab_env_ready:
    mov eax, stabPhase1
    add eax, stabIncrement1
    mov stabPhase1, eax
    mov ecx, eax
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    mov edx, ecx
    add edx, edx
    and edx, SINE_SIZE-1
    movsx edx, word ptr sineTable[rdx*2]
    sar edx, 4
    add eax, edx
    imul eax, ebx
    sar eax, 19
    add r8d, eax
    mov edx, eax
    sar edx, 1
    add r9d, edx                        ; lower voice leans left

    mov eax, stabPhase2
    add eax, stabIncrement2
    mov stabPhase2, eax
    mov ecx, eax
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    mov edx, ecx
    add edx, edx
    and edx, SINE_SIZE-1
    movsx edx, word ptr sineTable[rdx*2]
    sar edx, 4
    add eax, edx
    imul eax, ebx
    sar eax, 19
    add r8d, eax                        ; middle voice remains centred

    mov eax, stabPhase3
    add eax, stabIncrement3
    mov stabPhase3, eax
    mov ecx, eax
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    mov edx, ecx
    add edx, edx
    and edx, SINE_SIZE-1
    movsx edx, word ptr sineTable[rdx*2]
    sar edx, 4
    add eax, edx
    imul eax, ebx
    sar eax, 19
    add r8d, eax
    mov edx, eax
    sar edx, 1
    sub r9d, edx                        ; upper voice leans right
stabs_done:

    ; Harmonic-only ping-pong delay: drums never enter the feedback loop.  The
    ; 3/16 and 1/4-note taps turn short stabs into space without smearing kick.
    mov r10d, r8d
    add r10d, r9d
    mov r11d, r8d
    sub r11d, r9d
    mov ecx, r15d
    sub ecx, 16538
    and ecx, 65535
    movsx eax, word ptr delayRight[rcx*2]
    sar eax, 3
    add r10d, eax
    mov ecx, r15d
    sub ecx, 22050
    and ecx, 65535
    movsx eax, word ptr delayLeft[rcx*2]
    sar eax, 3
    add r11d, eax

    ; Classic house pump: roughly -21 dB at the kick edge, recovering over
    ; 112 ms.  It affects sub, stabs and their delay, never the drum transients.
    mov ebx, 32767
    mov eax, audioStep
    test eax, 1
    jnz sidechain_ready
    mov ebx, audioStepPos
    imul ebx, 6
    add ebx, 3000
    cmp ebx, 32767
    jbe sidechain_ready
    mov ebx, 32767
sidechain_ready:
    imul r10d, ebx
    sar r10d, 15
    imul r11d, ebx
    sar r11d, 15
    mov eax, r10d
    mov word ptr delayLeft[r15*2], ax
    mov eax, r11d
    mov word ptr delayRight[r15*2], ax

    ; Per-sample xorshift, followed by two one-pole stages.  No percussion path
    ; ever receives raw white noise: clap uses the band, hats use filtered air.
    mov eax, noiseState
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov noiseState, eax
    movsx r13d, ax

    mov edx, noiseFast
    mov eax, r13d
    sub eax, edx
    sar eax, 2
    add edx, eax
    mov noiseFast, edx
    mov ecx, noiseSlow
    mov eax, edx
    sub eax, ecx
    sar eax, 5
    add ecx, eax
    mov noiseSlow, ecx

    ; Very quiet filtered air, lifted through the lake and waterfall acts.
    mov eax, ecx
    sar eax, 5
    mov ebx, audioStep
    cmp ebx, 240
    jb air_level_ready
    cmp ebx, 416
    jae air_level_ready
    add eax, eax
air_level_ready:
    add r10d, eax
    add r11d, eax
    mov edx, eax
    sar edx, 3
    add r10d, edx
    sub r11d, edx

    ; Warm sine kick on every quarter note in groove/drop sections.
    mov eax, audioStep
    cmp eax, 32
    jb kick_done
    cmp eax, 240
    jb kick_arranged
    cmp eax, 336
    jb kick_done
    cmp eax, 480
    jae kick_done
kick_arranged:
    test eax, 1
    jnz kick_done
    mov ecx, audioStepPos
    cmp ecx, 10000
    jae kick_done
    mov eax, kickIncrement
    cmp eax, 5000000
    jbe kick_pitch_ready
    sub eax, 12000
    mov kickIncrement, eax
kick_pitch_ready:
    mov edx, kickPhase
    add edx, eax
    mov kickPhase, edx
    mov ecx, edx
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    mov ebx, audioStepPos
    lea ebx, [rbx+rbx*2]
    neg ebx
    add ebx, 30000
    imul eax, ebx
    sar eax, 17
    add r10d, eax
    add r11d, eax
kick_done:

    ; Filtered, three-burst clap on beats two and four.  Closely-spaced bursts
    ; give the hand-clap flam; the shared low tail replaces harsh white noise.
    mov eax, audioStep
    cmp eax, 48
    jb clap_done
    cmp eax, 240
    jb clap_arranged
    cmp eax, 336
    jb clap_done
    cmp eax, 480
    jae clap_done
clap_arranged:
    and eax, 3
    cmp eax, 2
    jne clap_done
    mov ecx, audioStepPos
    cmp ecx, 5500
    jae clap_done
    mov ebx, 5500
    sub ebx, ecx
    add ebx, ebx                       ; broad filtered tail
    cmp ecx, 300
    jae clap_burst_two
    mov eax, ecx
    imul eax, 48
    neg eax
    add eax, 15000
    add ebx, eax
clap_burst_two:
    cmp ecx, 450
    jb clap_burst_three
    cmp ecx, 780
    jae clap_burst_three
    mov eax, ecx
    sub eax, 450
    imul eax, 42
    neg eax
    add eax, 14000
    add ebx, eax
clap_burst_three:
    cmp ecx, 950
    jb clap_render
    cmp ecx, 1400
    jae clap_render
    mov eax, ecx
    sub eax, 950
    imul eax, 26
    neg eax
    add eax, 12000
    add ebx, eax
clap_render:
    mov eax, noiseFast
    sub eax, noiseSlow
    imul eax, ebx
    sar eax, 16
    add r10d, eax
    add r11d, eax
    mov edx, eax
    sar edx, 3
    add r10d, edx
    sub r11d, edx
clap_done:

    ; Soft offbeat open hat.  A high-passed component is blended with the
    ; band-pass state, keeping the articulation while avoiding brittle white hiss.
    mov eax, audioStep
    cmp eax, 16
    jb hat_done
    cmp eax, 240
    jb hat_arranged
    cmp eax, 304
    jb hat_done
    cmp eax, 496
    jae hat_done
hat_arranged:
    test eax, 1
    jz hat_done
    mov ecx, audioStepPos
    cmp ecx, 5000
    jae hat_done
    mov ebx, ecx
    imul ebx, 96
    cmp ebx, 8000
    jbe hat_attack_ready
    mov ebx, 8000
hat_attack_ready:
    mov edx, ecx
    add edx, edx
    neg edx
    add edx, 10000
    cmp ebx, edx
    jbe hat_env_ready
    mov ebx, edx
hat_env_ready:
    mov eax, r13d
    sub eax, noiseFast
    sar eax, 2
    mov edx, noiseFast
    sub edx, noiseSlow
    sar edx, 1
    add eax, edx
    imul eax, ebx
    sar eax, 17
    add r10d, eax
    add r11d, eax
    mov edx, eax
    sar edx, 2
    mov ecx, audioStep
    test ecx, 2
    jnz hat_pan_right
    add r10d, edx
    sub r11d, edx
    jmp hat_done
hat_pan_right:
    sub r10d, edx
    add r11d, edx
hat_done:

    ; A short shaker 6200 samples into every eighth supplies a restrained 56%
    ; sixteenth swing.  It uses only the smooth band-pass noise state.
    mov eax, audioStep
    cmp eax, 16
    jb shaker_done
    cmp eax, 80                         ; two-bar dawn riser
    jb shaker_arranged
    cmp eax, 160                        ; village stays uncluttered
    jb shaker_done
    cmp eax, 240                        ; flight brings the full swung layer
    jb shaker_arranged
    cmp eax, 304
    jb shaker_done
    cmp eax, 496
    jae shaker_done
shaker_arranged:
    mov ecx, audioStepPos
    cmp ecx, 6200
    jb shaker_done
    cmp ecx, 7400
    jae shaker_done
    mov ebx, ecx
    sub ebx, 6200
    imul ebx, 32
    mov edx, 7400
    sub edx, ecx
    imul edx, 16
    cmp ebx, edx
    jbe shaker_env_ready
    mov ebx, edx
shaker_env_ready:
    mov eax, noiseFast
    sub eax, noiseSlow
    imul eax, ebx
    sar eax, 18
    add r10d, eax
    add r11d, eax
    mov edx, eax
    sar edx, 2
    mov ecx, audioStep
    test ecx, 1
    jnz shaker_pan_right
    add r10d, edx
    sub r11d, edx
    jmp shaker_done
shaker_pan_right:
    sub r10d, edx
    add r11d, edx
shaker_done:

    ; Short boundary fades make the pre-rendered 128-second PCM loop exact.
    mov eax, AUDIO_FRAMES
    sub eax, r14d
    cmp eax, 4096
    jae fade_out_check
    imul r10d, eax
    sar r10d, 12
    imul r11d, eax
    sar r11d, 12
fade_out_check:
    cmp r14d, 4096
    jae mix_ready
    imul r10d, r14d
    sar r10d, 12
    imul r11d, r14d
    sar r11d, 12
mix_ready:

    ; Transparent +4.86 dB output trim.  Measured true peaks remain below
    ; -2 dBFS; the limiter comparisons below are still only a safety net.
    imul r10d, 7
    sar r10d, 2
    imul r11d, 7
    sar r11d, 2

    ; No saturation or loudness drive.  These comparisons are only an overflow
    ; guard; QA keeps the procedural master comfortably below full scale.
    mov eax, r10d
    cmp eax, 32767
    jle clip_left_low
    mov eax, 32767
clip_left_low:
    cmp eax, -32768
    jge clip_left_done
    mov eax, -32768
clip_left_done:
    mov word ptr [rdi], ax

    mov eax, r11d
    cmp eax, 32767
    jle clip_right_low
    mov eax, 32767
clip_right_low:
    cmp eax, -32768
    jge clip_right_done
    mov eax, -32768
clip_right_done:
    mov word ptr [rdi+2], ax

    add rdi, 4
    inc r15d
    and r15d, 65535
    dec r14d
    jnz audio_frame_loop

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
GenerateAudio ENDP

; -----------------------------------------------------------------------------
; Process entry point: no CRT, no C/C++ helper layer.
; -----------------------------------------------------------------------------
start PROC
    sub rsp, 28h

    ; Respect an explicit hidden launch. This permits unattended validation
    ; of the delivered EXE without briefly opening a visible native window.
    mov dword ptr startupInfo[0], 104
    lea rcx, startupInfo
    call GetStartupInfoA
    test dword ptr startupInfo[60], 1   ; STARTF_USESHOWWINDOW
    jz startup_visibility_ready
    cmp word ptr startupInfo[64], 0    ; SW_HIDE
    jne startup_visibility_ready
    mov startupHidden, 1
startup_visibility_ready:

    xor ecx, ecx
    call GetModuleHandleA
    mov hInstance, rax
    mov qword ptr wndClass[24], rax

    xor ecx, ecx
    mov edx, IDC_ARROW
    call LoadCursorA
    mov qword ptr wndClass[40], rax

    lea rcx, wndClass
    call RegisterClassExA
    test eax, eax
    jz init_failed

    ; Centre a borderless 1280x720 canvas; scale down on smaller displays.
    xor ecx, ecx
    call GetSystemMetrics
    mov edx, CW_RENDER_WIDTH
    cmp eax, edx
    cmovb edx, eax
    mov windowW, edx
    sub eax, edx
    sar eax, 1
    mov windowX, eax

    mov ecx, 1
    call GetSystemMetrics
    mov edx, CW_RENDER_HEIGHT
    cmp eax, edx
    cmovb edx, eax
    mov windowH, edx
    sub eax, edx
    sar eax, 1
    mov windowY, eax

    xor ecx, ecx
    lea rdx, className
    lea r8, windowTitle
    mov r9d, WS_POPUP or WS_VISIBLE
    cmp startupHidden, 0
    je create_window_style_ready
    mov r9d, WS_POPUP
create_window_style_ready:
    sub rsp, 40h
    mov eax, windowX
    mov dword ptr [rsp+20h], eax
    mov eax, windowY
    mov dword ptr [rsp+28h], eax
    mov eax, windowW
    mov dword ptr [rsp+30h], eax
    mov eax, windowH
    mov dword ptr [rsp+38h], eax
    mov qword ptr [rsp+40h], 0
    mov qword ptr [rsp+48h], 0
    mov rax, hInstance
    mov qword ptr [rsp+50h], rax
    mov qword ptr [rsp+58h], 0
    call CreateWindowExA
    add rsp, 40h
    test rax, rax
    jz init_failed
    mov hWindow, rax
    mov qword ptr swapDesc[48], rax

    cmp startupHidden, 0
    jne window_visibility_ready
    mov rcx, rax
    mov edx, SW_SHOW
    call ShowWindow
    mov rcx, hWindow
    call UpdateWindow
window_visibility_ready:

    ; Create D3D11 hardware device; WARP is an automatic software fallback.
    xor ecx, ecx
    mov edx, D3D_DRIVER_TYPE_HARDWARE
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 40h
    lea rax, requiredFeatureLevel
    mov qword ptr [rsp+20h], rax
    mov qword ptr [rsp+28h], 1
    mov dword ptr [rsp+30h], D3D11_SDK_VERSION
    lea rax, swapDesc
    mov qword ptr [rsp+38h], rax
    lea rax, swapChain
    mov qword ptr [rsp+40h], rax
    lea rax, d3dDevice
    mov qword ptr [rsp+48h], rax
    lea rax, featureLevel
    mov qword ptr [rsp+50h], rax
    lea rax, d3dContext
    mov qword ptr [rsp+58h], rax
    call D3D11CreateDeviceAndSwapChain
    add rsp, 40h
    test eax, eax
    jns d3d_created

    xor ecx, ecx
    mov edx, D3D_DRIVER_TYPE_WARP
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 40h
    lea rax, requiredFeatureLevel
    mov qword ptr [rsp+20h], rax
    mov qword ptr [rsp+28h], 1
    mov dword ptr [rsp+30h], D3D11_SDK_VERSION
    lea rax, swapDesc
    mov qword ptr [rsp+38h], rax
    lea rax, swapChain
    mov qword ptr [rsp+40h], rax
    lea rax, d3dDevice
    mov qword ptr [rsp+48h], rax
    lea rax, featureLevel
    mov qword ptr [rsp+50h], rax
    lea rax, d3dContext
    mov qword ptr [rsp+58h], rax
    call D3D11CreateDeviceAndSwapChain
    add rsp, 40h
    test eax, eax
    js init_failed

d3d_created:
    ; Locate the fullscreen DXBC programs in the executable resources.
    mov rcx, hInstance
    mov edx, 101
    mov r8d, 10                         ; RT_RCDATA
    call FindResourceA
    test rax, rax
    jz init_failed
    mov resourceVS, rax
    mov rcx, hInstance
    mov rdx, rax
    call SizeofResource
    test eax, eax
    jz init_failed
    mov shaderVSSize, eax
    mov rcx, hInstance
    mov rdx, resourceVS
    call LoadResource
    test rax, rax
    jz init_failed
    mov rcx, rax
    call LockResource
    test rax, rax
    jz init_failed
    mov shaderVSPtr, rax

    mov rcx, hInstance
    mov edx, 102
    mov r8d, 10
    call FindResourceA
    test rax, rax
    jz init_failed
    mov resourcePS, rax
    mov rcx, hInstance
    mov rdx, rax
    call SizeofResource
    test eax, eax
    jz init_failed
    mov shaderPSSize, eax
    mov rcx, hInstance
    mov rdx, resourcePS
    call LoadResource
    test rax, rax
    jz init_failed
    mov rcx, rax
    call LockResource
    test rax, rax
    jz init_failed
    mov shaderPSPtr, rax

    ; ID3D11Device::CreateVertexShader
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rax, [rax+96]
    mov rdx, shaderVSPtr
    mov r8d, shaderVSSize
    xor r9d, r9d
    lea r10, vertexShader
    mov qword ptr [rsp+20h], r10
    call rax
    test eax, eax
    js init_failed

    ; ID3D11Device::CreatePixelShader
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rax, [rax+120]
    mov rdx, shaderPSPtr
    mov r8d, shaderPSSize
    xor r9d, r9d
    lea r10, pixelShader
    mov qword ptr [rsp+20h], r10
    call rax
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit

    mov ecx, 103
    lea rdx, humanShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit

    mov ecx, 104
    lea rdx, temporalShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed

    mov ecx, 105
    lea rdx, displayShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed

    mov ecx, 106
    lea rdx, meshVertexShader
    call LoadEmbeddedVertexShader
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit
    mov ecx, 107
    lea rdx, meshPixelShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed
    mov ecx, 108
    lea rdx, shadowVertexShader
    call LoadEmbeddedVertexShader
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit
    mov ecx, 109
    lea rdx, shadowPixelShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed
    mov ecx, 110
    lea rdx, cameraComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed
    mov ecx, 111
    lea rdx, terrainComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit
    mov ecx, 112
    lea rdx, flightComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit
    mov ecx, 113
    lea rdx, waterComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed

    mov ecx, 114
    lea rdx, materialComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit
    mov ecx, 115
    lea rdx, atmosphereComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed

    mov ecx, 116
    lea rdx, instanceComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed

    mov ecx, 117
    lea rdx, cloudComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed
    mov ecx, 118
    lea rdx, boundsComputeShader
    call LoadEmbeddedComputeShader
    test eax, eax
    js init_failed
    mov ecx, 119
    lea rdx, cloudCompositeShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed

    ; IDXGISwapChain::GetBuffer(0, IID_ID3D11Texture2D, ...)
    mov rcx, swapChain
    mov rax, [rcx]
    mov rax, [rax+72]
    xor edx, edx
    lea r8, IID_ID3D11Texture2D
    lea r9, backBuffer
    call rax
    test eax, eax
    js init_failed

    ; ID3D11Device::CreateRenderTargetView
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rax, [rax+72]
    mov rdx, backBuffer
    xor r8d, r8d
    lea r9, renderTarget
    call rax
    test eax, eax
    js init_failed
    mov rcx, backBuffer
    call ReleaseObject
    mov backBuffer, 0

    ; Native HDR scene plus two full-resolution temporal histories.
    lea rcx, lowSurfaceDesc
    lea rdx, lowTexture
    lea r8, lowSRV
    lea r9, lowRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed

    lea rcx, lowSurfaceDesc
    lea rdx, lowBTexture
    lea r8, lowBSRV
    lea r9, lowBRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed
    lea rcx, lowSurfaceDesc
    lea rdx, cloudedTexture
    lea r8, cloudedSRV
    lea r9, cloudedRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed
    lea rcx, reflectionSurfaceDesc
    lea rdx, reflectionCloudTexture
    lea r8, reflectionCloudSRV
    lea r9, reflectionCloudRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed

    lea rcx, historySurfaceDesc
    lea rdx, historyTexture0
    lea r8, historySRV0
    lea r9, historyRTV0
    call CreateRenderSurface
    test eax, eax
    js init_failed

    lea rcx, historySurfaceDesc
    lea rdx, historyTexture1
    lea r8, historySRV1
    lea r9, historyRTV1
    call CreateRenderSurface
    test eax, eax
    js init_failed

    lea rcx, shadowSurfaceDesc
    lea rdx, shadowTexture
    lea r8, shadowSRV
    lea r9, shadowRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, terrainSurfaceDesc
    xor r8d, r8d
    lea r9, terrainTexture
    call qword ptr [rax+40]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, terrainTexture
    xor r8d, r8d
    lea r9, terrainSRV
    call qword ptr [rax+56]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, terrainTexture
    xor r8d, r8d
    lea r9, terrainUAV
    call qword ptr [rax+64]
    test eax, eax
    js init_failed
    lea rcx, mainDepthDesc
    lea rdx, mainDepthTexture
    lea r8, mainDepthView
    call CreateDepthSurface
    test eax, eax
    js init_failed
    lea rcx, materialSurfaceDesc
    lea rdx, materialTextures
    lea r8, materialSRVs
    lea r9, materialUAVs
    call CreateComputeSurface
    test eax, eax
    js init_failed
    lea rcx, materialSurfaceDesc
    lea rdx, materialTextures[8]
    lea r8, materialSRVs[8]
    lea r9, materialUAVs[8]
    call CreateComputeSurface
    test eax, eax
    js init_failed
    lea rcx, atmosphereSurfaceDesc
    lea rdx, atmosphereTexture
    lea r8, atmosphereSRV
    lea r9, atmosphereUAV
    call CreateComputeSurface
    test eax, eax
    js init_failed
    call CreateGeneratedVolumes
    test eax, eax
    js init_failed
    lea rcx, farShadowSurfaceDesc
    lea rdx, farShadowTexture
    lea r8, farShadowSRV
    lea r9, farShadowRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed
    lea rcx, farShadowDepthDesc
    lea rdx, farShadowDepthTexture
    lea r8, farShadowDepthView
    call CreateDepthSurface
    test eax, eax
    js init_failed
    lea rcx, reflectionSurfaceDesc
    lea rdx, reflectionTexture
    lea r8, reflectionSRV
    lea r9, reflectionRTV
    call CreateRenderSurface
    test eax, eax
    js init_failed
    lea rcx, reflectionDepthDesc
    lea rdx, reflectionDepthTexture
    lea r8, reflectionDepthView
    call CreateDepthSurface
    test eax, eax
    js init_failed
    lea rcx, shadowDepthDesc
    lea rdx, shadowDepthTexture
    lea r8, shadowDepthView
    call CreateDepthSurface
    test eax, eax
    js init_failed

    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, cameraBufferDesc
    xor r8d, r8d
    lea r9, cameraFrameBuffer
    call qword ptr [rax+24]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, flightBufferDesc
    xor r8d, r8d
    lea r9, flightBuffer
    call qword ptr [rax+24]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, instanceBufferDesc
    xor r8d, r8d
    lea r9, instanceBuffer
    call qword ptr [rax+24]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, instanceBuffer
    lea r8, instanceSRVDesc
    lea r9, instanceSRV
    call qword ptr [rax+56]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, instanceBuffer
    lea r8, instanceUAVDesc
    lea r9, instanceUAV
    call qword ptr [rax+64]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, flightBuffer
    lea r8, flightSRVDesc
    lea r9, flightSRV
    call qword ptr [rax+56]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, flightBuffer
    lea r8, flightUAVDesc
    lea r9, flightUAV
    call qword ptr [rax+64]
    test eax, eax
    js init_failed
    lea rcx, waterSurfaceDesc
    lea rdx, waterTextures
    lea r8, waterSRVs
    lea r9, waterUAVs
    call CreateComputeSurface
    test eax, eax
    js init_failed
    lea rcx, waterSurfaceDesc
    lea rdx, waterTextures[8]
    lea r8, waterSRVs[8]
    lea r9, waterUAVs[8]
    call CreateComputeSurface
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, batchBufferDesc
    xor r8d, r8d
    lea r9, physicsConstantBuffer
    call qword ptr [rax+24]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, batchBufferDesc
    xor r8d, r8d
    lea r9, batchConstantBuffer
    call qword ptr [rax+24]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, batchBufferDesc
    xor r8d, r8d
    lea r9, passConstantBuffer
    call qword ptr [rax+24]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, cameraFrameBuffer
    lea r8, cameraSRVDesc
    lea r9, cameraFrameSRV
    call qword ptr [rax+56]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rdx, cameraFrameBuffer
    lea r8, cameraUAVDesc
    lea r9, cameraFrameUAV
    call qword ptr [rax+64]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, meshRasterizerDesc
    lea r8, meshRasterizer
    call qword ptr [rax+176]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, worldDepthStateDesc
    lea r8, worldDepthState
    call qword ptr [rax+168]
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, postDepthStateDesc
    lea r8, postDepthState
    call qword ptr [rax+168]
    test eax, eax
    js init_failed

    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, postSamplerDesc
    lea r8, postSampler
    call qword ptr [rax+184]             ; CreateSamplerState
    test eax, eax
    js init_failed
    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, materialSamplerDesc
    lea r8, materialSampler
    call qword ptr [rax+184]
    test eax, eax
    js init_failed

    ; A zero alpha marks both histories invalid on the first temporal frame.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+400]                   ; ClearRenderTargetView
    mov rdx, historyRTV0
    lea r8, clearHistoryColour
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+400]
    mov rdx, historyRTV1
    lea r8, clearHistoryColour
    call rax

    ; ID3D11Device::CreateBuffer for Frame constants.
    mov rcx, d3dDevice
    mov rax, [rcx]
    mov rax, [rax+24]
    lea rdx, constantBufferDesc
    xor r8d, r8d
    lea r9, constantBuffer
    call rax
    test eax, eax
    js init_failed

    ; Bind the immutable part of the tiny fullscreen-triangle pipeline.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+192]                  ; IASetPrimitiveTopology
    mov edx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST
    call rax

    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, meshRasterizer
    call qword ptr [rax+344]            ; RSSetState, procedural triangles two-sided

    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+88]                   ; VSSetShader
    mov rdx, vertexShader
    xor r8d, r8d
    xor r9d, r9d
    call rax

    ; Camera/path/terrain evaluation is frame-uniform. The fullscreen vertex
    ; shader computes current/previous camera frames once for each of 3 vertices
    ; and forwards them without interpolation to all four pixel passes.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+56]                   ; VSSetConstantBuffers(b0)
    xor edx, edx
    mov r8d, 1
    lea r9, constantBuffer
    call rax

    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8d, 1
    lea r9, batchConstantBuffer
    call qword ptr [rax+56]             ; VS b1, explicit procedural batch base
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 2
    mov r8d, 1
    lea r9, passConstantBuffer
    call qword ptr [rax+56]             ; VS b2, reflection mode/availability
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 2
    mov r8d, 1
    lea r9, passConstantBuffer
    call qword ptr [rax+128]            ; PS b2

    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+128]                  ; PSSetConstantBuffers
    xor edx, edx
    mov r8d, 1
    lea r9, constantBuffer
    call rax

    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, constantBuffer
    call qword ptr [rax+568]            ; CSSetConstantBuffers(b0)

    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+80]                   ; PSSetSamplers(s0)
    xor edx, edx
    mov r8d, 1
    lea r9, postSampler
    call rax

    ; Generate the immutable terrain height cache on the GPU. No pixels or
    ; external files are embedded: resource 111 contains only generator code.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, terrainComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]            ; CSSetShader
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, terrainUAV
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]            ; CSSetUnorderedAccessViews
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 512
    mov r8d, 512
    mov r9d, 1
    call qword ptr [rax+328]            ; Dispatch(512,512,1),4096 terrain
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 4
    mov r8d, 1
    lea r9, terrainSRV
    call qword ptr [rax+200]            ; VS t4
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 4
    mov r8d, 1
    lea r9, terrainSRV
    call qword ptr [rax+64]             ; PS t4
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 4
    mov r8d, 1
    lea r9, terrainSRV
    call qword ptr [rax+536]            ; CS t4
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8d, 1
    lea r9, postSampler
    call qword ptr [rax+208]            ; VS sampler s1
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8d, 1
    lea r9, postSampler
    call qword ptr [rax+80]             ; PS sampler s1
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8d, 1
    lea r9, postSampler
    call qword ptr [rax+560]            ; CS sampler s1

    call GenerateTerrainBounds
    test eax, eax
    jnz clean_exit
    call GenerateCloudVolume
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit

    ; Eight physical material recipes produce color/height and normal/roughness
    ; arrays. Autogenerated mip chains keep distant detail properly filtered.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, materialComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 2
    lea r9, materialUAVs
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 128
    mov r8d, 128
    mov r9d, 8
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 2
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, materialSRVs[0]
    call qword ptr [rax+432]            ; GenerateMips
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, materialSRVs[8]
    call qword ptr [rax+432]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 8
    mov r8d, 2
    lea r9, materialSRVs
    call qword ptr [rax+64]             ; PS material t8/t9
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 8
    mov r8d, 2
    lea r9, materialSRVs
    call qword ptr [rax+200]            ; VS material t8/t9
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 2
    mov r8d, 1
    lea r9, materialSampler
    call qword ptr [rax+80]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 2
    mov r8d, 1
    lea r9, materialSampler
    call qword ptr [rax+208]
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit

    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, physicsConstantBuffer
    call qword ptr [rax+568]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, physicsConstantBuffer
    call qword ptr [rax+56]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, physicsConstantBuffer
    call qword ptr [rax+128]
    call UpdatePhysicsConstants
    ; Solve four independent flight trajectories on the GPU at startup. Only
    ; solver code is embedded; positions/velocities are produced at runtime.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, flightComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, flightUAV
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8d, 1
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 6
    mov r8d, 1
    lea r9, flightSRV
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 6
    mov r8d, 1
    lea r9, flightSRV
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 6
    mov r8d, 1
    lea r9, flightSRV
    call qword ptr [rax+536]
    call ResetWaterSimulation
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit

    ; Session entropy controls the restrained musical mutations and shader seed.
    lea rcx, qpcFrequency
    call QueryPerformanceFrequency
    test eax, eax
    jz init_failed
    cmp qpcFrequency, 0
    jle init_failed
    lea rcx, qpcNow
    call QueryPerformanceCounter
    mov eax, dword ptr qpcNow
    xor eax, 0A5319E37h
    test eax, eax
    jnz seed_nonzero
    mov eax, 1
seed_nonzero:
    mov noiseState, eax
    and eax, 0FFFFh
    cvtsi2ss xmm0, eax
    mulss xmm0, inv65535
    movss runSeed, xmm0

    ; Allocate and synthesize the complete 128-second score in working memory.
    xor ecx, ecx
    mov edx, AUDIO_BYTES
    mov r8d, MEM_COMMIT or MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jz audio_skipped
    mov audioBuffer, rax
    call GenerateSineTable
    call GenerateAudio
    call PumpInitializationMessages
    test eax, eax
    jnz clean_exit

    ; A hidden diagnostic launch still synthesizes the score but uses QPC
    ; instead of playing it through the user's speakers.
    cmp startupHidden, 0
    jne audio_skipped

IFDEF QA_SILENT_AUDIO
    ; Test builds can expose the finished PCM buffer for analysis without
    ; sending it to the user's audio device.
    mov audioEnabled, 0
    jmp timer_start
ENDIF

    ; WAVEHDR offsets: data 0, length 8, flags 24, loops 28.
    mov rax, audioBuffer
    mov qword ptr waveHeader[0], rax
    mov dword ptr waveHeader[8], AUDIO_BYTES
    mov dword ptr waveHeader[24], WHDR_BEGINLOOP or WHDR_ENDLOOP
    mov dword ptr waveHeader[28], 0FFFFFFFFh

    lea rcx, audioHandle
    mov edx, WAVE_MAPPER
    lea r8, waveFormat
    xor r9d, r9d
    sub rsp, 10h
    mov qword ptr [rsp+20h], 0
    mov qword ptr [rsp+28h], 0
    call waveOutOpen
    add rsp, 10h
    test eax, eax
    jnz audio_skipped
    mov rcx, audioHandle
    lea rdx, waveHeader
    mov r8d, 48
    call waveOutPrepareHeader
    test eax, eax
    jnz audio_close_only
    mov rcx, audioHandle
    lea rdx, waveHeader
    mov r8d, 48
    call waveOutWrite
    test eax, eax
    jnz audio_unprepare
    mov audioEnabled, 1
    jmp timer_start

audio_unprepare:
    mov rcx, audioHandle
    lea rdx, waveHeader
    mov r8d, 48
    call waveOutUnprepareHeader
audio_close_only:
    mov rcx, audioHandle
    call waveOutClose
    mov audioHandle, 0
audio_skipped:
    mov audioEnabled, 0

timer_start:
    lea rcx, qpcStart
    call QueryPerformanceCounter
    mov frameCounter, 0
    mov historyIndex, 0
    mov previousTime, 0

main_message_loop:
    lea rcx, messageData
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp+20h], PM_REMOVE
    call PeekMessageA
    test eax, eax
    jz render_frame
    cmp dword ptr messageData[8], WM_QUIT
    je clean_exit
    lea rcx, messageData
    call TranslateMessage
    lea rcx, messageData
    call DispatchMessageA
    jmp main_message_loop

render_frame:
    ; Prefer the hardware audio cursor, keeping cuts and camera exactly together.
    cmp audioEnabled, 0
    je time_from_qpc
    mov dword ptr mmTime[0], TIME_SAMPLES
    mov rcx, audioHandle
    lea rdx, mmTime
    mov r8d, 12                         ; sizeof(MMTIME), not pointer-aligned
    call waveOutGetPosition
    test eax, eax
    jnz time_from_qpc
    cmp dword ptr mmTime[0], TIME_SAMPLES
    jne time_from_qpc
    mov eax, dword ptr mmTime[4]
    xor edx, edx
    mov ecx, AUDIO_FRAMES
    div ecx
    mov eax, edx                       ; preserve sub-frame precision each loop
    cvtsi2ss xmm0, rax
    divss xmm0, audioRateF
    addss xmm0, qaTimeOffset
    movss currentTime, xmm0
    jmp update_constants

time_from_qpc:
    lea rcx, qpcNow
    call QueryPerformanceCounter
    mov rax, qpcNow
    sub rax, qpcStart
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, qpcFrequency
    divsd xmm0, xmm1
    cvtsd2ss xmm0, xmm0
    addss xmm0, qaTimeOffset
    movss currentTime, xmm0

update_constants:
    mov ecx, 44A00000h
    mov edx, 44340000h
    call UpdateFrameConstants
    test eax, eax
    js clean_exit
    ; Range gating uses loop phase, including the audio and QPC fallback paths.
    mov reflectionEnabled, 0
    movss xmm0, currentTime
    movaps xmm1, xmm0
    divss xmm1, loopSeconds
    cvttss2si eax, xmm1
    cvtsi2ss xmm1, eax
    mulss xmm1, loopSeconds
    subss xmm0, xmm1
    ucomiss xmm0, reflectionBegin
    jb reflection_unavailable
    ucomiss xmm0, reflectionEnd
    ja reflection_unavailable
    mov reflectionEnabled, 1
    lea rcx, passMainAvailable
    jmp pass_mode_ready
reflection_unavailable:
    lea rcx, passMainUnavailable
pass_mode_ready:
    call UpdatePassConstants
    call AdvanceWaterSimulation
    test eax, eax
    jnz clean_exit

    ; Any SRV left by the preceding display pass must be detached before one of
    ; the ping-pong resources can become an RTV again.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]                   ; PSSetShaderResources
    xor edx, edx
    mov r8d, 4
    lea r9, nullShaderResources
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 5
    mov r8d, 1
    lea r9, terrainSRV                 ; safe fallback while reflection is RTV
    call qword ptr [rax+64]

    ; Cache camera/light transforms once per frame, never per mesh vertex.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, nullShaderResources
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, cameraComputeShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+552]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, cameraFrameUAV
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    mov r8d, 1
    mov r9d, 1
    call qword ptr [rax+328]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    mov r8d, 1
    lea r9, nullShaderResources
    mov qword ptr [rsp+20h], 0
    call qword ptr [rax+544]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, cameraFrameSRV
    call qword ptr [rax+200]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    mov r8d, 1
    lea r9, cameraFrameSRV
    call qword ptr [rax+64]

    call UpdateSceneInstances
    call UpdateAtmosphere
    call RenderFarShadow

    ; Rasterize moving scene geometry into the near shadow/depth map.
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    xor r8d, r8d
    call qword ptr [rax+288]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, shadowRTV
    mov r9, shadowDepthView
    call qword ptr [rax+264]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, shadowRTV
    lea r8, clearShadowColour
    call qword ptr [rax+400]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, shadowDepthView
    mov r8d, 1
    movss xmm3, clearShadowColour
    mov dword ptr [rsp+20h], 0
    call qword ptr [rax+424]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, shadowViewport
    call qword ptr [rax+352]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, shadowVertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, shadowPixelShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+72]
    mov ecx, 7
    call DrawSceneBatches

    cmp reflectionEnabled, 0
    je reflection_complete
    lea rcx, passReflection
    call UpdatePassConstants
    mov ecx, 44200000h                 ; 640x360 ray footprint and jitter
    mov edx, 43B40000h
    call UpdateFrameConstants
    test eax, eax
    js clean_exit
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, reflectionRTV
    mov r9, reflectionDepthView
    call qword ptr [rax+264]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, reflectionDepthView
    mov r8d, 1
    movss xmm3, clearShadowColour
    mov dword ptr [rsp+20h], 0
    call qword ptr [rax+424]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, worldDepthState
    xor r8d, r8d
    call qword ptr [rax+288]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 2
    mov r8d, 1
    lea r9, shadowSRV
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 1
    lea r8, reflectionViewport
    call qword ptr [rax+352]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, vertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, pixelShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+72]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 3
    xor r8d, r8d
    call qword ptr [rax+104]
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    xor r8d, r8d
    call qword ptr [rax+288]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, meshVertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, meshPixelShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+72]
    mov ecx, 6
    call DrawSceneBatches
    mov rcx, reflectionSRV
    mov rdx, reflectionCloudRTV
    lea r8, reflectionViewport
    call CompositeClouds
    lea rcx, passMainAvailable
    call UpdatePassConstants
    mov ecx, 44A00000h
    mov edx, 44340000h
    call UpdateFrameConstants
    test eax, eax
    js clean_exit
reflection_complete:

    ; World: heightfield, water and sky write perspective depth into D32.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+264]                  ; OMSetRenderTargets
    mov edx, 1
    lea r8, lowRTV
    mov r9, mainDepthView
    call rax
    cmp reflectionEnabled, 0
    je main_reflection_bound
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 5
    mov r8d, 1
    lea r9, reflectionCloudSRV
    call qword ptr [rax+64]             ; reflection RTV has been detached
main_reflection_bound:
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, mainDepthView
    mov r8d, 1
    movss xmm3, clearShadowColour
    mov dword ptr [rsp+20h], 0
    call qword ptr [rax+424]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, worldDepthState
    xor r8d, r8d
    call qword ptr [rax+288]            ; sky at depth1 needs LESS_EQUAL
    mov rcx, d3dContext
    mov rax, [rcx]
    mov edx, 2
    mov r8d, 1
    lea r9, shadowSRV
    call qword ptr [rax+64]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, vertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+352]                  ; RSSetViewports
    mov edx, 1
    lea r8, lowViewport
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+72]                   ; PSSetShader(scene P)
    mov rdx, pixelShader
    xor r8d, r8d
    xor r9d, r9d
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+104]                  ; Draw(3,0)
    mov edx, 3
    xor r8d, r8d
    call rax

    ; Real instanced triangles share the world depth buffer and HDR target.
    mov rcx, d3dContext
    mov rax, [rcx]
    xor edx, edx
    xor r8d, r8d
    call qword ptr [rax+288]            ; default LESS, depth writes enabled
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, meshVertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, meshPixelShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+72]
    mov ecx, 6
    call DrawSceneBatches
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rdx, vertexShader
    xor r8d, r8d
    xor r9d, r9d
    call qword ptr [rax+88]

    ; Composite procedural humans over LowA into LowB. Keeping the
    ; character marcher out of the world shader prevents FXC from exploding its
    ; nested ray loops and gives reactive character depth a dedicated pass.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]
    xor edx, edx
    mov r8d, 2
    lea r9, nullShaderResources
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+264]
    mov edx, 1
    lea r8, lowBRTV
    xor r9d, r9d
    call rax
    mov rax, lowSRV
    mov displayBinding, rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]
    xor edx, edx
    mov r8d, 1
    lea r9, displayBinding
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+72]
    mov rdx, humanShader
    xor r8d, r8d
    xor r9d, r9d
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+104]
    mov edx, 3
    xor r8d, r8d
    call rax

    mov rcx, lowBSRV
    mov rdx, cloudedRTV
    lea r8, lowViewport
    call CompositeClouds

    ; Select Hprev/Hnext without copying. historyIndex names the valid previous
    ; surface; the opposite surface becomes this frame's temporal RTV.
    cmp historyIndex, 0
    jne temporal_previous_one
    mov rax, cloudedSRV
    mov temporalBindings[0], rax
    mov rax, historySRV0
    mov temporalBindings[8], rax
    mov rax, historyRTV1
    mov nextRTVBinding, rax
    mov rax, historySRV1
    mov displayBinding, rax
    jmp temporal_targets_ready
temporal_previous_one:
    mov rax, cloudedSRV
    mov temporalBindings[0], rax
    mov rax, historySRV1
    mov temporalBindings[8], rax
    mov rax, historyRTV0
    mov nextRTVBinding, rax
    mov rax, historySRV0
    mov displayBinding, rax

temporal_targets_ready:
    ; Explicitly detach S/Hprev before the output role changes on later frames.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]
    xor edx, edx
    mov r8d, 2
    lea r9, nullShaderResources
    call rax

    ; Pass 3: jitter-aware edge/depth reconstruction into full-resolution Hnext.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+264]
    mov edx, 1
    lea r8, nextRTVBinding
    xor r9d, r9d
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+352]
    mov edx, 1
    lea r8, outputViewport
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]
    xor edx, edx
    mov r8d, 2
    lea r9, temporalBindings
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+72]
    mov rdx, temporalShader
    xor r8d, r8d
    xor r9d, r9d
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+104]
    mov edx, 3
    xor r8d, r8d
    call rax

    ; Pass 4: detach temporal inputs, switch Hnext from RTV to SRV, and write the
    ; ACES-like display transform into the swap-chain backbuffer.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]
    xor edx, edx
    mov r8d, 2
    lea r9, nullShaderResources
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+264]
    mov edx, 1
    lea r8, renderTarget
    xor r9d, r9d
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]
    xor edx, edx
    mov r8d, 1
    lea r9, displayBinding
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+72]
    mov rdx, displayShader
    xor r8d, r8d
    xor r9d, r9d
    call rax
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+104]
    mov edx, 3
    xor r8d, r8d
    call rax

    mov rcx, swapChain
    mov rax, [rcx]
    mov rax, [rax+64]                   ; Present(1,0)
    mov edx, 1
    xor r8d, r8d
    call rax
    test eax, eax
    js clean_exit                      ; device removed/reset must not busy-loop
    movss xmm0, currentTime
    movss previousTime, xmm0
    xor dword ptr historyIndex, 1
    inc frameCounter
    jmp main_message_loop

init_failed:
    xor ecx, ecx
    lea rdx, errorText
    lea r8, errorTitle
    mov r9d, MB_ICONERROR
    call MessageBoxA

clean_exit:
    cmp audioEnabled, 0
    je release_audio_memory
    mov rcx, audioHandle
    call waveOutReset
    mov rcx, audioHandle
    lea rdx, waveHeader
    mov r8d, 48
    call waveOutUnprepareHeader
    mov rcx, audioHandle
    call waveOutClose
    mov audioEnabled, 0

release_audio_memory:
    mov rcx, audioBuffer
    test rcx, rcx
    jz release_graphics
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
    mov audioBuffer, 0

release_graphics:
    ; Release context-held RTV/SRV/shader references before their owner slots.
    mov rcx, d3dContext
    test rcx, rcx
    jz release_graphics_objects
    mov rax, [rcx]
    call qword ptr [rax+880]            ; ID3D11DeviceContext::ClearState
release_graphics_objects:
    mov rcx, materialComputeShader
    call ReleaseObject
    mov rcx, materialUAVs[0]
    call ReleaseObject
    mov rcx, materialUAVs[8]
    call ReleaseObject
    mov rcx, materialSRVs[0]
    call ReleaseObject
    mov rcx, materialSRVs[8]
    call ReleaseObject
    mov rcx, materialTextures[0]
    call ReleaseObject
    mov rcx, materialTextures[8]
    call ReleaseObject
    mov rcx, materialSampler
    call ReleaseObject
    mov rcx, atmosphereComputeShader
    call ReleaseObject
    mov rcx, atmosphereUAV
    call ReleaseObject
    mov rcx, atmosphereSRV
    call ReleaseObject
    mov rcx, atmosphereTexture
    call ReleaseObject
    mov rcx, farShadowRTV
    call ReleaseObject
    mov rcx, farShadowSRV
    call ReleaseObject
    mov rcx, farShadowTexture
    call ReleaseObject
    mov rcx, farShadowDepthView
    call ReleaseObject
    mov rcx, farShadowDepthTexture
    call ReleaseObject
    mov rcx, physicsConstantBuffer
    call ReleaseObject
    mov rcx, flightComputeShader
    call ReleaseObject
    mov rcx, flightUAV
    call ReleaseObject
    mov rcx, flightSRV
    call ReleaseObject
    mov rcx, flightBuffer
    call ReleaseObject
    mov rcx, waterComputeShader
    call ReleaseObject
    mov rcx, waterUAVs[0]
    call ReleaseObject
    mov rcx, waterUAVs[8]
    call ReleaseObject
    mov rcx, waterSRVs[0]
    call ReleaseObject
    mov rcx, waterSRVs[8]
    call ReleaseObject
    mov rcx, waterTextures[0]
    call ReleaseObject
    mov rcx, waterTextures[8]
    call ReleaseObject
    mov rcx, passConstantBuffer
    call ReleaseObject
    mov rcx, reflectionRTV
    call ReleaseObject
    mov rcx, reflectionSRV
    call ReleaseObject
    mov rcx, reflectionTexture
    call ReleaseObject
    mov rcx, reflectionDepthView
    call ReleaseObject
    mov rcx, reflectionDepthTexture
    call ReleaseObject
    mov rcx, terrainUAV
    call ReleaseObject
    mov rcx, terrainSRV
    call ReleaseObject
    mov rcx, terrainTexture
    call ReleaseObject
    mov rcx, terrainComputeShader
    call ReleaseObject
    mov rcx, cameraFrameUAV
    call ReleaseObject
    mov rcx, instanceUAV
    call ReleaseObject
    mov rcx, instanceSRV
    call ReleaseObject
    mov rcx, instanceBuffer
    call ReleaseObject
    mov rcx, instanceComputeShader
    call ReleaseObject
    call ReleaseGeneratedVolumes
    mov rcx, cloudCompositeShader
    call ReleaseObject
    mov rcx, cloudedRTV
    call ReleaseObject
    mov rcx, cloudedSRV
    call ReleaseObject
    mov rcx, cloudedTexture
    call ReleaseObject
    mov rcx, reflectionCloudRTV
    call ReleaseObject
    mov rcx, reflectionCloudSRV
    call ReleaseObject
    mov rcx, reflectionCloudTexture
    call ReleaseObject
    mov rcx, postDepthState
    call ReleaseObject
    mov rcx, cameraFrameSRV
    call ReleaseObject
    mov rcx, cameraFrameBuffer
    call ReleaseObject
    mov rcx, batchConstantBuffer
    call ReleaseObject
    mov rcx, cameraComputeShader
    call ReleaseObject
    mov rcx, meshVertexShader
    call ReleaseObject
    mov rcx, meshPixelShader
    call ReleaseObject
    mov rcx, shadowVertexShader
    call ReleaseObject
    mov rcx, shadowPixelShader
    call ReleaseObject
    mov rcx, mainDepthView
    call ReleaseObject
    mov rcx, mainDepthTexture
    call ReleaseObject
    mov rcx, shadowDepthView
    call ReleaseObject
    mov rcx, shadowDepthTexture
    call ReleaseObject
    mov rcx, shadowRTV
    call ReleaseObject
    mov rcx, shadowSRV
    call ReleaseObject
    mov rcx, shadowTexture
    call ReleaseObject
    mov rcx, meshRasterizer
    call ReleaseObject
    mov rcx, worldDepthState
    call ReleaseObject
    mov rcx, postSampler
    call ReleaseObject
    mov rcx, historyRTV1
    call ReleaseObject
    mov rcx, historySRV1
    call ReleaseObject
    mov rcx, historyTexture1
    call ReleaseObject
    mov rcx, historyRTV0
    call ReleaseObject
    mov rcx, historySRV0
    call ReleaseObject
    mov rcx, historyTexture0
    call ReleaseObject
    mov rcx, lowBRTV
    call ReleaseObject
    mov rcx, lowBSRV
    call ReleaseObject
    mov rcx, lowBTexture
    call ReleaseObject
    mov rcx, lowRTV
    call ReleaseObject
    mov rcx, lowSRV
    call ReleaseObject
    mov rcx, lowTexture
    call ReleaseObject
    mov rcx, constantBuffer
    call ReleaseObject
    mov rcx, displayShader
    call ReleaseObject
    mov rcx, temporalShader
    call ReleaseObject
    mov rcx, humanShader
    call ReleaseObject
    mov rcx, pixelShader
    call ReleaseObject
    mov rcx, vertexShader
    call ReleaseObject
    mov rcx, renderTarget
    call ReleaseObject
    mov rcx, backBuffer
    call ReleaseObject
    mov rcx, d3dContext
    call ReleaseObject
    mov rcx, d3dDevice
    call ReleaseObject
    mov rcx, swapChain
    call ReleaseObject
    xor ecx, ecx
    call ExitProcess
start ENDP

; {6F15AAF2-D208-4E89-9AB4-489535D34F9C}
align 8
IID_ID3D11Texture2D:
    dd 06F15AAF2h
    dw 0D208h, 04E89h
    db 09Ah,0B4h,048h,095h,035h,0D3h,04Fh,09Ch

END
