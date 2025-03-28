#!/bin/bash

# Upload custom inventory data to Azure Log Analytics
# This script is intended to be used with Microsoft Intune for macOS
# Author: Ugur Koc, Twitter: @ugurkocde

# Azure Log Analytics Workspace details
# Do not forget to replace the workspaceId and sharedKey variables below with your actual values
workspaceId=""
sharedKey=""
logType="MacOS_CustomInventory" # Name of the table you want to add to in Azure Log Analytics
apiVersion="2016-04-01"   # Do not change

# Gather OS Information
os_version=$(sw_vers -productVersion)
OSBuild=$(sw_vers -buildVersion)
os_friendly=$(awk '/SOFTWARE LICENSE AGREEMENT FOR macOS/' '/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf' | awk -F 'macOS ' '{print $NF}' | awk '{print substr($0, 0, length($0)-1)}')

# Gather SIP Status
sip_status=$(csrutil status)
if [[ $sip_status == *"enabled"* ]]; then
    sip_status="enabled"
elif [[ $sip_status == *"disabled"* ]]; then
    sip_status="disabled"
else
    sip_status="unknown"
fi

# Determine Root account status
# Compliments of https://nverselab.com/2022/06/13/automatically-locking-down-root-access-on-macos/
rootCheck=`dscl . read /Users/root | grep AuthenticationAuthority 2>&1 > /dev/null ; echo $?`
if [ "${rootCheck}" == 1 ]; then
	root_status="Disabled"
else
	root_status"Enabled"
fi

# Gather Device Information
DeviceName=$(scutil --get ComputerName)
SerialNumber=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
Chip=$(sysctl -n machdep.cpu.brand_string)
Memory=$(sysctl -n hw.memsize | awk '{print $0/1024/1024 " MB"}')

# Gather Secure Boot Status
# Intel macs use different method than Silicon. Test which type.
whichchip=$(grep -i -c -e intel <<< $Chip )
if [ $whichchip == 1 ]; then
	#It's an intel
	secure_level=$(nvram 94b73556-2197-4702-82a8-3e1337dafbfb:AppleSecureBootPolicy | tail -c -4)
	if [ $secure_level == "%02" ]; then
		secure_boot_status="Full Security"
	elif [ $secure_level == "%01" ]; then
		secure_boot_status="Reduced Security"
	else
		secure_boot_status="No Security"
	fi
else
	secure_boot_status=$(system_profiler SPiBridgeDataType | awk -F': ' '/Secure Boot/ {print $2}')
fi

# Get FileVault Status
filevault_status=$(fdesetup status)
if [[ $filevault_status == *"FileVault is On."* ]]; then
    filevault_status="Enabled"
elif [[ $filevault_status == *"FileVault is Off."* ]]; then
    filevault_status="Disabled"
else
    filevault_status="Unknown"
fi

# Storage Information
Storage_Total=$(df -Hl | grep '/System/Volumes/Data' | awk '{print $2}')
Storage_Free=$(df -Hl | grep '/System/Volumes/Data' | awk '{print $4}')

# Last Boot Time
LastBoot=$(sysctl -n kern.boottime | awk '{print $4}' | sed 's/,//')
LastBootFormatted=$(date -jf "%s" "$LastBoot" +"%m/%d/%Y, %I:%M:%S %p")

# Get Model
Model=$(system_profiler SPHardwareDataType | awk -F: '/Model Name/ {print $2}' | sed 's/^ *//')

# Determine if MacOS TouchID has at least ONE fingerprint registered.
# Get Mac TouchID info
touchresult=$(bioutil -s -c | grep -i "no biometric templates")
#Test if Mac TouchID has no templates (aka, no fingerprints have been set up)
# -z = empty
if [[ -z $touchresult ]]; then
	finger_status="Fingerprint registered"
else
	exempt=$(grep -i -e imac -e studio -e mini <<< $Model)
	if [[ -z $exempt ]]; then
		finger_status="NONE"
	else
		finger_status="EXEMPT"
	fi
fi

# Extract Device ID
LOG_DIR="$HOME/Library/Logs/Microsoft/Intune"
DEVICE_ID=$(grep 'DeviceId:' "$LOG_DIR"/*.log | awk -F ': ' '{print $2}' | sort | uniq)

# Extract Entra Tenant ID
TENANT_ID=$(grep 'AADTenantID:' "$LOG_DIR"/*.log | awk -F ': ' '{print $2}' | sort | uniq)

# Get Local Admins
LocalAdmins=$(dscl . -read /Groups/admin GroupMembership | awk '{for (i=2; i<=NF; i++) printf $i " "; print ""}' | sed 's/root //' | sed 's/ root//')

# Prepare JSON Data, LAW expects JSON format uploads
jsonData="{ \
  \"DeviceName\": \"${DeviceName}\", \
  \"SerialNumber\": \"${SerialNumber}\", \
  \"Model\": \"${Model}\", \
  \"OSVersion\": \"${os_version}\", \
  \"OSBuild\": \"${OSBuild}\", \
  \"OSFriendlyName\": \"${os_friendly}\", \
  \"SIPStatus\": \"${sip_status}\", \
  \"SecureBootStatus\": \"${secure_boot_status}\", \
  \"Chip\": \"${Chip}\", \
  \"Memory\": \"${Memory}\", \
  \"FileVaultStatus\": \"${filevault_status}\", \
  \"StorageTotal\": \"${Storage_Total}\", \
  \"StorageFree\": \"${Storage_Free}\", \
  \"LastBoot\": \"${LastBootFormatted}\", \
  \"DeviceID\": \"${DEVICE_ID}\", \
  \"EntraTenantID\": \"${TENANT_ID}\", \
  \"LocalAdmins\": \"${LocalAdmins}\", \
  \"Root Account\": \"${root_status}\", \
  \"TouchID Status\": \"${finger_status}\" \
}"

echo "JSON Data: $jsonData"

# Generate the current date in RFC 1123 format
rfc1123date=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")

# String to sign
stringToSign="POST\n${#jsonData}\napplication/json\nx-ms-date:$rfc1123date\n/api/logs"

# Create the signature
decodedKey=$(echo "$sharedKey" | base64 -d)
signature=$(printf "%b" "$stringToSign" | openssl dgst -sha256 -hmac "$decodedKey" -binary | base64)

# Format the Authorization header
authHeader="SharedKey $workspaceId:$signature"

# Send Data to Azure Log Analytics
response=$(curl -X POST "https://$workspaceId.ods.opinsights.azure.com/api/logs?api-version=$apiVersion" \
    -H "Content-Type: application/json" \
    -H "Log-Type: $logType" \
    -H "Authorization: $authHeader" \
    -H "x-ms-date: $rfc1123date" \
    -d "$jsonData" -w "%{http_code}")

# Extract HTTP Status Code
httpStatusCode=$(echo $response | tail -n1)

# Check Response
if [ "$httpStatusCode" -eq 200 ]; then
    echo "Data successfully sent to Azure Log Analytics."
elif [[ "$httpStatusCode" == 4* ]]; then
    echo "Client error occurred: $response"
elif [[ "$httpStatusCode" == 5* ]]; then
    echo "Server error occurred: $response"
else
    echo "Unexpected response: $response"
fi
