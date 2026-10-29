; Visible, cancellable startup feedback for long neural inference.
; Win64 MASM, USER32 + KERNEL32 only; stock system brushes, no media/fonts.
; DrawStartupProgress() has no arguments or return value. Call from the UI
; thread before PumpInitializationMessages; the message pump handles Escape.
; This is an indeterminate activity bar, never a fabricated completion percent.
EXTERN GetDC:PROC
EXTERN ReleaseDC:PROC
EXTERN GetClientRect:PROC
EXTERN GetSysColorBrush:PROC
EXTERN FillRect:PROC
EXTERN DrawTextA:PROC
EXTERN GetTickCount64:PROC

.data
loadingMainText db "Generating the Alpine world and instruments",0
loadingCancelText db "Press Esc to cancel",0

.data?
align 8
loadingLastPaint dq ?
loadingClientRect dd 4 dup (?)
loadingTextRect dd 4 dup (?)
loadingBarRect dd 4 dup (?)

.code
DrawStartupProgress PROC
    cmp startupHidden, 0
    jne loading_return
    cmp startupCancelled, 0
    jne loading_return
    cmp hWindow, 0
    je loading_return

    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp, 30h                    ; 32-byte home area + fifth argument
    mov rsi, hWindow
    call GetTickCount64
    mov r13, rax
    cmp loadingLastPaint, 0
    je loading_time_ready
    sub rax, loadingLastPaint
    cmp rax, 250
    jb loading_done
loading_time_ready:
    mov loadingLastPaint, r13
    mov rcx, rsi
    lea rdx, loadingClientRect
    call GetClientRect
    test eax, eax
    jz loading_done
    mov edi, loadingClientRect[8]
    sub edi, loadingClientRect[0]
    mov r12d, loadingClientRect[12]
    sub r12d, loadingClientRect[4]
    cmp edi, 200
    jl loading_done
    cmp r12d, 160
    jl loading_done
    mov rcx, rsi
    call GetDC
    test rax, rax
    jz loading_done
    mov rbx, rax

    ; Default window DC text is black. COLOR_WINDOW supplies the standard
    ; white client background; the stock system brushes must not be deleted.
    mov ecx, 5                      ; COLOR_WINDOW
    call GetSysColorBrush
    mov r8, rax
    mov rcx, rbx
    lea rdx, loadingClientRect
    call FillRect

    mov loadingTextRect[0], 24
    mov eax, edi
    sub eax, 24
    mov loadingTextRect[8], eax
    mov eax, r12d
    sar eax, 1
    sub eax, 52
    mov loadingTextRect[4], eax
    add eax, 28
    mov loadingTextRect[12], eax
    mov rcx, rbx
    lea rdx, loadingMainText
    mov r8d, -1
    lea r9, loadingTextRect
    mov dword ptr [rsp+20h], 825h     ; CENTER | VCENTER | SINGLELINE | NOPREFIX
    call DrawTextA

    add loadingTextRect[4], 30
    add loadingTextRect[12], 30
    mov rcx, rbx
    lea rdx, loadingCancelText
    mov r8d, -1
    lea r9, loadingTextRect
    mov dword ptr [rsp+20h], 825h
    call DrawTextA

    ; A bounded segment bounces across the track according to elapsed time.
    ; This only indicates that the UI thread is alive, not inference progress.
    mov eax, edi
    sub eax, 64
    cmp eax, 440
    jle loading_track_width
    mov eax, 440
loading_track_width:
    mov ecx, edi
    sub ecx, eax
    sar ecx, 1
    mov loadingBarRect[0], ecx
    add eax, ecx
    mov loadingBarRect[8], eax
    mov eax, r12d
    sar eax, 1
    add eax, 35
    mov loadingBarRect[4], eax
    add eax, 12
    mov loadingBarRect[12], eax
    mov ecx, 15                     ; COLOR_BTNFACE
    call GetSysColorBrush
    mov r8, rax
    mov rcx, rbx
    lea rdx, loadingBarRect
    call FillRect

    mov ecx, loadingBarRect[8]
    sub ecx, loadingBarRect[0]
    sub ecx, 80
    lea r8d, [rcx+rcx]
    mov rax, r13
    shr rax, 5
    xor edx, edx
    div r8
    cmp edx, ecx
    jbe loading_segment_position
    sub r8d, edx
    mov edx, r8d
loading_segment_position:
    add loadingBarRect[0], edx
    mov eax, loadingBarRect[0]
    add eax, 80
    mov loadingBarRect[8], eax
    mov ecx, 13                     ; COLOR_HIGHLIGHT
    call GetSysColorBrush
    mov r8, rax
    mov rcx, rbx
    lea rdx, loadingBarRect
    call FillRect
    mov rcx, rsi
    mov rdx, rbx
    call ReleaseDC

loading_done:
    add rsp, 30h
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
loading_return:
    ret
DrawStartupProgress ENDP
