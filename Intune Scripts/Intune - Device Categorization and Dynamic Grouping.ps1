#################################################################################
######Intune Maintenance Administration Script                             ######
#################################################################################
###### By: Clinton Sizemore                                                ######
###### Requires Microsoft.Graph.Authentication, Microsoft.Graph.Devicemanagement#
###### Microsoft.Graph.Groups, and Microsoft.Graph.Users modules to be     ######
###### installed in automation account runtime environment.                ######
#################################################################################

<#
MAKE SURE TO EDIT THE SCRIPT WITH YOUR COMPANY'S INFO:
LINE 26 COL 112
#>

# Authenticate to Microsoft Graph using Automation Account Managed Identity
Try {
    Connect-MgGraph -NoWelcome
    Write-Output "Successfully connected to Microsoft Graph."
}
Catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    Exit
}

# Fetch list of user departments and filter out /OS and /ZO designations
$users = Get-MgUser -All -Property UserPrincipalName, Department | Where-Object { $_.UserPrincipalName -like '[COMPANY.DOMAIN]' }
$departments = $users | Select-Object -ExpandProperty Department -Unique 

# Fetch existing device categories and dynamic groups
$existingCategories = Get-MgDeviceManagementDeviceCategory -All | Select-Object -ExpandProperty DisplayName
$existingGroups = Get-MgGroup -All | Where-Object -Property DisplayName -like 'Windows Workstations - *' | Select-Object -ExpandProperty DisplayName

# Create device categories if they don't already exist
function New-Categories {
    foreach ($department in $departments) {
        if ($existingCategories -notcontains $department) {
            # Create the device category
            New-MgDeviceManagementDeviceCategory -DisplayName $department
            Write-Output "Created new device category: $department"
        } else {
            Write-Output "Device category already exists: $department"
            Continue
        }
    }
}

# Create departmental Windows device groups if they don't exist
function New-Groups {
    foreach ($department in $departments) {
        if ($null -eq $existingGroups -or -not ($existingGroups -contains "Windows Workstations - $department")) {
            $groupName = "Windows Workstations - $department"
            $membershipRule = "(device.deviceOSType -eq 'Windows') and (device.deviceCategory -eq '$department')"
            $mailNickname = $groupName.ToLower().Replace(" ", "")
            New-MgGroup -DisplayName $groupName `
                -GroupTypes DynamicMembership `
                -SecurityEnabled `
                -MembershipRule $membershipRule `
                -MembershipRuleProcessingState "On" `
                -MailNickname $mailNickname `
                -MailEnabled:$False
            Write-Output "Created new dynamic device group: $groupName"
        } else {
            Write-Output "Dynamic Device group already exists: Windows Workstations - $department"
            Continue
        }
    }
}

# Assign device categories to devices
function Set-Categories {
    $devices = Get-MgDeviceManagementManagedDevice -All -ErrorAction SilentlyContinue
    foreach ($device in $devices) {
        $deviceUPN = $device.UserPrincipalName
        if ([string]::IsNullOrEmpty($deviceUPN)) {
            $deviceDepartment = "Unknown"
        } else {
            $deviceDepartment = Get-MgUser -UserId $deviceUPN -Property Department | Select-Object -ExpandProperty Department -Unique
        }
        $newDeviceCategory = $deviceDepartment
        $currentDeviceCategory = $device.DeviceCategoryDisplayName
        if ($currentDeviceCategory -ne $newDeviceCategory) {
            Update-MgDevice -DeviceId $device.id -DeviceCategory $newDeviceCategory -ErrorAction SilentlyContinue
            Write-Output "Category of $($device.DeviceName) has changed from $currentDeviceCategory to $newDeviceCategory"
        } elseif ([string]::IsNullOrEmpty($deviceUPN)) {
            Update-MgDevice -DeviceId $device.id -DeviceCategory "Unknown" -ErrorAction SilentlyContinue
            Write-Output "No User or Department assigned to $($device.DeviceName), clearing categorization."
        } else {
            Write-Output "Category of $($device.DeviceName) is already set to $newDeviceCategory"
            Continue
        }
    }
}

New-Categories
New-Groups
Set-Categories
Disconnect-MgGraph
