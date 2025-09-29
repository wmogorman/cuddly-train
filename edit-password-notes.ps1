[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$IdCsvPath,

    [Parameter(Mandatory = $false)]
    [string[]]$PwAssetIds
)

# Allow IDs to be supplied directly or via CSV when running in RMM
$PasswordIdList = @()

if ($PwAssetIds) {
    $PasswordIdList += $PwAssetIds
}

if ($IdCsvPath) {
    if (-not (Test-Path -LiteralPath $IdCsvPath)) {
        throw "ID CSV path '$IdCsvPath' was not found."
    }

    $csvRows = Import-Csv -Path $IdCsvPath

    if (-not $csvRows) {
        throw "ID CSV '$IdCsvPath' is empty or could not be read."
    }

    foreach ($row in $csvRows) {
        $candidate = $row.PasswordID
        if (-not $candidate) {
            $candidate = $row.PasswordId
        }

        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $PasswordIdList += $candidate
        }
    }
}

$PasswordIdList = @(
    $PasswordIdList |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
)

if (-not $PasswordIdList) {
    throw "No Password IDs supplied. Use -PwAssetIds or provide a CSV with a 'PasswordID' column."
}

# Define your IT Glue base URI
$ITGlueAPIKey = $env:ITGlueKey
$headers = @{
    "x-api-key"  = $ITGlueAPIKey
    "Content-Type" = "application/vnd.api+json"
}
$baseUri = "https://api.itglue.com"

foreach ($id in $PasswordIdList) {
    $id = $id.Trim()
    Write-Host "Processing PasswordID $id..."

    # Get password record
    $uri = "$baseUri/passwords/$id"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers

    $notes = $response.data.attributes.notes

    if ([string]::IsNullOrWhiteSpace($notes)) {
        Write-Host "No notes found for PasswordID $id"
        continue
    }

    # Remove 'password' and everything following it on the same line
    $cleanedNotes = $notes -replace '(?i)(?:old\s+)?password.*', ''

    if ($cleanedNotes -ne $notes) {
        Write-Host "Cleaning notes for PasswordID $id..."

        $body = @{
            data = @{
                type = "passwords"
                id   = "$id"
                attributes = @{
                    notes = $cleanedNotes.Trim()
                }
            }
        } | ConvertTo-Json -Depth 10

        # Update record
        Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body
    }
    else {
        Write-Host "No 'password' text found in notes for PasswordID $id"
    }
}

