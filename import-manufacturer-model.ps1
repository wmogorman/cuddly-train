<#
.SYNOPSIS
  Import manufacturer/model values from CSV into IT Glue configurations by UUID (or RMM ID).

.DESCRIPTION
  Reads a CSV with columns such as DeviceUID, Manufacturer, and Device Model (or Model).
  For each row, finds the configuration by filter[asset_tag], filter[uuid], or
  filter[rmm_id] + filter[rmm_integration_type] (controlled by -MatchMode),
  then updates manufacturer/model. Missing manufacturers/models can be created.

.PARAMETER ApiKey
  IT Glue API key. Defaults to $env:ITGlueKey for Datto RMM compatibility.

.PARAMETER CsvPath
  Path to the CSV file to import.

.PARAMETER MatchMode
  How to match DeviceUID to IT Glue configuration: AssetTag, Uuid, Rmm,
  AssetTagThenUuid, AssetTagThenRmm, UuidThenRmm, or RmmThenUuid.
  Default: AssetTag.

.PARAMETER RmmIntegrationType
  RMM integration type for filter[rmm_integration_type]. Default: aem (Datto RMM).

.PARAMETER CreateMissingManufacturers
  When true, create manufacturers that do not exist. Default: $true.

.PARAMETER CreateMissingModels
  When true, create models that do not exist for a manufacturer. Default: $true.

.PARAMETER ReportPath
  CSV path for the import report. Default: C:\itglue-manufacturer-model-import.csv

.PARAMETER BaseUri
  Base API URL. Default: https://api.itglue.com.

.PARAMETER PageSize
  Number of records to pull per request. Default: 100.

.EXAMPLE
  PowerShell (no profile), 64-bit:
    -Command "& { . .\import-manufacturer-model.ps1 -CsvPath C:\temp\devices.csv -WhatIf }"

.EXAMPLE
  PowerShell (no profile), 64-bit:
    -Command "& { . .\import-manufacturer-model.ps1 -CsvPath C:\temp\devices.csv -MatchMode AssetTag -Verbose }"
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$false)]
  [string]$ApiKey = $env:ITGlueKey,

  [Parameter(Mandatory=$true)]
  [string]$CsvPath,

  [Parameter(Mandatory=$false)]
  [ValidateSet('AssetTag','Uuid','Rmm','AssetTagThenUuid','AssetTagThenRmm','UuidThenRmm','RmmThenUuid')]
  [string]$MatchMode = 'AssetTag',

  [Parameter(Mandatory=$false)]
  [string]$RmmIntegrationType = 'aem',

  [Parameter(Mandatory=$false)]
  [bool]$CreateMissingManufacturers = $true,

  [Parameter(Mandatory=$false)]
  [bool]$CreateMissingModels = $true,

  [Parameter(Mandatory=$false)]
  [string]$ReportPath = 'C:\itglue-manufacturer-model-import.csv',

  [Parameter(Mandatory=$false)]
  [string]$BaseUri = 'https://api.itglue.com',

  [Parameter(Mandatory=$false)]
  [ValidateRange(1,1000)]
  [int]$PageSize = 100
)

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
  throw 'Missing API key. Pass -ApiKey or set env var ITGlueKey.'
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
  throw 'CsvPath cannot be empty.'
}

if (-not (Test-Path -Path $CsvPath)) {
  throw "CSV file not found: $CsvPath"
}

$BaseUri = $BaseUri.TrimEnd('/')

function Invoke-ITGlueRequest {
  param(
    [Parameter(Mandatory=$true)] [string]$Uri,
    [Parameter(Mandatory=$true)] [string]$Method,
    [hashtable]$Headers,
    $Body,
    [string]$ContentType
  )

  $invokeParams = @{
    Uri         = $Uri
    Method      = $Method
    Headers     = $Headers
    ErrorAction = 'Stop'
  }

  if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
    $invokeParams['Body'] = $Body
  }

  if ($PSBoundParameters.ContainsKey('ContentType') -and -not [string]::IsNullOrWhiteSpace($ContentType)) {
    $invokeParams['ContentType'] = $ContentType
  }

  try {
    Invoke-RestMethod @invokeParams
  }
  catch {
    $message = $_.Exception.Message
    if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
      $message = "{0} Response: {1}" -f $message, $_.ErrorDetails.Message
    }
    try {
      if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $bodyText = $reader.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
          $message = "{0} Response: {1}" -f $message, $bodyText
        }
      }
    }
    catch {
    }
    if ($_.Exception.Response -and $_.Exception.Response.ResponseUri) {
      $message = "{0} (URI: {1})" -f $message, $_.Exception.Response.ResponseUri
    }
    throw (New-Object System.Exception("IT Glue request failed: $message", $_.Exception))
  }
}

function Resolve-ColumnName {
  param(
    [string[]]$Headers,
    [string[]]$Candidates
  )

  foreach ($candidate in $Candidates) {
    $match = $Headers | Where-Object { $_.Equals($candidate, [System.StringComparison]::OrdinalIgnoreCase) }
    if ($match -and $match.Count -gt 0) {
      return [string]$match[0]
    }
  }

  return $null
}

function Get-ITGlueConfigurationByRmmId {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$RmmId,
    [string]$RmmIntegrationType,
    [int]$PageSize
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $encodedRmmId = [System.Uri]::EscapeDataString([string]$RmmId)
  $encodedType = [System.Uri]::EscapeDataString([string]$RmmIntegrationType)
  $uri = '{0}/configurations?filter[rmm_id]={1}&filter[rmm_integration_type]={2}&page[size]={3}' -f $BaseUri, $encodedRmmId, $encodedType, $PageSize

  $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
  return $response.data
}

function Get-ITGlueConfigurationByUuid {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$Uuid,
    [int]$PageSize
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $encodedUuid = [System.Uri]::EscapeDataString([string]$Uuid)
  $uri = '{0}/configurations?filter[uuid]={1}&page[size]={2}' -f $BaseUri, $encodedUuid, $PageSize

  $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
  return $response.data
}

function Get-ITGlueConfigurationByAssetTag {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$AssetTag,
    [int]$PageSize
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $encodedTag = [System.Uri]::EscapeDataString([string]$AssetTag)
  $uri = '{0}/configurations?filter[asset_tag]={1}&page[size]={2}' -f $BaseUri, $encodedTag, $PageSize
  $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
  if ($response.data -and $response.data.Count -gt 0) {
    return $response.data
  }

  $uriAlt = '{0}/configurations?filter[asset-tag]={1}&page[size]={2}' -f $BaseUri, $encodedTag, $PageSize
  $responseAlt = Invoke-ITGlueRequest -Uri $uriAlt -Method 'GET' -Headers $headers
  return $responseAlt.data
}

function Get-ITGlueManufacturerByName {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$Name
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $encodedName = [System.Uri]::EscapeDataString([string]$Name)
  $uri = '{0}/manufacturers?filter[name]={1}' -f $BaseUri, $encodedName
  $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
  return $response.data
}

function New-ITGlueManufacturer {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$Name
  )

  $headers = @{
    'x-api-key'    = $ApiKey
    'Accept'       = 'application/vnd.api+json'
    'Content-Type' = 'application/vnd.api+json'
  }

  $body = @{
    data = @{
      type       = 'manufacturers'
      attributes = @{
        name = $Name
      }
    }
  } | ConvertTo-Json -Depth 5

  $uri = '{0}/manufacturers' -f $BaseUri
  return Invoke-ITGlueRequest -Uri $uri -Method 'POST' -Headers $headers -Body $body -ContentType 'application/vnd.api+json'
}

function Get-ITGlueModelsForManufacturer {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$ManufacturerId,
    [int]$PageSize
  )

  $headers = @{
    'x-api-key' = $ApiKey
    'Accept'    = 'application/vnd.api+json'
  }

  $uri = '{0}/manufacturers/{1}/relationships/models?page[size]={2}' -f $BaseUri, [System.Uri]::EscapeDataString([string]$ManufacturerId), $PageSize
  $results = @()

  while ($true) {
    $response = Invoke-ITGlueRequest -Uri $uri -Method 'GET' -Headers $headers
    if ($response.data) {
      $results += $response.data
    }

    if (-not $response.links -or [string]::IsNullOrWhiteSpace([string]$response.links.next)) {
      break
    }

    $uri = [string]$response.links.next
  }

  return $results
}

function New-ITGlueModel {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$Name,
    [string]$ManufacturerId
  )

  $headers = @{
    'x-api-key'    = $ApiKey
    'Accept'       = 'application/vnd.api+json'
    'Content-Type' = 'application/vnd.api+json'
  }

  $body = @{
    data = @{
      type       = 'models'
      attributes = @{
        name               = $Name
        'manufacturer-id' = [string]$ManufacturerId
      }
    }
  } | ConvertTo-Json -Depth 5

  $uri = '{0}/models' -f $BaseUri
  return Invoke-ITGlueRequest -Uri $uri -Method 'POST' -Headers $headers -Body $body -ContentType 'application/vnd.api+json'
}

function Update-ITGlueConfiguration {
  param(
    [string]$ApiKey,
    [string]$BaseUri,
    [string]$ItemId,
    [hashtable]$Attributes
  )

  if (-not $Attributes -or $Attributes.Count -eq 0) {
    return
  }

  $headers = @{
    'x-api-key'    = $ApiKey
    'Accept'       = 'application/vnd.api+json'
    'Content-Type' = 'application/vnd.api+json'
  }

  $body = @{
    data = @{
      type       = 'configurations'
      id         = [string]$ItemId
      attributes = $Attributes
    }
  } | ConvertTo-Json -Depth 6

  $uri = '{0}/configurations/{1}' -f $BaseUri, [System.Uri]::EscapeDataString([string]$ItemId)
  Invoke-ITGlueRequest -Uri $uri -Method 'PATCH' -Headers $headers -Body $body -ContentType 'application/vnd.api+json'
}

$csvRows = Import-Csv -Path $CsvPath
if (-not $csvRows -or $csvRows.Count -eq 0) {
  throw 'CSV file is empty.'
}

$headers = $csvRows[0].PSObject.Properties.Name
$deviceIdColumn = Resolve-ColumnName -Headers $headers -Candidates @('DeviceUID','Device UID','Device Id','DeviceID','UID')
$manufacturerColumn = Resolve-ColumnName -Headers $headers -Candidates @('Manufacturer','Make','Vendor')
$modelColumn = Resolve-ColumnName -Headers $headers -Candidates @('Device Model','DeviceModel','Model','Product Model')

if (-not $deviceIdColumn) {
  throw "Missing DeviceUID column. Found columns: $($headers -join ', ')"
}
if (-not $manufacturerColumn) {
  throw "Missing Manufacturer column. Found columns: $($headers -join ', ')"
}
if (-not $modelColumn) {
  throw "Missing Device Model/Model column. Found columns: $($headers -join ', ')"
}

$manufacturerCache = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
$modelsByManufacturer = @{}
$configurationCache = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)

$report = New-Object System.Collections.Generic.List[object]
$updated = 0
$skipped = 0
$failed = 0
$createdManufacturers = 0
$createdModels = 0

foreach ($row in $csvRows) {
  $deviceUid = [string]$row.$deviceIdColumn
  $manufacturerName = [string]$row.$manufacturerColumn
  $modelName = [string]$row.$modelColumn

  $deviceUid = $deviceUid.Trim()
  $manufacturerName = $manufacturerName.Trim()
  $modelName = $modelName.Trim()

  if ([string]::IsNullOrWhiteSpace($deviceUid) -or
      [string]::IsNullOrWhiteSpace($manufacturerName) -or
      [string]::IsNullOrWhiteSpace($modelName)) {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $null
      ConfigurationName = $null
      Status            = 'Skipped'
      Message           = 'Missing DeviceUID, Manufacturer, or Model value.'
    })
    continue
  }

  $configKey = "$MatchMode|$($deviceUid.ToLowerInvariant())"
  $configData = $null
  $matchSource = $null

  if ($configurationCache.ContainsKey($configKey)) {
    $cached = $configurationCache[$configKey]
    $configData = $cached.Data
    $matchSource = $cached.Source
  }
  else {
    switch ($MatchMode) {
      'AssetTag' {
        $configData = Get-ITGlueConfigurationByAssetTag -ApiKey $ApiKey -BaseUri $BaseUri -AssetTag $deviceUid -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) { $matchSource = 'AssetTag' }
      }
      'Uuid' {
        $configData = Get-ITGlueConfigurationByUuid -ApiKey $ApiKey -BaseUri $BaseUri -Uuid $deviceUid -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) { $matchSource = 'Uuid' }
      }
      'Rmm' {
        $configData = Get-ITGlueConfigurationByRmmId -ApiKey $ApiKey -BaseUri $BaseUri -RmmId $deviceUid -RmmIntegrationType $RmmIntegrationType -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) { $matchSource = 'Rmm' }
      }
      'AssetTagThenUuid' {
        $configData = Get-ITGlueConfigurationByAssetTag -ApiKey $ApiKey -BaseUri $BaseUri -AssetTag $deviceUid -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) {
          $matchSource = 'AssetTag'
        }
        else {
          $configData = Get-ITGlueConfigurationByUuid -ApiKey $ApiKey -BaseUri $BaseUri -Uuid $deviceUid -PageSize $PageSize
          if ($configData -and $configData.Count -gt 0) { $matchSource = 'Uuid' }
        }
      }
      'AssetTagThenRmm' {
        $configData = Get-ITGlueConfigurationByAssetTag -ApiKey $ApiKey -BaseUri $BaseUri -AssetTag $deviceUid -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) {
          $matchSource = 'AssetTag'
        }
        else {
          $configData = Get-ITGlueConfigurationByRmmId -ApiKey $ApiKey -BaseUri $BaseUri -RmmId $deviceUid -RmmIntegrationType $RmmIntegrationType -PageSize $PageSize
          if ($configData -and $configData.Count -gt 0) { $matchSource = 'Rmm' }
        }
      }
      'UuidThenRmm' {
        $configData = Get-ITGlueConfigurationByUuid -ApiKey $ApiKey -BaseUri $BaseUri -Uuid $deviceUid -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) {
          $matchSource = 'Uuid'
        }
        else {
          $configData = Get-ITGlueConfigurationByRmmId -ApiKey $ApiKey -BaseUri $BaseUri -RmmId $deviceUid -RmmIntegrationType $RmmIntegrationType -PageSize $PageSize
          if ($configData -and $configData.Count -gt 0) { $matchSource = 'Rmm' }
        }
      }
      'RmmThenUuid' {
        $configData = Get-ITGlueConfigurationByRmmId -ApiKey $ApiKey -BaseUri $BaseUri -RmmId $deviceUid -RmmIntegrationType $RmmIntegrationType -PageSize $PageSize
        if ($configData -and $configData.Count -gt 0) {
          $matchSource = 'Rmm'
        }
        else {
          $configData = Get-ITGlueConfigurationByUuid -ApiKey $ApiKey -BaseUri $BaseUri -Uuid $deviceUid -PageSize $PageSize
          if ($configData -and $configData.Count -gt 0) { $matchSource = 'Uuid' }
        }
      }
    }

    $configurationCache[$configKey] = [PSCustomObject]@{
      Data   = $configData
      Source = $matchSource
    }
  }

  if (-not $configData -or $configData.Count -eq 0) {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $null
      ConfigurationName = $null
      Status            = 'Skipped'
      Message           = "No configuration found for DeviceUID $deviceUid using MatchMode $MatchMode."
    })
    continue
  }

  if ($configData.Count -gt 1) {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $null
      ConfigurationName = $null
      Status            = 'Skipped'
      Message           = "Multiple configurations found for DeviceUID $deviceUid using MatchMode $MatchMode. Skipping to avoid ambiguity."
    })
    continue
  }

  $config = $configData[0]
  $configName = [string]$config.attributes.name
  $configId = [string]$config.id

  $manufacturerId = $null
  if ($manufacturerCache.ContainsKey($manufacturerName)) {
    $manufacturerId = $manufacturerCache[$manufacturerName]
  }
  else {
    $existingManufacturer = Get-ITGlueManufacturerByName -ApiKey $ApiKey -BaseUri $BaseUri -Name $manufacturerName
    if ($existingManufacturer -and $existingManufacturer.Count -gt 0) {
      $manufacturerId = [string]$existingManufacturer[0].id
      $manufacturerCache[$manufacturerName] = $manufacturerId
    }
  }

  $manufacturerCreatePrevented = $false
  if (-not $manufacturerId -and $CreateMissingManufacturers) {
    if ($PSCmdlet.ShouldProcess("Manufacturer '$manufacturerName'", 'Create')) {
      try {
        $created = New-ITGlueManufacturer -ApiKey $ApiKey -BaseUri $BaseUri -Name $manufacturerName
        if ($created -and $created.data) {
          $manufacturerId = [string]$created.data.id
          $manufacturerCache[$manufacturerName] = $manufacturerId
          $createdManufacturers++
        }
      }
      catch {
        $failed++
        $report.Add([PSCustomObject]@{
          DeviceUID         = $deviceUid
          Manufacturer      = $manufacturerName
          Model             = $modelName
          ConfigurationId   = $configId
          ConfigurationName = $configName
          Status            = 'Failed'
          Message           = "Failed to create manufacturer '$manufacturerName': $($_.Exception.Message)"
        })
        continue
      }
    }
    else {
      $manufacturerCreatePrevented = $true
    }
  }

  if (-not $manufacturerId) {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $configId
      ConfigurationName = $configName
      Status            = 'Skipped'
      Message           = $(if ($manufacturerCreatePrevented) { 'WhatIf/Confirm prevented manufacturer creation.' } else { "Manufacturer '$manufacturerName' not found." })
    })
    continue
  }

  $modelsLookup = $null
  if ($modelsByManufacturer.ContainsKey($manufacturerId)) {
    $modelsLookup = $modelsByManufacturer[$manufacturerId]
  }
  else {
    $modelsLookup = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $models = Get-ITGlueModelsForManufacturer -ApiKey $ApiKey -BaseUri $BaseUri -ManufacturerId $manufacturerId -PageSize $PageSize
    foreach ($model in $models) {
      $modelNameValue = [string]$model.attributes.name
      if (-not [string]::IsNullOrWhiteSpace($modelNameValue)) {
        $modelsLookup[$modelNameValue] = [string]$model.id
      }
    }
    $modelsByManufacturer[$manufacturerId] = $modelsLookup
  }

  $modelId = $null
  if ($modelsLookup.ContainsKey($modelName)) {
    $modelId = $modelsLookup[$modelName]
  }

  $modelCreatePrevented = $false
  if (-not $modelId -and $CreateMissingModels) {
    if ($PSCmdlet.ShouldProcess("Model '$modelName' for manufacturer '$manufacturerName'", 'Create')) {
      try {
        $createdModel = New-ITGlueModel -ApiKey $ApiKey -BaseUri $BaseUri -Name $modelName -ManufacturerId $manufacturerId
        if ($createdModel -and $createdModel.data) {
          $modelId = [string]$createdModel.data.id
          $modelsLookup[$modelName] = $modelId
          $createdModels++
        }
      }
      catch {
        $failed++
        $report.Add([PSCustomObject]@{
          DeviceUID         = $deviceUid
          Manufacturer      = $manufacturerName
          Model             = $modelName
          ConfigurationId   = $configId
          ConfigurationName = $configName
          Status            = 'Failed'
          Message           = "Failed to create model '$modelName': $($_.Exception.Message)"
        })
        continue
      }
    }
    else {
      $modelCreatePrevented = $true
    }
  }

  if (-not $modelId) {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $configId
      ConfigurationName = $configName
      Status            = 'Skipped'
      Message           = $(if ($modelCreatePrevented) { 'WhatIf/Confirm prevented model creation.' } else { "Model '$modelName' not found for manufacturer '$manufacturerName'." })
    })
    continue
  }

  $currentManufacturerId = [string]$config.attributes.'manufacturer-id'
  $currentModelId = [string]$config.attributes.'model-id'

  $attributesToUpdate = @{}
  if ($currentManufacturerId -ne $manufacturerId) {
    $attributesToUpdate['manufacturer-id'] = $manufacturerId
  }
  if ($currentModelId -ne $modelId) {
    $attributesToUpdate['model-id'] = $modelId
  }

  if ($attributesToUpdate.Count -eq 0) {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $configId
      ConfigurationName = $configName
      Status            = 'Skipped'
      Message           = 'Configuration already has matching manufacturer/model.'
    })
    continue
  }

  $target = '{0} ({1})' -f $configName, $configId
  if ($PSCmdlet.ShouldProcess($target, "Update manufacturer/model")) {
    try {
      Update-ITGlueConfiguration -ApiKey $ApiKey -BaseUri $BaseUri -ItemId $configId -Attributes $attributesToUpdate
      $updated++
      $report.Add([PSCustomObject]@{
        DeviceUID         = $deviceUid
        Manufacturer      = $manufacturerName
        Model             = $modelName
        ConfigurationId   = $configId
        ConfigurationName = $configName
        Status            = 'Updated'
      Message           = $(if ($matchSource) { "Manufacturer/model updated (matched by $matchSource)." } else { 'Manufacturer/model updated.' })
    })
    }
    catch {
      $message = $_.Exception.Message
      if ($message -match 'synced resource|externally synced') {
        $skipped++
        $report.Add([PSCustomObject]@{
          DeviceUID         = $deviceUid
          Manufacturer      = $manufacturerName
          Model             = $modelName
          ConfigurationId   = $configId
          ConfigurationName = $configName
          Status            = 'Skipped'
          Message           = 'Update blocked by IT Glue sync rules.'
        })
      }
      else {
        $failed++
        $report.Add([PSCustomObject]@{
          DeviceUID         = $deviceUid
          Manufacturer      = $manufacturerName
          Model             = $modelName
          ConfigurationId   = $configId
          ConfigurationName = $configName
          Status            = 'Failed'
          Message           = $message
        })
      }
    }
  }
  else {
    $skipped++
    $report.Add([PSCustomObject]@{
      DeviceUID         = $deviceUid
      Manufacturer      = $manufacturerName
      Model             = $modelName
      ConfigurationId   = $configId
      ConfigurationName = $configName
      Status            = 'Skipped'
      Message           = 'WhatIf/Confirm prevented update.'
    })
  }
}

if ($report.Count -gt 0) {
  $report | Export-Csv -Path $ReportPath -NoTypeInformation
}

Write-Host ("Updated {0} configuration(s). Skipped {1}. Failed {2}. Manufacturers created {3}. Models created {4}. Report: {5}" -f `
  $updated, $skipped, $failed, $createdManufacturers, $createdModels, $ReportPath)
