# Define the API endpoint and headers
$apiKey = "YOUR_API_KEY"
$organizationId = "YOUR_ORGANIZATION_ID"
$baseUrl = "https://api.itglue.com"
$headers = @{
    "Authorization" = "Bearer $apiKey"
    "Accept" = "application/vnd.api+json"
}

# Function to get all flexible asset types
function Get-FlexibleAssetTypes {
    $url = "$baseUrl/flexible_asset_types"
    $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers
    return $response.data
}

# Function to get the count of flexible assets for each type
function Get-FlexibleAssetCounts {
    $assetTypes = Get-FlexibleAssetTypes
    $assetCounts = @()

    foreach ($type in $assetTypes) {
        $typeId = $type.id
        $countUrl = "$baseUrl/flexible_assets?filter[flexible_asset_type]=$typeId"
        $countResponse = Invoke-RestMethod -Uri $countUrl -Method Get -Headers $headers
        $count = $countResponse.meta.total

        $assetCounts += [PSCustomObject]@{
            TypeName = $type.attributes.name
            Count    = $count
        }
    }

    return $assetCounts
}

# Get and display the counts of flexible assets
$flexibleAssetCounts = Get-FlexibleAssetCounts
$flexibleAssetCounts | Format-Table -AutoSize