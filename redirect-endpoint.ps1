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
        
        Get-ChildItem -Path $hive -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $currentKey = $_.PSPath

            try {
                $item = Get-ItemProperty -Path $currentKey -ErrorAction Stop
            }
            catch {
                Write-Verbose "Skipping ${currentKey}: $($_.Exception.Message)"
                continue
            }

            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -like 'PS*') {
                    continue
                }

                $value = $prop.Value
                if ($null -eq $value) {
                    continue
                }

                if ($value -is [string]) {
                    if ($value -notlike "*$searchValue*") {
                        continue
                    }

                    $newValue = $value.Replace($searchValue, $replaceValue)
                    Write-Output "Found match in: $currentKey"
                    Write-Output "Property: $($prop.Name)"
                    Write-Output "Old Value: $value"
                    Write-Output "New Value: $newValue"

                    try {
                        Set-ItemProperty -Path $currentKey -Name $prop.Name -Value $newValue -ErrorAction Stop
                        Write-Output "Successfully updated value"
                    }
                    catch {
                        Write-Output "Failed to update value: $($_.Exception.Message)"
                    }
                }
                elseif ($value -is [string[]]) {
                    $needsUpdate = $false
                    $newValues = foreach ($entry in $value) {
                        if ($entry -like "*$searchValue*") {
                            $needsUpdate = $true
                            $entry.Replace($searchValue, $replaceValue)
                        }
                        else {
                            $entry
                        }
                    }

                    if (-not $needsUpdate) {
                        continue
                    }

                    Write-Output "Found match in: $currentKey"
                    Write-Output "Property: $($prop.Name)"
                    Write-Output "Old Value: $($value -join ', ')"
                    Write-Output "New Value: $($newValues -join ', ')"

                    try {
                        Set-ItemProperty -Path $currentKey -Name $prop.Name -Value $newValues -ErrorAction Stop
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

# Execute the updates
Write-Output "Starting registry update process..."
Update-RegistryValues -searchValue $oldServer1 -replaceValue $newServer1
Update-RegistryValues -searchValue $oldServer2 -replaceValue $newServer2
Update-RegistryValues -searchValue $oldServer3 -replaceValue $newServer3
Update-RegistryValues -searchValue $oldServer4 -replaceValue $newServer4
Write-Output "Registry update process completed."
