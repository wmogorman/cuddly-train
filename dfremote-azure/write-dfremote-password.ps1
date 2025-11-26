[CmdletBinding()]
param(
  [SecureString] $Password,
  [string] $OutFile = (Join-Path $PSScriptRoot 'dfremote-password.txt'),
  [switch] $Force,
  [string] $PasswordPlain
)

$ErrorActionPreference = 'Stop'

if ((Test-Path -Path $OutFile) -and -not $Force) {
  throw "Password file already exists at $OutFile. Use -Force to overwrite it."
}

if (-not $Password) {
  if ($PasswordPlain) {
    $Password = ConvertTo-SecureString -String $PasswordPlain -AsPlainText -Force
  } else {
    $Password = Read-Host "Enter the admin password for dfremote.ps1" -AsSecureString
  }
}

if (-not $Password) {
  throw "No password provided."
}

# DPAPI-protect the password for the current user on this workstation
$encrypted = ConvertFrom-SecureString -SecureString $Password
Set-Content -Path $OutFile -Value $encrypted -NoNewline

# Sanity check that the file can be read back on this profile
$null = ConvertTo-SecureString -String (Get-Content -Path $OutFile -Raw) -ErrorAction Stop

Write-Host "Encrypted password written to $OutFile" -ForegroundColor Green
Write-Host "Scope: Windows DPAPI (current user on this workstation). Run dfremote.ps1 as this same user." -ForegroundColor Yellow
