; Runtime modal sample synthesis. No wave recordings or precomputed waveforms.
; The string spectra follow a bowed/plucked-string modal expansion; hand-tuned
; body admittance peaks colour the bridge excitation. These are deliberately
; NOT claimed to be measurements or a complete nonlinear instrument simulation.
; See AUDIO_RU.md for the model, limits, validation and primary references.
ORCH_SAMPLE_FRAMES EQU 198450          ; 4.5 seconds, including release space
ORCH_SAMPLE_BYTES EQU ORCH_SAMPLE_FRAMES * 4
ORCH_SAMPLE_COUNT EQU 18
ORCH_MIX_BYTES EQU AUDIO_FRAMES * 8

.data
align 16
orchOne REAL4 1.0
orchZero REAL4 0.0
orchHalf REAL4 0.5
orchInvSine REAL4 0.000030525030525
orchInvRate REAL4 0.0000226757369615
orchNyquistSafe REAL4 9000.0
orchPhaseToHz REAL4 0.0000102678313851
orchVibratoScale REAL4 0.00000018
orchBassVibrato REAL4 0.000000004
orchBrassVibrato REAL4 0.00000012
orchSlowDrift REAL4 0.12
orchSectionVibrato REAL4 0.012
orchVibRamp REAL4 0.0000755857898715
orchSpectralSlope REAL4 0.018
orchViolinDecay REAL4 0.025
orchBrassDecay REAL4 0.055
orchBassDecay REAL4 0.75
orchBassHFDecay REAL4 0.055
orchBassStiffness REAL4 0.000018
orchViolinStiffness REAL4 0.0000012
orchScale REAL4 0.82
orchSafety REAL4 0.86
orchMasterGain REAL4 1.55
orchRMSFloor REAL4 0.00000001
orchDrumsGain REAL4 0.57
orchPCMScale REAL4 0.000030517578125
orchPCMMult REAL4 32767.0
orchDCpole REAL4 0.9992              ; ~5.6Hz: retain the double bass E1 fundamental
orchReverbDamping REAL4 0.28
orchReverbFeedback REAL4 0.69
orchReverbWet REAL4 0.13
orchStringGain REAL4 0.080
orchBassGain REAL4 0.175
orchTrumpetGain REAL4 0.20
orchNoiseGain REAL4 0.0025
orchBassNoiseGain REAL4 0.008
orchTrumpetNoiseGain REAL4 0.004
orchNoisePole REAL4 0.15
orchViolinAttack REAL4 0.00016
orchBrassAttack REAL4 0.00042
orchBassAttack REAL4 0.0020
orchReleaseInv REAL4 0.00015117158
orchStringReleaseInv REAL4 0.000045351474
orchBodyFloor REAL4 0.22
orchBassBodyFloor REAL4 0.65
orchBowPosition REAL4 0.091
orchPluckPosition REAL4 0.23
orchQuarterTurn REAL4 512.0
orchBowNotchDepth REAL4 0.45
orchBowNotchFloor REAL4 0.55
orchViolinRadiation REAL4 520.0
orchBassRadiation REAL4 90.0
orchBrassRadiation REAL4 650.0
orchBreathAttackInv REAL4 0.0002834467
orchBreathSustain REAL4 0.25

; Instrument, MIDI. Strings / double-bass / trumpet, respectively.
orchInstruments dd 0,0,0,0,0,0,0,0,0, 1,1,1,1, 2,2,2,2,2
orchNotes dd 55,57,59,60,62,64,67,69,71, 28,29,31,33, 64,67,69,71,74
orchChordSamples dd 3,5,8, 2,5,7, 1,5,6, 0,4,7
orchBassSamples dd 12,11,10,9
; Body modes: centre Hz, half-width Hz, relative amplitude. Values are model
; parameters, not stored audio. Bowed body/bridge hill, bass plates, brass bell.
orchViolinModes REAL4 280.0,65.0,0.80, 455.0,80.0,0.65, 540.0,90.0,0.90
                REAL4 1100.0,260.0,0.45, 2400.0,700.0,1.35, 3600.0,900.0,0.30
orchBassModes REAL4 82.0,30.0,1.15, 170.0,65.0,0.80, 390.0,130.0,0.55
              REAL4 720.0,240.0,0.30, 1400.0,550.0,0.12, 2300.0,700.0,0.04
orchBrassModes REAL4 420.0,260.0,0.35, 950.0,420.0,0.65, 1600.0,650.0,0.80
               REAL4 2550.0,950.0,0.75, 3900.0,900.0,0.30, 6000.0,1100.0,0.05
; Two players on each side of the section. Q16.16 rates ~ +/- 4 cents,
; uncorrelated onset/pan and evolving vibrato prevent a static chorus chord.
orchPlayerRates dd 65403,65642,65489,65593
orchPlayerDelays dd 0,331,617,953
orchPlayerPan REAL4 0.74,0.28,0.57,0.40
orchPlayerVibratoRates dd 480000,520000,560000,498000
orchBassRhythm db 127,0,127,0,127,127,0,127,127,0,127,127,0,127,127,0
; Sparse four-bar call/response; 127 = breath/rest. No constant lead arpeggio.
orchTrumpetPhrase db 127,127,127,127,127,127,127,127
                  db 13,127,127,127,127,127,15,127
                  db 127,127,127,127,127,127,127,127
                  db 14,127,127,127,16,127,127,127
orchRoomTaps dd 1499,2111,2633,3163

.data?
align 16
orchBank dq ?
orchPhaseBuffer dq ?
orchMix dq ?
orchSampleDest dq ?
orchKind dd ?
orchPitch dd ?
orchPartial dd ?
orchBaseIncrement dd ?
orchFundHz REAL4 ?
orchPartialHz REAL4 ?
orchPartialAmplitude REAL4 ?
orchPartialDecay REAL4 ?
orchPartialDrift dd ?
orchPartialPhase dd ?
orchVibAmount REAL4 ?
orchBodySum REAL4 ?
orchNoise REAL4 ?
orchRng dd ?
orchPeak REAL4 ?
orchBankIndex dd ?
orchNoteOffset dd ?
orchNoteLength dd ?
orchNoteGain REAL4 ?
orchNotePan REAL4 ?
orchNoteRate dd ?
orchNoteVibPhase dd ?
orchNoteVibRate dd ?
orchScheduleStep dd ?
orchScheduleVoice dd ?
orchSchedulePlayer dd ?
orchScheduleChord dd ?
orchDCinput REAL4 2 dup (?)
orchDCoutput REAL4 2 dup (?)
orchRoomState REAL4 4 dup (?)
orchRoom REAL4 4*4096 dup (?)
orchSeedOriginal dd ?
orchClipped dd ?
orchGenerated dd ?

.code
OrchestraRand PROC
    mov eax, orchRng
    imul eax, eax, 1664525
    add eax, 1013904223
    mov orchRng, eax
    ret
OrchestraRand ENDP

; rcx float output, edx instrument (0 bowed, 1 plucked, 2 brass), r8d MIDI.
; Forty-eight band-limited string/air-column modes, radiating-body response,
; stiffness dispersion and frequency-dependent decay. Each bank note receives
; a separately drifting vibrato trajectory and breath/bow/pluck excitation.
OrchestraMakeSample PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 20h
    mov orchSampleDest, rcx
    mov orchKind, edx
    mov orchPitch, r8d
    mov rdi, rcx
    xor eax, eax
    mov ecx, ORCH_SAMPLE_FRAMES
    rep stosd
    mov ecx, r8d
    mov edx, 0
    cmp ecx, 36
    jae orch_pitch_table
    add ecx, 12
    inc edx
orch_pitch_table:
    sub ecx, 36
    mov eax, noteIncrements[rcx*4]
    mov ecx, edx
    shr eax, cl
    mov orchBaseIncrement, eax
    cvtsi2ss xmm0, eax
    mulss xmm0, orchPhaseToHz
    movss orchFundHz, xmm0
    cvtsi2ss xmm0, eax
    mulss xmm0, orchVibratoScale
    cmp orchKind, 1
    jne orch_vib_brass
    cvtsi2ss xmm0, eax
    mulss xmm0, orchBassVibrato
orch_vib_brass:
    cmp orchKind, 2
    jne orch_vib_set
    cvtsi2ss xmm0, eax
    mulss xmm0, orchBrassVibrato
orch_vib_set:
    movss orchVibAmount, xmm0
    mov rdi, orchPhaseBuffer
    xor ebx, ebx
    xor r12d, r12d
    call OrchestraRand
    mov r13d, eax
    xor r14d, r14d
orch_phase_loop:
    add r13d, 510000                   ; 5.24 Hz; independent phase per bank note
    mov ecx, r13d
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    cvtsi2ss xmm0, eax
    mulss xmm0, orchVibAmount
    cvtsi2ss xmm1, ebx
    mulss xmm1, orchVibRamp
    minss xmm1, orchOne
    mulss xmm0, xmm1                    ; vibrato starts after the attack
    add r14d, 79000                    ; 0.81 Hz independent slow pitch drift
    mov ecx, r14d
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    cvtsi2ss xmm2, eax
    mulss xmm2, orchVibAmount
    mulss xmm2, orchSlowDrift
    addss xmm0, xmm2
    cvttss2si eax, xmm0
    add eax, orchBaseIncrement
    add r12d, eax
    mov [rdi+rbx*4], r12d
    inc ebx
    cmp ebx, ORCH_SAMPLE_FRAMES
    jb orch_phase_loop

    mov orchPartial, 1
orch_partial_setup:
    mov eax, orchPartial
    cvtsi2ss xmm0, eax
    mulss xmm0, orchFundHz
    movss orchPartialHz, xmm0
    comiss xmm0, orchNyquistSafe
    jae orch_partials_done
    lea rsi, orchViolinModes
    cmp orchKind, 1
    jne orch_mode_brass
    lea rsi, orchBassModes
orch_mode_brass:
    cmp orchKind, 2
    jne orch_mode_ready
    lea rsi, orchBrassModes
orch_mode_ready:
    movss xmm3, orchBodyFloor
    cmp orchKind, 1
    jne orch_mode_floor_ready
    movss xmm3, orchBassBodyFloor
orch_mode_floor_ready:
    mov ecx, 6
orch_mode_loop:
    movss xmm0, orchPartialHz
    subss xmm0, dword ptr [rsi]
    divss xmm0, dword ptr [rsi+4]
    mulss xmm0, xmm0
    addss xmm0, orchOne
    movss xmm1, dword ptr [rsi+8]
    divss xmm1, xmm0
    addss xmm3, xmm1
    add rsi, 12
    dec ecx
    jnz orch_mode_loop
    movss orchBodySum, xmm3
    mov eax, orchPartial
    cvtsi2ss xmm1, eax
    divss xmm3, xmm1                    ; Helmholtz-motion harmonic rolloff
    movss xmm2, xmm1
    mulss xmm2, orchSpectralSlope
    addss xmm2, orchOne
    mulss xmm2, xmm2
    divss xmm3, xmm2
    cmp orchKind, 1
    je orch_radiation_setup
    ; Bridge/bell radiation emphasises higher modes compared with the bare
    ; displacement spectrum. The previous common 1/k law sounded organ-like.
    sqrtss xmm2, xmm1
    mulss xmm3, xmm2
orch_radiation_setup:
    movss xmm2, orchViolinRadiation
    cmp orchKind, 1
    jne orch_radiation_brass
    movss xmm2, orchBassRadiation
orch_radiation_brass:
    cmp orchKind, 2
    jne orch_radiation_ready
    movss xmm2, orchBrassRadiation
orch_radiation_ready:
    mulss xmm2, xmm2
    movss xmm0, orchPartialHz
    mulss xmm0, xmm0
    addss xmm2, xmm0
    sqrtss xmm2, xmm2
    movss xmm0, orchPartialHz
    divss xmm0, xmm2
    mulss xmm3, xmm0
    cmp orchKind, 0
    jne orch_bow_position_done
    movss xmm0, xmm1
    mulss xmm0, orchBowPosition
    mulss xmm0, orchQuarterTurn
    addss xmm0, xmm0
    cvttss2si ecx, xmm0
    and ecx, SINE_SIZE-1
    movsx eax, word ptr sineTable[rcx*2]
    cdq
    xor eax, edx
    sub eax, edx
    cvtsi2ss xmm0, eax
    mulss xmm0, orchInvSine
    mulss xmm0, orchBowNotchDepth
    addss xmm0, orchBowNotchFloor
    mulss xmm3, xmm0
orch_bow_position_done:
    cmp orchKind, 1
    jne orch_not_pluck_spectrum
    ; Displacement at a finite pluck point gives sin(pi*k*x)/(k*k).
    divss xmm3, xmm1
    movss xmm0, xmm1
    mulss xmm0, orchPluckPosition
    mulss xmm0, orchQuarterTurn
    addss xmm0, xmm0
    cvttss2si ecx, xmm0
    and ecx, SINE_SIZE-1
    movsx eax, word ptr sineTable[rcx*2]
    cvtsi2ss xmm0, eax
    mulss xmm0, orchInvSine
    mulss xmm3, xmm0
orch_not_pluck_spectrum:
    ; Brass is pressure-shaped: stronger upper partials at a tongued onset,
    ; followed by faster harmonic relaxation. No static sawtooth oscillator.
    movss orchPartialAmplitude, xmm3
    movss xmm0, orchViolinDecay
    cmp orchKind, 1
    jne orch_decay_brass
    movss xmm0, orchBassHFDecay
    mulss xmm0, xmm1
    addss xmm0, orchBassDecay
orch_decay_brass:
    cmp orchKind, 2
    jne orch_decay_ready
    movss xmm0, orchBrassDecay
    mulss xmm0, xmm1
orch_decay_ready:
    mulss xmm0, orchInvRate
    movss xmm2, orchOne
    subss xmm2, xmm0
    movss orchPartialDecay, xmm2
    ; First-order stiff-string frequency correction sqrt(1+B*k*k) ~ 1+B*k*k/2.
    ; No bass modes above 9kHz enter the spectrum; B is small in this register.
    movss xmm0, orchViolinStiffness
    cmp orchKind, 1
    jne orch_disp_brass
    movss xmm0, orchBassStiffness
orch_disp_brass:
    cmp orchKind, 2
    jne orch_disp_ready
    xorps xmm0, xmm0
orch_disp_ready:
    mulss xmm0, xmm1
    mulss xmm0, xmm1
    mulss xmm0, xmm1
    mulss xmm0, orchHalf
    cvtsi2ss xmm2, orchBaseIncrement
    mulss xmm0, xmm2
    cvttss2si eax, xmm0
    mov orchPartialDrift, eax
    ; Fixed bridge phase plus a small partial-dependent phase offset.
    mov eax, orchPartial
    imul eax, eax, 5120000
    mov orchPartialPhase, eax
    mov rsi, orchPhaseBuffer
    mov rdi, orchSampleDest
    mov r12d, orchPartial
    mov r13d, orchPartialPhase
    mov r14d, orchPartialDrift
    movss xmm3, orchPartialAmplitude
    movss xmm4, orchPartialDecay
    xor ebx, ebx
orch_partial_loop:
    mov eax, [rsi+rbx*4]
    imul eax, r12d
    add r13d, r14d
    add eax, r13d
    shr eax, 21
    movsx eax, word ptr sineTable[rax*2]
    cvtsi2ss xmm0, eax
    mulss xmm0, orchInvSine
    mulss xmm0, xmm3
    addss xmm0, dword ptr [rdi+rbx*4]
    movss dword ptr [rdi+rbx*4], xmm0
    mulss xmm3, xmm4
    inc ebx
    cmp ebx, ORCH_SAMPLE_FRAMES
    jb orch_partial_loop
    inc orchPartial
    cmp orchPartial, 48
    jbe orch_partial_setup
orch_partials_done:
    mov rdi, orchSampleDest
    xor ebx, ebx
    mov orchPeak, 0
    mov orchNoise, 0
    xor r12d, r12d
orch_envelope_loop:
    call OrchestraRand
    shr eax, 16                        ; low bits of an LCG have short periods
    movsx eax, ax
    cvtsi2ss xmm0, eax
    mulss xmm0, orchInvSine
    subss xmm0, orchNoise
    mulss xmm0, orchNoisePole
    addss xmm0, orchNoise
    movss orchNoise, xmm0
    movss xmm3, orchNoiseGain
    cmp orchKind, 1
    jne orch_breath_kind
    movss xmm3, orchBassNoiseGain
    ; Very short finger/string excitation, not persistent white hiss.
    cvtsi2ss xmm1, ebx
    mulss xmm1, orchBassAttack
    movss xmm2, orchOne
    subss xmm2, xmm1
    maxss xmm2, orchZero
    mulss xmm3, xmm2
orch_breath_kind:
    cmp orchKind, 2
    jne orch_noise_kind_done
    cvtsi2ss xmm1, ebx
    mulss xmm1, orchBreathAttackInv
    movss xmm2, orchOne
    subss xmm2, xmm1
    maxss xmm2, orchBreathSustain
    movss xmm3, orchTrumpetNoiseGain
    mulss xmm3, xmm2
orch_noise_kind_done:
    mulss xmm0, xmm3
    addss xmm0, dword ptr [rdi+rbx*4]
    cvtsi2ss xmm1, ebx
    mulss xmm1, orchViolinAttack
    cmp orchKind, 0
    je orch_attack_ready
    cvtsi2ss xmm1, ebx
    mulss xmm1, orchBrassAttack
    cmp orchKind, 2
    je orch_attack_ready
    cvtsi2ss xmm1, ebx
    mulss xmm1, orchBassAttack
orch_attack_ready:
    minss xmm1, orchOne
    mulss xmm1, xmm1
    mulss xmm0, xmm1
    ; Non-periodic beat between two slow bow/breath intensity trajectories.
    add r12d, 51500
    mov ecx, r12d
    shr ecx, 21
    movsx eax, word ptr sineTable[rcx*2]
    cvtsi2ss xmm2, eax
    mulss xmm2, orchInvSine
    mulss xmm2, orchViolinDecay
    addss xmm2, orchOne
    mulss xmm0, xmm2
    movss dword ptr [rdi+rbx*4], xmm0
    ; Absolute value via sign clearing, no unbounded normalisation.
    movd eax, xmm0
    and eax, 7fffffffh
    movd xmm1, eax
    maxss xmm1, orchPeak
    movss orchPeak, xmm1
    inc ebx
    cmp ebx, ORCH_SAMPLE_FRAMES
    jb orch_envelope_loop
    movss xmm3, orchScale
    movss xmm0, orchPeak
    maxss xmm0, orchRMSFloor
    divss xmm3, xmm0
    xor ebx, ebx
orch_normalise_loop:
    movss xmm0, dword ptr [rdi+rbx*4]
    mulss xmm0, xmm3
    movss dword ptr [rdi+rbx*4], xmm0
    inc ebx
    cmp ebx, ORCH_SAMPLE_FRAMES
    jb orch_normalise_loop
    add rsp, 20h
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
OrchestraMakeSample ENDP

; ecx bank index; scheduling parameters live in orchNote*. Linear interpolation
; at gently detuned Q16.16 rates, bounded source/output, smooth release.
OrchestraMixNote PROC
    push rbx
    push rsi
    push rdi
    push r12
    mov eax, ORCH_SAMPLE_BYTES
    imul rax, rcx
    add rax, orchBank
    mov rsi, rax
    mov rdi, orchMix
    mov eax, orchNoteOffset
    lea rdi, [rdi+rax*8]
    xor ebx, ebx
    xor r12, r12
orch_mix_note_loop:
    mov eax, orchNoteOffset
    add eax, ebx
    cmp eax, AUDIO_FRAMES
    jae orch_mix_note_done
    mov rax, r12
    shr rax, 16
    cmp eax, ORCH_SAMPLE_FRAMES-1
    jae orch_mix_note_done
    movss xmm0, dword ptr [rsi+rax*4]
    movss xmm1, dword ptr [rsi+rax*4+4]
    subss xmm1, xmm0
    mov ecx, r12d
    and ecx, 65535
    cvtsi2ss xmm2, ecx
    mulss xmm2, inv65535
    mulss xmm1, xmm2
    addss xmm0, xmm1
    mulss xmm0, orchNoteGain
    mov eax, orchNoteLength
    sub eax, ebx
    cvtsi2ss xmm2, eax
    mulss xmm2, orchReleaseInv
    cmp orchNoteLength, 150000
    jb orch_note_release_ready
    cvtsi2ss xmm2, eax
    mulss xmm2, orchStringReleaseInv
orch_note_release_ready:
    minss xmm2, orchOne
    mulss xmm2, xmm2
    mulss xmm0, xmm2
    movss xmm1, orchNotePan
    mulss xmm1, xmm0
    subss xmm0, xmm1
    addss xmm1, dword ptr [rdi+rbx*8]
    addss xmm0, dword ptr [rdi+rbx*8+4]
    movss dword ptr [rdi+rbx*8], xmm1
    movss dword ptr [rdi+rbx*8+4], xmm0
    cmp orchNoteLength, 150000
    jb orch_note_fixed_rate
    mov eax, orchNoteVibPhase
    add eax, orchNoteVibRate
    mov orchNoteVibPhase, eax
    shr eax, 21
    movsx eax, word ptr sineTable[rax*2]
    cvtsi2ss xmm0, eax
    mulss xmm0, orchSectionVibrato
    cvttss2si eax, xmm0
    add eax, orchNoteRate
    jmp orch_note_rate_ready
orch_note_fixed_rate:
    mov eax, orchNoteRate
orch_note_rate_ready:
    add r12, rax
    inc ebx
    cmp ebx, orchNoteLength
    jb orch_mix_note_loop
orch_mix_note_done:
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
OrchestraMixNote ENDP

GenerateOrchestra PROC
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 20h
    mov orchGenerated, 0
    mov orchClipped, 0
    mov eax, noiseState
    or eax, 1
    mov orchRng, eax
    mov orchSeedOriginal, eax
    xor ecx, ecx
    mov edx, ORCH_SAMPLE_BYTES * ORCH_SAMPLE_COUNT
    mov r8d, MEM_COMMIT or MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    mov orchBank, rax
    test rax, rax
    jz orch_all_done
    xor ecx, ecx
    mov edx, ORCH_SAMPLE_BYTES
    mov r8d, MEM_COMMIT or MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    mov orchPhaseBuffer, rax
    test rax, rax
    jz orch_cleanup
    xor ecx, ecx
    mov edx, ORCH_MIX_BYTES
    mov r8d, MEM_COMMIT or MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    mov orchMix, rax
    test rax, rax
    jz orch_cleanup
    mov orchBankIndex, 0
orch_bank_loop:
    mov eax, orchBankIndex
    imul eax, ORCH_SAMPLE_BYTES
    mov rcx, orchBank
    add rcx, rax
    mov eax, orchBankIndex
    mov edx, orchInstruments[rax*4]
    mov r8d, orchNotes[rax*4]
    call OrchestraMakeSample
    inc orchBankIndex
    cmp orchBankIndex, ORCH_SAMPLE_COUNT
    jb orch_bank_loop

    ; 32 four-second harmonic phrases, each with three voices/four players.
    ; The long bow envelopes breathe through the lake; they never retrigger
    ; every eighth note like the old sine stabs.
    mov orchScheduleStep, 0
orch_strings_phrase:
    mov eax, orchScheduleStep
    and eax, 3
    mov orchScheduleChord, eax
    mov orchScheduleVoice, 0
orch_strings_voice:
    mov orchSchedulePlayer, 0
orch_strings_player:
    mov eax, orchScheduleStep
    imul eax, AUDIO_RATE * 4
    mov ecx, orchSchedulePlayer
    add eax, orchPlayerDelays[rcx*4]
    mov edx, orchScheduleVoice
    imul edx, 233
    add eax, edx
    mov orchNoteOffset, eax
    mov orchNoteLength, 187425          ; 4.25 s: crossfade into next harmony
    mov eax, orchPlayerRates[rcx*4]
    mov orchNoteRate, eax
    mov eax, orchPlayerVibratoRates[rcx*4]
    mov orchNoteVibRate, eax
    mov eax, ecx
    imul eax, eax, 1257823591
    mov edx, orchScheduleVoice
    imul edx, edx, 417127371
    add eax, edx
    mov orchNoteVibPhase, eax
    movss xmm0, orchPlayerPan[rcx*4]
    movss orchNotePan, xmm0
    movss xmm0, orchStringGain
    mov eax, orchScheduleStep
    cmp eax, 2
    jae orch_strings_intro_done
    mulss xmm0, orchHalf
orch_strings_intro_done:
    movss orchNoteGain, xmm0
    mov eax, orchScheduleChord
    lea eax, [rax+rax*2]
    add eax, orchScheduleVoice
    mov ecx, orchChordSamples[rax*4]
    call OrchestraMixNote
    inc orchSchedulePlayer
    cmp orchSchedulePlayer, 4
    jb orch_strings_player
    inc orchScheduleVoice
    cmp orchScheduleVoice, 3
    jb orch_strings_voice
    inc orchScheduleStep
    cmp orchScheduleStep, 32
    jb orch_strings_phrase

    ; Bass on syncopated eighth-note gaps, with ghost velocity variations and
    ; swung offsets. Rooted acoustic low register leaves the kick transient free.
    mov orchScheduleStep, 32
orch_bass_step:
    mov eax, orchScheduleStep
    cmp eax, 240
    jb orch_bass_arranged
    cmp eax, 336
    jb orch_bass_next
orch_bass_arranged:
    mov ecx, eax
    and ecx, 15
    cmp byte ptr orchBassRhythm[rcx], 127
    je orch_bass_next
    imul eax, STEP_SAMPLES
    add eax, 420
    mov orchNoteOffset, eax
    mov orchNoteLength, 48000
    mov orchNoteRate, 65536
    movss xmm0, orchHalf
    movss orchNotePan, xmm0
    movss xmm0, orchBassGain
    test orchScheduleStep, 2
    jz orch_bass_velocity
    mulss xmm0, orchScale
orch_bass_velocity:
    movss orchNoteGain, xmm0
    mov eax, orchScheduleStep
    shr eax, 4
    and eax, 3
    mov ecx, orchBassSamples[rax*4]
    call OrchestraMixNote
orch_bass_next:
    inc orchScheduleStep
    cmp orchScheduleStep, 480
    jb orch_bass_step

    ; Trumpet answers only in selected phrases, with complete breath gaps.
    ; Long tones connect the section; this is not a repeating toy lead riff.
    mov orchScheduleStep, 80
orch_trumpet_step:
    mov eax, orchScheduleStep
    cmp eax, 240
    jb orch_trumpet_arranged
    cmp eax, 336
    jb orch_trumpet_next
orch_trumpet_arranged:
    mov ecx, eax
    and ecx, 31
    movzx edx, byte ptr orchTrumpetPhrase[rcx]
    cmp edx, 127
    je orch_trumpet_next
    mov orchBankIndex, edx
    imul eax, STEP_SAMPLES
    add eax, 667
    mov orchNoteOffset, eax
    mov orchNoteLength, 39000
    cmp ecx, 16
    jb orch_trumpet_duration
    mov orchNoteLength, 66000
orch_trumpet_duration:
    mov orchNoteRate, 65521
    movss xmm0, orchPlayerPan[12]
    movss orchNotePan, xmm0
    movss xmm0, orchTrumpetGain
    movss orchNoteGain, xmm0
    mov ecx, orchBankIndex
    call OrchestraMixNote
orch_trumpet_next:
    inc orchScheduleStep
    cmp orchScheduleStep, 464
    jb orch_trumpet_step

    ; Shared damped feedback-delay room with a Householder scattering matrix.
    ; The feedback has spectral radius <1; no limiting is used to stabilise it.
    lea rdi, orchRoom
    xor eax, eax
    mov ecx, 4*4096
    rep stosd
    lea rdi, orchRoomState
    mov ecx, 4
    rep stosd
    lea rdi, orchDCinput
    mov ecx, 4
    rep stosd
    mov rsi, orchMix
    mov rdi, audioBuffer
    xor ebx, ebx
    xor r12d, r12d
    mov orchPeak, 0
orch_room_loop:
    ; Four delayed signals, each with a different prime delay and low-pass loss.
    xorps xmm4, xmm4
    xor r13d, r13d
orch_room_read:
    mov ecx, r12d
    sub ecx, orchRoomTaps[r13*4]
    and ecx, 4095
    mov edx, r13d
    shl edx, 12
    add ecx, edx
    movss xmm0, orchRoom[rcx*4]
    subss xmm0, orchRoomState[r13*4]
    mulss xmm0, orchReverbDamping
    addss xmm0, orchRoomState[r13*4]
    movss orchRoomState[r13*4], xmm0
    addss xmm4, xmm0
    inc r13d
    cmp r13d, 4
    jb orch_room_read
    mulss xmm4, orchHalf
    movss xmm3, dword ptr [rsi+rbx*8]
    addss xmm3, dword ptr [rsi+rbx*8+4]
    mulss xmm3, orchHalf
    xor r13d, r13d
orch_room_write:
    movss xmm0, xmm4
    subss xmm0, orchRoomState[r13*4]
    mulss xmm0, orchReverbFeedback
    addss xmm0, xmm3
    mov ecx, r13d
    shl ecx, 12
    add ecx, r12d
    movss orchRoom[rcx*4], xmm0
    inc r13d
    cmp r13d, 4
    jb orch_room_write
    movss xmm0, orchRoomState[0]
    addss xmm0, orchRoomState[8]
    mulss xmm0, orchReverbWet
    addss xmm0, dword ptr [rsi+rbx*8]
    movss xmm1, orchRoomState[4]
    addss xmm1, orchRoomState[12]
    mulss xmm1, orchReverbWet
    addss xmm1, dword ptr [rsi+rbx*8+4]
    ; Preserve the restrained house drums underneath the acoustic instruments.
    movsx eax, word ptr [rdi+rbx*4]
    cvtsi2ss xmm2, eax
    mulss xmm2, orchPCMScale
    mulss xmm2, orchDrumsGain
    addss xmm0, xmm2
    movsx eax, word ptr [rdi+rbx*4+2]
    cvtsi2ss xmm2, eax
    mulss xmm2, orchPCMScale
    mulss xmm2, orchDrumsGain
    addss xmm1, xmm2
    ; DC blocker and a quiet two-second closing fade preserve exact loop seam.
    movss xmm2, xmm0
    subss xmm0, orchDCinput[0]
    movss orchDCinput[0], xmm2
    movss xmm2, orchDCoutput[0]
    mulss xmm2, orchDCpole
    addss xmm0, xmm2
    movss orchDCoutput[0], xmm0
    movss xmm2, xmm1
    subss xmm1, orchDCinput[4]
    movss orchDCinput[4], xmm2
    movss xmm2, orchDCoutput[4]
    mulss xmm2, orchDCpole
    addss xmm1, xmm2
    movss orchDCoutput[4], xmm1
    mov eax, AUDIO_FRAMES
    sub eax, ebx
    cvtsi2ss xmm2, eax
    mulss xmm2, orchInvRate
    mulss xmm2, orchHalf
    minss xmm2, orchOne
    mulss xmm0, xmm2
    mulss xmm1, xmm2
    cvtsi2ss xmm2, ebx
    mulss xmm2, orchInvRate
    minss xmm2, orchOne
    mulss xmm0, xmm2
    mulss xmm1, xmm2
    movss dword ptr [rsi+rbx*8], xmm0
    movss dword ptr [rsi+rbx*8+4], xmm1
    movd eax, xmm0
    and eax, 7fffffffh
    movd xmm2, eax
    maxss xmm2, orchPeak
    movd eax, xmm1
    and eax, 7fffffffh
    movd xmm3, eax
    maxss xmm2, xmm3
    movss orchPeak, xmm2
    inc r12d
    and r12d, 4095
    inc ebx
    cmp ebx, AUDIO_FRAMES
    jb orch_room_loop
    movss xmm4, orchSafety
    movss xmm0, orchPeak
    mulss xmm0, orchMasterGain
    maxss xmm0, orchSafety
    divss xmm4, xmm0                    ; only reduce gain if headroom requires it
    mulss xmm4, orchMasterGain
    mulss xmm4, orchPCMMult
    xor ebx, ebx
orch_pcm_loop:
    movss xmm0, dword ptr [rsi+rbx*8]
    mulss xmm0, xmm4
    cvttss2si eax, xmm0
    mov word ptr [rdi+rbx*4], ax
    movss xmm0, dword ptr [rsi+rbx*8+4]
    mulss xmm0, xmm4
    cvttss2si eax, xmm0
    mov word ptr [rdi+rbx*4+2], ax
    inc ebx
    cmp ebx, AUDIO_FRAMES
    jb orch_pcm_loop
    mov orchGenerated, 1
orch_cleanup:
IFNDEF QA_AUDIO_KEEP_BANK
    mov rcx, orchBank
    test rcx, rcx
    jz orch_free_phase
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
    mov orchBank, 0
orch_free_phase:
ENDIF
    mov rcx, orchPhaseBuffer
    test rcx, rcx
    jz orch_free_mix
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
    mov orchPhaseBuffer, 0
orch_free_mix:
    mov rcx, orchMix
    test rcx, rcx
    jz orch_all_done
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
    mov orchMix, 0
orch_all_done:
    add rsp, 20h
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret
GenerateOrchestra ENDP
