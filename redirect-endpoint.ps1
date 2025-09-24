# Define old and new values
$oldServer1 = "BBM-EVO01"
$oldServer2 = "10.0.1.4"
$newServer1 = "BBM-EVO02"
$newServer2 = "10.0.1.11"
$oldServer3 = "BBM-FP01"
$oldServer4 = "10.0.1.3"
$newServer3 = "BBM-DC01"
$newServer4 = "10.0.1.6"

# Function to search and replace values in registry
function Update-RegistryValues {
    param (
        [string]$searchValue,
        [string]$replaceValue
    )
    
    # Registry hives to search
    $registryHives = @(
        "HKLM:\SOFTWARE",
        "HKCU:\SOFTWARE"
    )

    foreach ($hive in $registryHives) {
        Write-Output "Searching in $hive..."
        
        # Get all string values recursively
        Get-ChildItem -Path $hive -Recurse -ErrorAction SilentlyContinue | 
        ForEach-Object {
            $currentKey = $_.PSPath
            Get-ItemProperty -Path $currentKey -ErrorAction SilentlyContinue |
            Select-Object * -ExcludeProperty PS* |
            ForEach-Object {
                $properties = $_.PSObject.Properties
                foreach ($prop in $properties) {
                    if ($prop.Value -is [string] -and $prop.Value -like "*$searchValue*") {
                        $newValue = $prop.Value.Replace($searchValue, $replaceValue)
                        Write-Output "Found match in: $currentKey"
                        Write-Output "Property: $($prop.Name)"
                        Write-Output "Old Value: $($prop.Value)"
                        Write-Output "New Value: $newValue"
                        
                        try {
                            Set-ItemProperty -Path $currentKey -Name $prop.Name -Value $newValue -ErrorAction Stop
                            Write-Output "Successfully updated value"
                        }
                        catch {
                            Write-Output "Failed to update value: $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
    }
}

# Execute the updates
Write-Output "Starting registry update process..."
Update-RegistryValues -searchValue $oldServer1 -replaceValue $newServer1
Update-RegistryValues -searchValue $oldServer2 -replaceValue $newServer2
Update-RegistryValues -searchValue $oldServer3 -replaceValue $newServer3
Update-RegistryValues -searchValue $oldServer4 -replaceValue $newServer4
Write-Output "Registry update process completed."

