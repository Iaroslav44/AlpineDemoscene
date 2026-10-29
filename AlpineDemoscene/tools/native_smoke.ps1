[CmdletBinding()]
param(
    [string]$Executable=(Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\AlpineDreaming.exe'),
    [ValidateRange(1,600)][int]$HoldSeconds=5,
    [ValidateRange(1,60)][int]$CloseWaitSeconds=30,
    [ValidateRange(0,100000)][int]$MinimumRenderedFrames=0,
    [string]$ReportPath=(Join-Path (Split-Path -Parent $PSScriptRoot) 'build\native_smoke.json')
)
$ErrorActionPreference='Stop'
if (-not ('AlpineNativeSmoke' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AlpineNativeSmoke {
    delegate bool EnumProc(IntPtr h,IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out IntPtr result);
    public static IntPtr Window(int processId) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,p)=>{uint id;GetWindowThreadProcessId(h,out id);if(id==(uint)processId){found=h;return false;}return true;},IntPtr.Zero);
        return found;
    }
    public static bool Responsive(IntPtr h) {IntPtr result;return SendMessageTimeout(h,0,IntPtr.Zero,IntPtr.Zero,2,500,out result)!=IntPtr.Zero;}
    public static long RenderedFrames(IntPtr h) {IntPtr result;return SendMessageTimeout(h,0x8001,IntPtr.Zero,IntPtr.Zero,2,2000,out result)!=IntPtr.Zero?result.ToInt64():-1;}
}
'@
}
$exePath=(Get-Item -LiteralPath $Executable).FullName
$clock=[Diagnostics.Stopwatch]::StartNew()
$process=Start-Process -FilePath $exePath -WorkingDirectory (Split-Path -Parent $exePath) -WindowStyle Hidden -PassThru
$window=[IntPtr]::Zero
$visible=$false
$forced=$false
$nextProgress=30
$renderedFrames=0
$firstFrameSeconds=$null
$peakWorkingSetBytes=0L
Write-Host "Hidden native validation started: PID=$($process.Id), hold=$HoldSeconds seconds."
try {
    while ($clock.Elapsed.TotalSeconds -lt $HoldSeconds -and -not $process.HasExited) {
        $window=[AlpineNativeSmoke]::Window($process.Id)
        if ($window -ne [IntPtr]::Zero) {
            $visible=$visible -or [AlpineNativeSmoke]::IsWindowVisible($window)
            if ($visible) { throw 'Native process did not honor the explicit hidden launch.' }
            if ($MinimumRenderedFrames -gt 0) {
                $renderedFrames=[AlpineNativeSmoke]::RenderedFrames($window)
                if ($renderedFrames -gt 0 -and $null -eq $firstFrameSeconds) {
                    $firstFrameSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,4)
                    Write-Host "Native renderer reached its first frames at $firstFrameSeconds seconds."
                }
                if ($renderedFrames -ge $MinimumRenderedFrames) { break }
            }
        }
        $process.Refresh()
        $peakWorkingSetBytes=[Math]::Max($peakWorkingSetBytes,$process.PeakWorkingSet64)
        if ($clock.Elapsed.TotalSeconds -ge $nextProgress) {
            Write-Host "Hidden native process is alive at $nextProgress seconds."
            $nextProgress+=30
        }
        Start-Sleep -Milliseconds 100
    }
    if ($process.HasExited) { throw "Native process exited before close request: $($process.ExitCode)." }
    if ($window -eq [IntPtr]::Zero) { throw 'Native process did not create a window.' }
    $responsive=[AlpineNativeSmoke]::Responsive($window)
    $renderedFrames=[AlpineNativeSmoke]::RenderedFrames($window)
    $closeAt=$clock.Elapsed.TotalSeconds
    if (-not [AlpineNativeSmoke]::PostMessage($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)) { throw 'Could not post WM_CLOSE.' }
    if (-not $process.WaitForExit($CloseWaitSeconds*1000)) {
        $forced=$true
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    $report=[ordered]@{
        executable=$exePath;sha256=(Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
        hold_seconds=$HoldSeconds;window_was_visible=$visible;responsive_before_close=$responsive
        close_latency_seconds=[Math]::Round($clock.Elapsed.TotalSeconds-$closeAt,4)
        exit_code=$process.ExitCode;forced_termination=$forced
        rendered_frames=$renderedFrames;minimum_rendered_frames=$MinimumRenderedFrames
        first_frame_observed_seconds=$firstFrameSeconds
        observed_seconds=[Math]::Round($closeAt,4);peak_working_set_bytes=$peakWorkingSetBytes
    }
    $report | ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8
    $report | ConvertTo-Json
    if ($visible -or -not $responsive -or $forced -or $process.ExitCode -ne 0) { throw 'Native smoke failed visibility, responsiveness, orderly shutdown, or exit-code contract.' }
    if ($renderedFrames -lt $MinimumRenderedFrames) { throw "Native process presented $renderedFrames frames; required $MinimumRenderedFrames. Startup alone does not pass playback validation." }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.Dispose()
}
