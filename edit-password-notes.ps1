# Define your IT Glue base URI
$ITGlueAPIKey = $env:ITGlueKey
$headers = @{
    "x-api-key" = $ITGlueAPIKey
    "Content-Type" = "application/vnd.api+json"
}
$baseUri = "https://api.itglue.com"

# List of PasswordIDs you want to check
$PasswordIDs = @(
    12345,
    67890,
    24680
)

foreach ($id in $PasswordIDs) {
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
    $cleanedNotes = $notes -replace '(?i)password.*', ''

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
