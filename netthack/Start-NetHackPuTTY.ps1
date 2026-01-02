# Launch the saved PuTTY session for NetHack and auto-send initial keystrokes.
[CmdletBinding()]
param(
    [string]$SessionName = "NetHack",
    [string]$UserName,
    [string]$UserNameFile = (Join-Path -Path $PSScriptRoot -ChildPath 'nethack-username.txt'),
    [string]$PasswordFile = (Join-Path -Path $PSScriptRoot -ChildPath 'nethack-password.txt'),
    [string]$PuTTYPath,
    [int]$StartupTimeoutSeconds = 5,
    [int]$PostLaunchDelayMilliseconds = 500,
    [switch]$PauseOnError,
    [switch]$ShowErrorDialog
)

$ErrorActionPreference = "Stop"
if (-not $PSBoundParameters.ContainsKey('ShowErrorDialog')) {
    $ShowErrorDialog = ($Host.Name -eq 'ConsoleHost' -and -not $env:VSCODE_PID)
}

function ConvertTo-SendKeysLiteral {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '+' { $null = $builder.Append('{+}') }
            '^' { $null = $builder.Append('{^}') }
            '%' { $null = $builder.Append('{%}') }
            '~' { $null = $builder.Append('{~}') }
            '(' { $null = $builder.Append('{(}') }
            ')' { $null = $builder.Append('{)}') }
            '{' { $null = $builder.Append('{{}') }
            '}' { $null = $builder.Append('{}}') }
            default { $null = $builder.Append($ch) }
        }
    }

    $builder.ToString()
}

function Resolve-PuTTYPath {
    param(
        [string]$PathOverride
    )

    if ($PathOverride -and (Test-Path -Path $PathOverride)) {
        return (Resolve-Path -Path $PathOverride).Path
    }

    $puttyCommand = Get-Command -Name putty.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($puttyCommand) {
        return $puttyCommand.Source
    }

    $candidates = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath "PuTTY\\putty.exe"),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "PuTTY\\putty.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-PuTTYSessions {
    $sessionRoot = "HKCU:\\Software\\SimonTatham\\PuTTY\\Sessions"
    if (-not (Test-Path -Path $sessionRoot)) {
        return @()
    }

    Get-ChildItem -Path $sessionRoot | Select-Object -ExpandProperty PSChildName | ForEach-Object {
        [System.Uri]::UnescapeDataString($_)
    }
}

function Test-PuTTYSessionExists {
    param(
        [Parameter(Mandatory = $true)][string]$SessionName
    )

    $sessionRoot = "HKCU:\\Software\\SimonTatham\\PuTTY\\Sessions"
    if (-not (Test-Path -Path $sessionRoot)) {
        Write-Verbose "PuTTY session registry not found; skipping session validation."
        return $true
    }

    $encodedName = [System.Uri]::EscapeDataString($SessionName)
    return (Test-Path -Path (Join-Path -Path $sessionRoot -ChildPath $encodedName))
}

function Show-StartupError {
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    Write-Error $Message
    if ($ShowErrorDialog) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show($Message, "Start-NetHackPuTTY error") | Out-Null
        } catch {
        }
    }
    if ($PauseOnError) {
        Read-Host "Press Enter to exit"
    }
}

try {
    $PuTTYPath = Resolve-PuTTYPath -PathOverride $PuTTYPath
    if (-not $PuTTYPath) {
        throw "Unable to find putty.exe. Provide -PuTTYPath with the full path to PuTTY."
    }
}

    if (-not $UserName -and (Test-Path -Path $UserNameFile -PathType Leaf -ErrorAction SilentlyContinue)) {
        $UserName = (Get-Content -Path $UserNameFile -Raw).Trim()
    }

    if ($UserName) {
        $UserName = $UserName.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        throw "Username not found. Run Initialize-NetHackPassword.ps1 to save it or pass -UserName."
    }

    if (-not (Test-Path -Path $PasswordFile -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Password file not found at $PasswordFile. Run Initialize-NetHackPassword.ps1 to create it."
    }

    if (-not (Test-PuTTYSessionExists -SessionName $SessionName)) {
        $availableSessions = Get-PuTTYSessions
        $availableText = if ($availableSessions.Count -gt 0) { $availableSessions -join ", " } else { "<none>" }
        throw "PuTTY session '$SessionName' not found. Available sessions: $availableText"
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

    if (-not ("PuTTYAutoKeys.NativeMethods" -as [type])) {
        $typeDefinition = @"
using System;
using System.Runtime.InteropServices;

namespace PuTTYAutoKeys {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(
            IntPtr hWnd,
            out RECT lpRect);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowPos(
            IntPtr hWnd,
            IntPtr hWndInsertAfter,
            int X,
            int Y,
            int cx,
            int cy,
            uint uFlags);
    }
}
"@
        Add-Type -TypeDefinition $typeDefinition
    }

    Add-Type -AssemblyName System.Windows.Forms

    $targetDisplay = [System.Windows.Forms.Screen]::AllScreens `
        | Where-Object { $_.DeviceName -eq '\\.\DISPLAY1' } `
        | Select-Object -First 1

    if (-not $targetDisplay) {
        $targetDisplay = [System.Windows.Forms.Screen]::AllScreens `
            | Where-Object { -not $_.Primary } `
            | Select-Object -First 1
    }

    if (-not $targetDisplay) {
        $targetDisplay = [System.Windows.Forms.Screen]::Primary
    }

    $workingArea = $targetDisplay.WorkingArea

    $windowRect = New-Object 'PuTTYAutoKeys.NativeMethods+RECT'
    $haveRect = [PuTTYAutoKeys.NativeMethods]::GetWindowRect($handle, [ref]$windowRect)

    if ($haveRect) {
        $windowWidth = $windowRect.Right - $windowRect.Left
        $windowHeight = $windowRect.Bottom - $windowRect.Top
    } else {
        $windowWidth = 0
        $windowHeight = 0
    }

    if ($windowWidth -le 0 -or $windowHeight -le 0) {
        $targetX = $workingArea.Left
        $targetY = $workingArea.Top
    } else {
        $offsetX = [System.Math]::Floor(($workingArea.Width - $windowWidth) / 2.0)
        $offsetY = [System.Math]::Floor(($workingArea.Height - $windowHeight) / 2.0)
        if ($offsetX -lt 0) { $offsetX = 0 }
        if ($offsetY -lt 0) { $offsetY = 0 }
        $targetX = $workingArea.Left + [int]$offsetX
        $targetY = $workingArea.Top + [int]$offsetY
    }

    $SWP_NOSIZE = 0x0001
    $SWP_NOZORDER = 0x0004
    $SWP_NOACTIVATE = 0x0010
    $flags = $SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE

    [PuTTYAutoKeys.NativeMethods]::SetWindowPos(
        $handle,
        [IntPtr]::Zero,
        $targetX,
        $targetY,
        0,
        0,
        [uint32]$flags
    ) | Out-Null

    [PuTTYAutoKeys.NativeMethods]::SetForegroundWindow($handle) | Out-Null

    if ($PostLaunchDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $PostLaunchDelayMilliseconds
    }

    $securePassword = Get-Content -Path $PasswordFile | ConvertTo-SecureString
    $passwordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringUni($passwordBstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr)
    }

    $escapedUserName = ConvertTo-SendKeysLiteral -Value $UserName
    $escapedPassword = ConvertTo-SendKeysLiteral -Value $plainPassword
    $initialKeys = "l$escapedUserName{ENTER}$escapedPassword{ENTER}"
    [System.Windows.Forms.SendKeys]::SendWait($initialKeys)
    $plainPassword = $null
} catch {
    $message = $_.Exception.Message
    if ($_.ScriptStackTrace) {
        $message = "$message`n$($_.ScriptStackTrace)"
    }
    Show-StartupError -Message $message
    exit 1
}
