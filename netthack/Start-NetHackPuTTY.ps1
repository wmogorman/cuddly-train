# Launch the saved PuTTY session for NetHack and auto-send initial keystrokes.
[CmdletBinding()]
param(
    [string]$SessionName = "NetHack",
    [string]$UserName = "mayrwil",
    [string]$PuTTYPath,
    [int]$StartupTimeoutSeconds = 5,
    [int]$PostLaunchDelayMilliseconds = 500
)

if (-not $PuTTYPath -or -not (Test-Path -Path $PuTTYPath)) {
    $puttyCommand = Get-Command -Name putty.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($puttyCommand) {
        $PuTTYPath = $puttyCommand.Source
    } else {
        throw "Unable to find putty.exe. Provide -PuTTYPath with the full path to PuTTY."
    }
}

$sessionArgs = "-load `"$SessionName`""
$process = Start-Process -FilePath $PuTTYPath -ArgumentList $sessionArgs -PassThru

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Milliseconds 100
    try {
        $handle = $process.MainWindowHandle
    } catch {
        $handle = 0
    }
} while ($handle -eq 0 -and -not $process.HasExited -and $stopwatch.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds)

if ($handle -eq 0 -or $process.HasExited) {
    throw "PuTTY window not detected. Increase -StartupTimeoutSeconds if the session needs longer to open."
}

$null = $stopwatch.Stop()

Add-Type -Namespace PuTTYAutoKeys -Name NativeMethods -MemberDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public static class NativeMethods {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
"@

[PuTTYAutoKeys.NativeMethods]::SetForegroundWindow($handle) | Out-Null

if ($PostLaunchDelayMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $PostLaunchDelayMilliseconds
}

Add-Type -AssemblyName System.Windows.Forms

$initialKeys = "l{ENTER}$UserName{ENTER}"
[System.Windows.Forms.SendKeys]::SendWait($initialKeys)
