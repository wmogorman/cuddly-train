# Requires: PowerShell 7+, IT Glue API Key

# Set your IT Glue API Key
$ApiKey = "YOUR_ITGLUE_API_KEY"
$BaseUri = "https://api.itglue.com"
$OrgId = "YOUR_ORG_ID" # Set your organization ID

# Function to get all passwords for the organization
function Get-ITGluePasswords {
    $headers = @{
        "x-api-key" = $ApiKey
        "Accept"    = "application/vnd.api+json"
    }
    $uri = "$BaseUri/organizations/$OrgId/passwords?page[size]=1000"
    $results = @()
    do {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $results += $response.data
        $uri = $response.links.next
    } while ($uri)
    return $results
}

# Function to check if description contains possible password patterns
function Test-DescriptionForPassword {
    param($description)
    if ([string]::IsNullOrWhiteSpace($description)) { return $false }
    # Simple patterns: "password is", "pwd:", "pass=", etc.
    $patterns = @(
        "password\s*is\s*[:=]?\s*\S+",
        "pwd\s*[:=]?\s*\S+",
        "pass\s*[:=]?\s*\S+",
        "pw\s*[:=]?\s*\S+"
    )
    foreach ($pattern in $patterns) {
        if ($description -match $pattern) { return $true }
    }
    return $false
}

# Main logic
$passwords = Get-ITGluePasswords
$report = @()

foreach ($pw in $passwords) {
    $desc = $pw.attributes.description
    if (Test-DescriptionForPassword $desc) {
        $report += [PSCustomObject]@{
            PasswordName = $pw.attributes.name
            Description  = $desc
            PasswordID   = $pw.id
        }
    }
}

# Output report to CSV
$report | Export-Csv -Path "./itglue-passwords-to-investigate.csv" -NoTypeInformation

Write-Host "Report generated: itglue-passwords-to-investigate.csv"