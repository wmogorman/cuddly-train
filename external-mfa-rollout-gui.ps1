Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rolloutScriptPath = Join-Path $scriptDir "external-mfa-rollout.ps1"

function New-LabelControl {
  param(
    [string]$Text,
    [int]$X,
    [int]$Y,
    [int]$Width = 220
  )

  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($X, $Y)
  $label.Size = New-Object System.Drawing.Size($Width, 22)
  return $label
}

function New-TextBoxControl {
  param(
    [int]$X,
    [int]$Y,
    [int]$Width = 520,
    [string]$Text = "",
    [bool]$Multiline = $false,
    [int]$Height = 24
  )

  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Location = New-Object System.Drawing.Point($X, $Y)
  $tb.Size = New-Object System.Drawing.Size($Width, $Height)
  $tb.Text = $Text
  $tb.Multiline = $Multiline
  if ($Multiline) {
    $tb.ScrollBars = "Vertical"
  }
  return $tb
}

function New-CheckBoxControl {
  param(
    [string]$Text,
    [int]$X,
    [int]$Y,
    [bool]$Checked = $false,
    [int]$Width = 520
  )

  $cb = New-Object System.Windows.Forms.CheckBox
  $cb.Text = $Text
  $cb.Location = New-Object System.Drawing.Point($X, $Y)
  $cb.Size = New-Object System.Drawing.Size($Width, 24)
  $cb.Checked = $Checked
  return $cb
}

function Escape-ForPreview {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Parse-MethodIdList {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @()
  }

  return @(
    ($Text -split "[,\r\n]") |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "External MFA Rollout GUI"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(980, 920)
$form.MinimumSize = New-Object System.Drawing.Size(980, 920)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size = New-Object System.Drawing.Size(944, 600)
$form.Controls.Add($tabs)

$tabBasics = New-Object System.Windows.Forms.TabPage
$tabBasics.Text = "Basics"
$tabs.TabPages.Add($tabBasics)

$tabOptions = New-Object System.Windows.Forms.TabPage
$tabOptions.Text = "Options"
$tabs.TabPages.Add($tabOptions)

$tabNotes = New-Object System.Windows.Forms.TabPage
$tabNotes.Text = "Notes"
$tabs.TabPages.Add($tabNotes)

# Basics tab controls
$y = 20
$tabBasics.Controls.Add((New-LabelControl -Text "Rollout script path" -X 16 -Y $y))
$txtScriptPath = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660 -Text $rolloutScriptPath
$tabBasics.Controls.Add($txtScriptPath)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "EAM Name (required)" -X 16 -Y $y))
$txtName = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660 -Text "Cisco Duo"
$tabBasics.Controls.Add($txtName)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "ClientId (optional if EAM already exists)" -X 16 -Y $y))
$txtClientId = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660
$tabBasics.Controls.Add($txtClientId)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "DiscoveryEndpoint (optional if EAM already exists)" -X 16 -Y $y))
$txtDiscovery = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660 -Text "https://us.azureauth.duosecurity.com/.well-known/openid-configuration"
$tabBasics.Controls.Add($txtDiscovery)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "AppId (optional if EAM already exists)" -X 16 -Y $y))
$txtAppId = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660
$tabBasics.Controls.Add($txtAppId)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "ExternalAuthConfigId (recommended if EAM already exists)" -X 16 -Y $y))
$txtExternalConfigId = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660
$tabBasics.Controls.Add($txtExternalConfigId)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "PilotGroupName" -X 16 -Y $y))
$txtPilotGroup = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660 -Text "DMX-ExternalMFA-Pilot-GlobalAdmins"
$tabBasics.Controls.Add($txtPilotGroup)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "WrapperGroupName" -X 16 -Y $y))
$txtWrapperGroup = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660 -Text "DMX-ExternalMFA-Users"
$tabBasics.Controls.Add($txtWrapperGroup)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "Conditional Access policy name" -X 16 -Y $y))
$txtCaPolicy = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660 -Text "DMX - Require MFA (External MFA)"
$tabBasics.Controls.Add($txtCaPolicy)
$y += 34

$tabBasics.Controls.Add((New-LabelControl -Text "BreakGlassGroupId (required for rollout)" -X 16 -Y $y))
$txtBreakGlassGroupId = New-TextBoxControl -X 240 -Y ($y - 2) -Width 660
$tabBasics.Controls.Add($txtBreakGlassGroupId)
$y += 42

$cbOffboard = New-CheckBoxControl -Text "Offboard to Microsoft-preferred MFA (reverse rollout)" -X 20 -Y $y -Checked $false -Width 880
$tabBasics.Controls.Add($cbOffboard)
$y += 28

$cbWhatIf = New-CheckBoxControl -Text "WhatIf (dry run)" -X 20 -Y $y -Checked $false -Width 220
$tabBasics.Controls.Add($cbWhatIf)
$cbConfirmFalse = New-CheckBoxControl -Text "Skip confirmations (-Confirm:`$false)" -X 260 -Y $y -Checked $true -Width 300
$tabBasics.Controls.Add($cbConfirmFalse)
$y += 28

$cbNoExit = New-CheckBoxControl -Text "Keep console window open after run" -X 20 -Y $y -Checked $true -Width 300
$tabBasics.Controls.Add($cbNoExit)

# Options tab controls
$y2 = 20
$tabOptions.Controls.Add((New-LabelControl -Text "Strict external-only options" -X 16 -Y $y2 -Width 300))
$y2 += 30

$cbDisableMsAuth = New-CheckBoxControl -Text "Disable Microsoft Authenticator method policy" -X 20 -Y $y2 -Checked $false -Width 420
$tabOptions.Controls.Add($cbDisableMsAuth)
$cbDisableRegCampaign = New-CheckBoxControl -Text "Disable Authenticator registration campaign" -X 460 -Y $y2 -Checked $true -Width 420
$tabOptions.Controls.Add($cbDisableRegCampaign)
$y2 += 28

$cbDisableSystemPreferred = New-CheckBoxControl -Text "Disable system-preferred MFA" -X 20 -Y $y2 -Checked $true -Width 420
$tabOptions.Controls.Add($cbDisableSystemPreferred)
$cbRestrictMethods = New-CheckBoxControl -Text "Restrict common Microsoft MFA methods for wrapper group" -X 460 -Y $y2 -Checked $true -Width 420
$tabOptions.Controls.Add($cbRestrictMethods)
$y2 += 36

$tabOptions.Controls.Add((New-LabelControl -Text "WrapperGroupExcludedMethodIds (comma-separated)" -X 16 -Y $y2 -Width 320))
$txtExcludedMethods = New-TextBoxControl -X 20 -Y ($y2 + 24) -Width 860 -Height 54 -Multiline $true -Text "microsoftAuthenticator, sms, voice, softwareOath, hardwareOath"
$tabOptions.Controls.Add($txtExcludedMethods)
$y2 += 92

$tabOptions.Controls.Add((New-LabelControl -Text "Bulk registration" -X 16 -Y $y2 -Width 200))
$y2 += 30

$cbBulkRegister = New-CheckBoxControl -Text "Bulk-register External MFA for wrapper-group users" -X 20 -Y $y2 -Checked $false -Width 420
$tabOptions.Controls.Add($cbBulkRegister)
$cbBulkSkipDisabled = New-CheckBoxControl -Text "Skip disabled users during bulk registration" -X 460 -Y $y2 -Checked $true -Width 420
$tabOptions.Controls.Add($cbBulkSkipDisabled)
$y2 += 28

$cbBulkIncludeGuests = New-CheckBoxControl -Text "Include guest users during bulk registration" -X 20 -Y $y2 -Checked $false -Width 420
$tabOptions.Controls.Add($cbBulkIncludeGuests)
$y2 += 40

$tabOptions.Controls.Add((New-LabelControl -Text "Prereqs / diagnostics" -X 16 -Y $y2 -Width 240))
$y2 += 30

$cbEnforcePrereqs = New-CheckBoxControl -Text "Enforce strict external-only tenant prereqs (disable Security Defaults + admin SSPR flag)" -X 20 -Y $y2 -Checked $false -Width 860
$tabOptions.Controls.Add($cbEnforcePrereqs)
$y2 += 28

$cbAuditReadiness = New-CheckBoxControl -Text "Run EAM-only readiness audit (diagnostic output)" -X 20 -Y $y2 -Checked $true -Width 420
$tabOptions.Controls.Add($cbAuditReadiness)

# Notes tab
$txtNotes = New-TextBoxControl -X 16 -Y 16 -Width 890 -Height 520 -Multiline $true
$txtNotes.ReadOnly = $true
$txtNotes.Text = @"
Use this GUI to launch external-mfa-rollout.ps1 for teammates.

Recommended workflow:
1. Fill required rollout value: Name.
2. If creating a NEW EAM, also provide ClientId, DiscoveryEndpoint, and AppId.
3. If the EAM already exists in Entra, paste ExternalAuthConfigId (recommended) and you can leave ClientId/DiscoveryEndpoint/AppId blank.
4. Provide BreakGlassGroupId for the emergency admin exclusion before running a rollout.
5. Leave Microsoft Authenticator enabled unless you intentionally want the script to disable it.
6. Use Run In Console so teammates can complete Microsoft Graph interactive sign-in.

High-impact options:
- Enforce strict external-only tenant prereqs:
  Tenant-wide changes (best-effort) that disable Security Defaults and the admin SSPR authorizationPolicy flag.
- Offboard:
  Reverses the rollout (CA policy removal + EAM disable + Microsoft-preferred settings restore).

Manual items still required for strict external-only:
- Password reset / SSPR portal settings (Registration / Properties / reset methods)
  are not reliably controlled by supported Graph endpoints in the rollout script.
"@
$tabNotes.Controls.Add($txtNotes)

# Bottom action area
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 618)
$lblStatus.Size = New-Object System.Drawing.Size(940, 18)
$lblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
$lblStatus.Text = "Ready."
$form.Controls.Add($lblStatus)

$tabPreview = New-Object System.Windows.Forms.TabControl
$tabPreview.Location = New-Object System.Drawing.Point(10, 640)
$tabPreview.Size = New-Object System.Drawing.Size(944, 138)
$form.Controls.Add($tabPreview)

$tabCommand = New-Object System.Windows.Forms.TabPage
$tabCommand.Text = "Command Preview"
$tabPreview.TabPages.Add($tabCommand)

$txtCommandPreview = New-TextBoxControl -X 10 -Y 10 -Width 910 -Height 120 -Multiline $true
$txtCommandPreview.Font = New-Object System.Drawing.Font("Consolas", 9)
$tabCommand.Controls.Add($txtCommandPreview)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh Preview"
$btnRefresh.Location = New-Object System.Drawing.Point(10, 782)
$btnRefresh.Size = New-Object System.Drawing.Size(120, 28)
$form.Controls.Add($btnRefresh)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Copy Command"
$btnCopy.Location = New-Object System.Drawing.Point(138, 782)
$btnCopy.Size = New-Object System.Drawing.Size(120, 28)
$form.Controls.Add($btnCopy)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Run In Console"
$btnRun.Location = New-Object System.Drawing.Point(266, 782)
$btnRun.Size = New-Object System.Drawing.Size(120, 28)
$form.Controls.Add($btnRun)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Location = New-Object System.Drawing.Point(834, 782)
$btnClose.Size = New-Object System.Drawing.Size(120, 28)
$form.Controls.Add($btnClose)

function Get-UiState {
  return [pscustomobject]@{
    ScriptPath                     = $txtScriptPath.Text.Trim()
    Name                           = $txtName.Text.Trim()
    ClientId                       = $txtClientId.Text.Trim()
    DiscoveryEndpoint              = $txtDiscovery.Text.Trim()
    AppId                          = $txtAppId.Text.Trim()
    ExternalAuthConfigId           = $txtExternalConfigId.Text.Trim()
    PilotGroupName                 = $txtPilotGroup.Text.Trim()
    WrapperGroupName               = $txtWrapperGroup.Text.Trim()
    CaPolicyName                   = $txtCaPolicy.Text.Trim()
    BreakGlassGroupId              = $txtBreakGlassGroupId.Text.Trim()
    Offboard                       = $cbOffboard.Checked
    WhatIf                         = $cbWhatIf.Checked
    ConfirmFalse                   = $cbConfirmFalse.Checked
    KeepConsoleOpen                = $cbNoExit.Checked
    DisableMicrosoftAuthenticator  = $cbDisableMsAuth.Checked
    DisableAuthRegistrationCampaign = $cbDisableRegCampaign.Checked
    DisableSystemPreferredMfa      = $cbDisableSystemPreferred.Checked
    RestrictMethods                = $cbRestrictMethods.Checked
    ExcludedMethodIds              = @(Parse-MethodIdList -Text $txtExcludedMethods.Text)
    BulkRegister                   = $cbBulkRegister.Checked
    BulkSkipDisabledUsers          = $cbBulkSkipDisabled.Checked
    BulkIncludeGuestUsers          = $cbBulkIncludeGuests.Checked
    AuditReadiness                 = $cbAuditReadiness.Checked
    EnforceStrictPrereqs           = $cbEnforcePrereqs.Checked
  }
}

function Test-UiState {
  param($State)

  $errors = New-Object System.Collections.Generic.List[string]

  if ([string]::IsNullOrWhiteSpace($State.ScriptPath)) {
    $errors.Add("Rollout script path is required.") | Out-Null
  }
  elseif (-not (Test-Path -LiteralPath $State.ScriptPath)) {
    $errors.Add("Rollout script not found: $($State.ScriptPath)") | Out-Null
  }

  if ([string]::IsNullOrWhiteSpace($State.Name)) {
    $errors.Add("EAM Name is required.") | Out-Null
  }

  if (-not $State.Offboard -and [string]::IsNullOrWhiteSpace($State.BreakGlassGroupId)) {
    $errors.Add("BreakGlassGroupId is required for rollout mode.") | Out-Null
  }

  if (-not $State.Offboard) {
    $providerFields = @(
      @{ Label = "ClientId"; Value = $State.ClientId },
      @{ Label = "DiscoveryEndpoint"; Value = $State.DiscoveryEndpoint },
      @{ Label = "AppId"; Value = $State.AppId }
    )
    $providedProviderFields = @(
      $providerFields | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) }
    )
    if ($providedProviderFields.Count -gt 0 -and $providedProviderFields.Count -lt $providerFields.Count) {
      $errors.Add("Provider fields are partially filled. Supply all of ClientId/DiscoveryEndpoint/AppId, or leave all blank when reusing an existing EAM.") | Out-Null
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($State.ExternalAuthConfigId)) {
    [guid]$tmpGuid = [guid]::Empty
    if (-not [guid]::TryParse($State.ExternalAuthConfigId, [ref]$tmpGuid)) {
      $errors.Add("ExternalAuthConfigId must be a valid GUID if provided.") | Out-Null
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($State.BreakGlassGroupId)) {
    [guid]$breakGlassGuid = [guid]::Empty
    if (-not [guid]::TryParse($State.BreakGlassGroupId, [ref]$breakGlassGuid)) {
      $errors.Add("BreakGlassGroupId must be a valid GUID if provided.") | Out-Null
    }
  }

  if ($State.RestrictMethods -and @($State.ExcludedMethodIds).Count -eq 0) {
    $errors.Add("WrapperGroupExcludedMethodIds is empty while restriction is enabled.") | Out-Null
  }

  return @($errors)
}

function Build-RunCommand {
  param($State)

  $argList = @()
  $previewParts = @()

  $argList += "-NoProfile"
  if ($State.KeepConsoleOpen) {
    $argList += "-NoExit"
  }
  $argList += "-ExecutionPolicy"
  $argList += "Bypass"
  $argList += "-File"
  $argList += $State.ScriptPath

  $previewParts += "powershell.exe"
  $previewParts += "-NoProfile"
  if ($State.KeepConsoleOpen) { $previewParts += "-NoExit" }
  $previewParts += "-ExecutionPolicy Bypass"
  $previewParts += "-File $(Escape-ForPreview -Value $State.ScriptPath)"

  $stringParams = @(
    @{ Name = "Name"; Value = $State.Name; Always = $true },
    @{ Name = "ClientId"; Value = $State.ClientId; Always = -not $State.Offboard },
    @{ Name = "DiscoveryEndpoint"; Value = $State.DiscoveryEndpoint; Always = -not $State.Offboard },
    @{ Name = "AppId"; Value = $State.AppId; Always = -not $State.Offboard },
    @{ Name = "ExternalAuthConfigId"; Value = $State.ExternalAuthConfigId; Always = -not [string]::IsNullOrWhiteSpace($State.ExternalAuthConfigId) },
    @{ Name = "PilotGroupName"; Value = $State.PilotGroupName; Always = $true },
    @{ Name = "WrapperGroupName"; Value = $State.WrapperGroupName; Always = $true },
    @{ Name = "CaPolicyName"; Value = $State.CaPolicyName; Always = $true },
    @{ Name = "BreakGlassGroupId"; Value = $State.BreakGlassGroupId; Always = -not $State.Offboard }
  )

  foreach ($p in $stringParams) {
    if ($p.Always -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
      $argList += "-$($p.Name)"
      $argList += [string]$p.Value
      $previewParts += "-$($p.Name) $(Escape-ForPreview -Value ([string]$p.Value))"
    }
  }

  $boolParams = @(
    @{ Name = "DisableMicrosoftAuthenticatorPolicy"; Value = $State.DisableMicrosoftAuthenticator },
    @{ Name = "DisableAuthenticatorRegistrationCampaign"; Value = $State.DisableAuthRegistrationCampaign },
    @{ Name = "DisableSystemPreferredMfa"; Value = $State.DisableSystemPreferredMfa },
    @{ Name = "RestrictCommonMicrosoftMfaMethodsForWrapperGroup"; Value = $State.RestrictMethods },
    @{ Name = "BulkRegisterExternalAuthMethodForWrapperGroupUsers"; Value = $State.BulkRegister },
    @{ Name = "BulkRegisterSkipDisabledUsers"; Value = $State.BulkSkipDisabledUsers },
    @{ Name = "BulkRegisterIncludeGuestUsers"; Value = $State.BulkIncludeGuestUsers },
    @{ Name = "AuditEamOnlyPilotReadiness"; Value = $State.AuditReadiness },
    @{ Name = "EnforceStrictExternalOnlyTenantPrereqs"; Value = $State.EnforceStrictPrereqs }
  )

  foreach ($p in $boolParams) {
    $v = if ($p.Value) { '$true' } else { '$false' }
    $argList += "-$($p.Name)"
    $argList += $v
    $previewParts += "-$($p.Name) $v"
  }

  if ($State.RestrictMethods) {
    $argList += "-WrapperGroupExcludedMethodIds"
    foreach ($methodId in @($State.ExcludedMethodIds)) {
      $argList += $methodId
    }
    $previewParts += "-WrapperGroupExcludedMethodIds " + ((@($State.ExcludedMethodIds) | ForEach-Object { Escape-ForPreview -Value $_ }) -join ", ")
  }

  if ($State.Offboard) {
    $argList += "-OffboardToMicrosoftPreferred"
    $previewParts += "-OffboardToMicrosoftPreferred"
  }
  if ($State.WhatIf) {
    $argList += "-WhatIf"
    $previewParts += "-WhatIf"
  }
  if ($State.ConfirmFalse) {
    $argList += "-Confirm:`$false"
    $previewParts += "-Confirm:`$false"
  }

  return [pscustomobject]@{
    ArgumentList = @($argList)
    PreviewText  = ($previewParts -join " ")
  }
}

$refreshPreview = {
  try {
    $state = Get-UiState
    $errors = @(Test-UiState -State $state)
    $cmd = Build-RunCommand -State $state
    $txtCommandPreview.Text = $cmd.PreviewText
    if ($errors.Count -gt 0) {
      $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
      $lblStatus.Text = "Validation: " + ($errors -join " | ")
    }
    else {
      $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
      $lblStatus.Text = "Ready to run."
    }
  }
  catch {
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
    $lblStatus.Text = "Preview error: $($_.Exception.Message)"
  }
}

$btnRefresh.Add_Click($refreshPreview)

$btnCopy.Add_Click({
  & $refreshPreview
  try {
    [System.Windows.Forms.Clipboard]::SetText($txtCommandPreview.Text)
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    $lblStatus.Text = "Command copied to clipboard."
  }
  catch {
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
    $lblStatus.Text = "Copy failed: $($_.Exception.Message)"
  }
})

$btnRun.Add_Click({
  & $refreshPreview
  $state = Get-UiState
  $errors = @(Test-UiState -State $state)
  if ($errors.Count -gt 0) {
    [System.Windows.Forms.MessageBox]::Show(($errors -join [Environment]::NewLine), "Validation errors", "OK", "Error") | Out-Null
    return
  }

  $cmd = Build-RunCommand -State $state
  try {
    Start-Process -FilePath "powershell.exe" -ArgumentList $cmd.ArgumentList -WorkingDirectory (Split-Path -Parent $state.ScriptPath) | Out-Null
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    $lblStatus.Text = "Launched rollout script in a new PowerShell window."
  }
  catch {
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
    $lblStatus.Text = "Launch failed: $($_.Exception.Message)"
  }
})

$btnClose.Add_Click({ $form.Close() })

$allRefreshControls = @(
  $txtScriptPath, $txtName, $txtClientId, $txtDiscovery, $txtAppId, $txtExternalConfigId,
  $txtPilotGroup, $txtWrapperGroup, $txtCaPolicy, $txtBreakGlassGroupId, $txtExcludedMethods,
  $cbOffboard, $cbWhatIf, $cbConfirmFalse, $cbNoExit, $cbDisableMsAuth, $cbDisableRegCampaign,
  $cbDisableSystemPreferred, $cbRestrictMethods, $cbBulkRegister, $cbBulkSkipDisabled,
  $cbBulkIncludeGuests, $cbAuditReadiness, $cbEnforcePrereqs
)

foreach ($ctl in $allRefreshControls) {
  if ($ctl -is [System.Windows.Forms.TextBox]) {
    $ctl.Add_TextChanged($refreshPreview)
  }
  elseif ($ctl -is [System.Windows.Forms.CheckBox]) {
    $ctl.Add_CheckedChanged($refreshPreview)
  }
}

$cbOffboard.Add_CheckedChanged({
  $isOffboard = $cbOffboard.Checked
  $txtClientId.Enabled = -not $isOffboard
  $txtDiscovery.Enabled = -not $isOffboard
  $txtAppId.Enabled = -not $isOffboard
  $txtBreakGlassGroupId.Enabled = -not $isOffboard
})

$cbRestrictMethods.Add_CheckedChanged({
  $txtExcludedMethods.Enabled = $cbRestrictMethods.Checked
})

$cbBulkRegister.Add_CheckedChanged({
  $enabled = $cbBulkRegister.Checked
  $cbBulkSkipDisabled.Enabled = $enabled
  $cbBulkIncludeGuests.Enabled = $enabled
})

# Apply initial UI state
$cbOffboard.Checked = $false
$txtExcludedMethods.Enabled = $cbRestrictMethods.Checked
$cbBulkSkipDisabled.Enabled = $cbBulkRegister.Checked
$cbBulkIncludeGuests.Enabled = $cbBulkRegister.Checked

& $refreshPreview

[void]$form.ShowDialog()
