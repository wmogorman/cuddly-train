[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
    [Alias('AppNames')]
    [string[]]$InputAppNames,

    [Parameter(Mandatory=$false)]
    [string]$CsvPath,

    [Parameter(Mandatory=$false)]
    [string]$CsvColumn = 'App',

    [Parameter(Mandatory=$false)]
    [ValidateSet('iOS','Android','Windows','All')]
    [string]$Platform = 'iOS',

    [Parameter(Mandatory=$false)]
    [switch]$Diagnostics
)

$AppNames = $InputAppNames
if (-not $AppNames -or $AppNames.Count -eq 0) {
    $parentVar = Get-Variable -Name 'appNames' -Scope 1 -ErrorAction SilentlyContinue
    if ($parentVar -and $parentVar.Value) {
        $AppNames = $parentVar.Value
    }
}

if ($CsvPath) {
    if (-not (Test-Path -Path $CsvPath)) {
        throw "CSV file not found: $CsvPath"
    }

    $csvRows = Import-Csv -Path $CsvPath
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "CSV file is empty: $CsvPath"
    }

    $headers = $csvRows[0].PSObject.Properties.Name
    $columnName = $headers |
        Where-Object { $_.Equals($CsvColumn, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1

    if (-not $columnName) {
        throw "CSV column '$CsvColumn' not found. Columns: $($headers -join ', ')"
    }

    $csvNames = @($csvRows |
        ForEach-Object { $_.$columnName } |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    $merged = New-Object System.Collections.Generic.List[string]
    if ($AppNames) {
        foreach ($name in $AppNames) {
            if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                $merged.Add([string]$name)
            }
        }
    }
    foreach ($name in $csvNames) {
        $merged.Add([string]$name)
    }

    $AppNames = $merged.ToArray()
}

if (-not $AppNames -or $AppNames.Count -eq 0) {
    throw 'Missing app names. Provide -AppNames, set $appNames, or use -CsvPath.'
}

function Normalize-AppName {
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $normalized = $Name.Trim()
    $normalized = $normalized -replace '\s+', ' '
    return $normalized.ToLowerInvariant()
}

function Format-AppLabel {
    param(
        $App
    )

    if (-not $App) {
        return ''
    }

    return "{0} (Id: {1})" -f $App.DisplayName, $App.Id
}

function Get-AssignmentIntent {
    param(
        $Assignment
    )

    if (-not $Assignment) {
        return $null
    }

    $intent = $Assignment.Intent
    if (-not $intent -and $Assignment.PSObject.Properties['intent']) {
        $intent = $Assignment.intent
    }

    if ([string]::IsNullOrWhiteSpace([string]$intent)) {
        return $null
    }

    return ([string]$intent).Trim().ToLowerInvariant()
}

function Get-AssignmentTargetType {
    param(
        $Assignment
    )

    if (-not $Assignment -or -not $Assignment.Target) {
        return $null
    }

    $target = $Assignment.Target

    if ($target.PSObject.Properties['@odata.type'] -and $target.'@odata.type') {
        return [string]$target.'@odata.type'
    }

    if ($target.PSObject.Properties['AdditionalProperties'] -and $target.AdditionalProperties) {
        if ($target.AdditionalProperties.ContainsKey('@odata.type')) {
            return [string]$target.AdditionalProperties['@odata.type']
        }
        if ($target.AdditionalProperties.ContainsKey('odata.type')) {
            return [string]$target.AdditionalProperties['odata.type']
        }
    }

    if ($target.PSObject.Properties['OdataType'] -and $target.OdataType) {
        return [string]$target.OdataType
    }

    return $null
}

function Match-AppPlatform {
    param(
        $App,
        [string]$Platform
    )

    if ($Platform -eq 'All') {
        return $true
    }

    $type = [string]$App.'@odata.type'
    if ([string]::IsNullOrWhiteSpace($type)) {
        return $false
    }

    switch ($Platform) {
        'iOS' { return $type -match 'ios' }
        'Android' { return $type -match 'android' }
        'Windows' { return $type -match 'windows|win32' }
        'All' { return $true }
        default { return $false }
    }
}

# Get all apps and then filter by platform
$allApps = @(Get-MgDeviceAppManagementMobileApp -All)
if ($Platform -eq 'All') {
    $platformApps = @($allApps | Where-Object { $_.DisplayName })
}
else {
    $platformApps = @($allApps | Where-Object {
        $_.DisplayName -and (Match-AppPlatform -App $_ -Platform $Platform)
    })
}

if (-not $platformApps -or $platformApps.Count -eq 0) {
    if ($Diagnostics -and $allApps.Count -gt 0) {
        $sample = $allApps | Select-Object -First 10 DisplayName, '@odata.type'
        Write-Host "DIAG: Sample apps returned by Graph (first 10):"
        $sample | ForEach-Object { Write-Host ("DIAG: {0} | {1}" -f $_.DisplayName, $_.'@odata.type') }
    }

    throw ("No apps found for Platform '{0}'. Total apps returned: {1}. Try -Platform All or check Graph connection and permissions." -f $Platform, $allApps.Count)
}

$normalizedApps = @()
$appsByNormalized = @{}
foreach ($app in $platformApps) {
    $norm = Normalize-AppName -Name $app.DisplayName
    if (-not $norm) {
        continue
    }

    $normalizedApps += [PSCustomObject]@{
        App      = $app
        NameNorm = $norm
    }

    if (-not $appsByNormalized.ContainsKey($norm)) {
        $appsByNormalized[$norm] = @()
    }
    $appsByNormalized[$norm] += $app
}

$expandedNames = New-Object System.Collections.Generic.List[string]
foreach ($name in $AppNames) {
    if ([string]::IsNullOrWhiteSpace($name)) {
        continue
    }

    if ($name -match ',') {
        foreach ($part in ($name -split ',')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $expandedNames.Add($part.Trim())
            }
        }
    }
    else {
        $expandedNames.Add($name.Trim())
    }
}

$processedAppIds = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($inputName in $expandedNames) {
    if ([string]::IsNullOrWhiteSpace($inputName)) {
        continue
    }

    $inputNorm = Normalize-AppName -Name $inputName
    $app = $null

    if ($inputNorm -and $appsByNormalized.ContainsKey($inputNorm)) {
        $exactMatches = $appsByNormalized[$inputNorm]
        if ($exactMatches.Count -eq 1) {
            $app = $exactMatches[0]
        }
        else {
            $labels = ($exactMatches | ForEach-Object { Format-AppLabel -App $_ }) -join '; '
            Write-Warning "Multiple apps match exact name '$inputName'. Matches: $labels"
            continue
        }
    }
    else {
        $pattern = $null
        if ($inputName -match '[*?]') {
            $pattern = $inputName
            $partialMatches = @($normalizedApps |
                Where-Object { $_.App.DisplayName -like $pattern } |
                Select-Object -ExpandProperty App)
        }
        else {
            $pattern = "*$inputNorm*"
            $partialMatches = @($normalizedApps |
                Where-Object { $_.NameNorm -like $pattern } |
                Select-Object -ExpandProperty App)
        }

        if ($partialMatches.Count -eq 1) {
            $app = $partialMatches[0]
            Write-Warning "No exact match for '$inputName'. Using partial match '$($app.DisplayName)'."
        }
        elseif ($partialMatches.Count -gt 1) {
            $labels = ($partialMatches | ForEach-Object { Format-AppLabel -App $_ }) -join '; '
            Write-Warning "Multiple apps match '$inputName' (pattern '$pattern'). Be more specific. Matches: $labels"
            continue
        }
    }

    if (-not $app) {
        Write-Warning "App not found: $inputName"
        continue
    }

    if ($processedAppIds.Contains([string]$app.Id)) {
        Write-Host "Skipping duplicate app in this run: $($app.DisplayName)"
        continue
    }
    [void]$processedAppIds.Add([string]$app.Id)

    # Check existing assignments
    $assignments = @(Get-MgDeviceAppManagementMobileAppAssignment `
        -MobileAppId $app.Id `
        -All)

    $allUsersAssignments = @($assignments | Where-Object {
        (Get-AssignmentTargetType -Assignment $_) -eq '#microsoft.graph.allLicensedUsersAssignmentTarget'
    })

    $alreadyAssigned = @($allUsersAssignments | Where-Object {
        (Get-AssignmentIntent -Assignment $_) -eq 'available'
    })

    if ($alreadyAssigned.Count -gt 0) {
        Write-Host "Already available to all users: $inputName"
        continue
    }

    if ($allUsersAssignments.Count -gt 0) {
        $assignmentToUpdate = $allUsersAssignments[0]
        $assignmentId = [string]$assignmentToUpdate.Id

        if ([string]::IsNullOrWhiteSpace($assignmentId)) {
            Write-Warning "All Users assignment found for '$($app.DisplayName)' but assignment id is missing. Skipping."
            continue
        }

        $updateTarget = "{0} (Id: {1}) assignment {2}" -f $app.DisplayName, $app.Id, $assignmentId
        if ($PSCmdlet.ShouldProcess($updateTarget, 'Update existing All Users assignment intent -> available')) {
            try {
                Update-MgDeviceAppManagementMobileAppAssignment `
                    -MobileAppId $app.Id `
                    -MobileAppAssignmentId $assignmentId `
                    -BodyParameter @{ intent = 'available' } | Out-Null
                Write-Host "Updated existing All Users assignment to available: $inputName"
            }
            catch {
                Write-Warning "Failed to update existing assignment for '$($app.DisplayName)': $($_.Exception.Message)"
            }
        }
        continue
    }

    Write-Host "Assigning Available -> All Users: $inputName"

    $assignment = @{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = 'available'
        target        = @{
            '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget'
        }
    }

    $target = "{0} (Id: {1})" -f $app.DisplayName, $app.Id
    if ($PSCmdlet.ShouldProcess($target, 'Assign Available -> All Users')) {
        try {
            New-MgDeviceAppManagementMobileAppAssignment `
                -MobileAppId $app.Id `
                -BodyParameter $assignment | Out-Null
        }
        catch {
            if ($_.Exception.Message -match 'already exists') {
                Write-Host "Assignment already exists (server-side check): $inputName"
            }
            else {
                throw
            }
        }
    }
}
