[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PasswordFile = (Join-Path -Path $PSScriptRoot -ChildPath 'nethack-password.txt'),
    [switch]$Force
)

if (Test-Path -Path $PasswordFile -PathType Leaf -ErrorAction SilentlyContinue) {
    if (-not $Force) {
        $caption = "Password file already exists"
        $message = "Overwrite the existing file at `"$PasswordFile`"?`nUse -Force to skip this prompt."
        if (-not $PSCmdlet.ShouldContinue($message, $caption)) {
            Write-Verbose "Operation cancelled by user."
            return
        }
    }
}

$securePassword = Read-Host -Prompt "Enter your NetHack password" -AsSecureString

if (-not $securePassword) {
    throw "Password input cancelled."
}

$encrypted = $securePassword | ConvertFrom-SecureString

if ($PSCmdlet.ShouldProcess($PasswordFile, "Write encrypted password")) {
    $encrypted | Set-Content -Path $PasswordFile -Encoding ascii
    Write-Host "Encrypted password saved to $PasswordFile"
}
