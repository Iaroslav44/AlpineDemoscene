; ALPINE DREAMING
; A no-CRT x64 MASM / Direct3D 11 procedural audiovisual intro.
; Native host, compact DXBC shaders and procedural audio live in one EXE.

option casemap:none

EXTERN  ExitProcess:PROC
EXTERN  GetModuleHandleA:PROC
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
CW_RENDER_WIDTH                 EQU 960
CW_RENDER_HEIGHT                EQU 540
CW_LOW_WIDTH                    EQU 640
CW_LOW_HEIGHT                   EQU 360

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

; Full-resolution and half-resolution D3D11_VIEWPORTs.
align 8
outputViewport:
    dd 00000000h, 00000000h
    dd 44700000h, 44070000h        ; 960.0, 540.0
    dd 00000000h, 3F800000h

align 8
lowViewport:
    dd 00000000h, 00000000h
    dd 44200000h, 43B40000h        ; 640.0, 360.0
    dd 00000000h, 3F800000h

; D3D11_BUFFER_DESC: two float4s, dynamic CPU write.
align 8
constantBufferDesc:
    dd 32
    dd D3D11_USAGE_DYNAMIC
    dd D3D11_BIND_CONSTANT_BUFFER
    dd D3D11_CPU_ACCESS_WRITE
    dd 0, 0

; D3D11_TEXTURE2D_DESCs for the low-resolution scene and two HDR histories.
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

align 8
clearHistoryColour dd 00000000h, 00000000h, 00000000h, 00000000h
nullShaderResources dq 0, 0

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
    push rbx
    push rsi
    push rdi
    sub rsp, 30h
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
    call qword ptr [rax+120]             ; CreatePixelShader
    jmp embedded_shader_done

embedded_shader_failed:
    mov eax, 80004005h
embedded_shader_done:
    add rsp, 30h
    pop rdi
    pop rsi
    pop rbx
    ret
LoadEmbeddedPixelShader ENDP


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

    ; Centre a borderless 960x540 canvas; scale down on smaller displays.
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

    mov rcx, rax
    mov edx, SW_SHOW
    call ShowWindow
    mov rcx, hWindow
    call UpdateWindow

    ; Create D3D11 hardware device; WARP is an automatic software fallback.
    xor ecx, ecx
    mov edx, D3D_DRIVER_TYPE_HARDWARE
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 40h
    mov qword ptr [rsp+20h], 0
    mov qword ptr [rsp+28h], 0
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
    mov qword ptr [rsp+20h], 0
    mov qword ptr [rsp+28h], 0
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
    ; Locate both fxc-produced bytecode blobs in the executable resources.
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

    mov ecx, 103
    lea rdx, humanShader
    call LoadEmbeddedPixelShader
    test eax, eax
    js init_failed

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

    ; Low-resolution HDR scene plus two full-resolution temporal histories.
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

    mov rcx, d3dDevice
    mov rax, [rcx]
    lea rdx, postSamplerDesc
    lea r8, postSampler
    call qword ptr [rax+184]             ; CreateSamplerState
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
    mov rax, [rax+128]                  ; PSSetConstantBuffers
    xor edx, edx
    mov r8d, 1
    lea r9, constantBuffer
    call rax

    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+80]                   ; PSSetSamplers(s0)
    xor edx, edx
    mov r8d, 1
    lea r9, postSampler
    call rax

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
    ; ID3D11DeviceContext::Map(constantBuffer, WRITE_DISCARD)
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+112]
    mov rdx, constantBuffer
    xor r8d, r8d
    mov r9d, D3D11_MAP_WRITE_DISCARD
    sub rsp, 10h
    mov qword ptr [rsp+20h], 0
    lea r10, mappedData
    mov qword ptr [rsp+28h], r10
    call rax
    add rsp, 10h
    test eax, eax
    js clean_exit
    mov rax, qword ptr mappedData[0]
    mov dword ptr [rax+0], 44200000h     ; low width 640.0
    mov dword ptr [rax+4], 43B40000h     ; low height 360.0
    movss xmm0, currentTime
    movss dword ptr [rax+8], xmm0
    cvtsi2ss xmm0, frameCounter
    movss dword ptr [rax+12], xmm0
    mov dword ptr [rax+16], 44700000h    ; output width 960.0
    mov dword ptr [rax+20], 44070000h    ; output height 540.0
    movss xmm0, runSeed
    movss dword ptr [rax+24], xmm0
    movss xmm0, previousTime
    movss dword ptr [rax+28], xmm0

    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+120]                  ; Unmap
    mov rdx, constantBuffer
    xor r8d, r8d
    call rax

    movss xmm0, currentTime
    movss previousTime, xmm0

    ; Any SRV left by the preceding display pass must be detached before one of
    ; the ping-pong resources can become an RTV again.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+64]                   ; PSSetShaderResources
    xor edx, edx
    mov r8d, 2
    lea r9, nullShaderResources
    call rax

    ; Pass 1: procedural scene into the half-resolution linear HDR surface S.
    mov rcx, d3dContext
    mov rax, [rcx]
    mov rax, [rax+264]                  ; OMSetRenderTargets
    mov edx, 1
    lea r8, lowRTV
    xor r9d, r9d
    call rax
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

    ; Pass 2: composite procedural humans over LowA into LowB.  Keeping the
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

    ; Select Hprev/Hnext without copying. historyIndex names the valid previous
    ; surface; the opposite surface becomes this frame's temporal RTV.
    cmp historyIndex, 0
    jne temporal_previous_one
    mov rax, lowBSRV
    mov temporalBindings[0], rax
    mov rax, historySRV0
    mov temporalBindings[8], rax
    mov rax, historyRTV1
    mov nextRTVBinding, rax
    mov rax, historySRV1
    mov displayBinding, rax
    jmp temporal_targets_ready
temporal_previous_one:
    mov rax, lowBSRV
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
