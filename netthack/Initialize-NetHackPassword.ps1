[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$UserName,
    [string]$UserNameFile = (Join-Path -Path $PSScriptRoot -ChildPath 'nethack-username.txt'),
    [string]$PasswordFile = (Join-Path -Path $PSScriptRoot -ChildPath 'nethack-password.txt'),
    [switch]$Force
)

$existingFiles = @()
if (Test-Path -Path $UserNameFile -PathType Leaf -ErrorAction SilentlyContinue) {
    $existingFiles += $UserNameFile
}

if (Test-Path -Path $PasswordFile -PathType Leaf -ErrorAction SilentlyContinue) {
    $existingFiles += $PasswordFile
}

if ($existingFiles.Count -gt 0 -and -not $Force) {
    $caption = "Credential files already exist"
    $fileList = $existingFiles -join "`n"
    $message = "Overwrite the existing file(s)?`n$fileList`nUse -Force to skip this prompt."
    if (-not $PSCmdlet.ShouldContinue($message, $caption)) {
        Write-Verbose "Operation cancelled by user."
        return
    }
}

if (-not $UserName) {
    $UserName = Read-Host -Prompt "Enter your NetHack username"
}

if ([string]::IsNullOrWhiteSpace($UserName)) {
    throw "Username input cancelled."
}

$securePassword = Read-Host -Prompt "Enter your NetHack password" -AsSecureString

if (-not $securePassword) {
    throw "Password input cancelled."
}

$encrypted = $securePassword | ConvertFrom-SecureString

if ($PSCmdlet.ShouldProcess($UserNameFile, "Write username")) {
    $UserName.Trim() | Set-Content -Path $UserNameFile -Encoding ascii
    Write-Host "Username saved to $UserNameFile"
}

if ($PSCmdlet.ShouldProcess($PasswordFile, "Write encrypted password")) {
    $encrypted | Set-Content -Path $PasswordFile -Encoding ascii
    Write-Host "Encrypted password saved to $PasswordFile"
}
