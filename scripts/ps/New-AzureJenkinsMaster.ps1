[CmdletBinding(SupportsShouldProcess = $True)]
param(
    [string] $configFile = $(throw "Please provide a configuration file path.")
)

# Stop everything if there are errors
$ErrorActionPreference = 'Stop'

$commonParameterSwitches =
    @{
        Verbose = $PSBoundParameters.ContainsKey('Verbose');
        Debug = $PSBoundParameters.ContainsKey('Debug');
        ErrorAction = "Stop"
    }

# Load the helper functions
$azureHelpers = Join-Path $PSScriptRoot Azure.ps1
. $azureHelpers

if (-not (Test-Path $configFile))
{
    throw "File not found. Configuration file path is invalid: $configFile"
}

# Get the data from the configuration file
# XML file is expected to look like:
# <?xml version="1.0" encoding="utf-8"?>
# <configuration>
#     <authentication>
#         <certificate name="${CertificateName}" />
#     </authentication>
#     <cloudservice name="${ServiceName}" location="${ServiceLocation}" affinity="${ServiceAffinity}">
#         <domain name="${DomainName}" organizationalunit="${DomainOrganizationalUnit}">
#             <admin domainname="${DomainNameForAdmin}" name="${AdminUserName}" password="${AdminPassword}" />
#         </domain>
#         <image name="${ImageName}" label="${ImageLabel}">
#             <baseimage>${BaseImageName}</baseimage>
#         </machine>
#     </cloudservice>
#     <desiredstate>
#         <installerpath>${DirectoryWithInstallers}</installerpath>
#         <entrypoint name="${InstallerMainScriptName}" />
#     </desiredstate>
# </configuration>
$config = ([xml](Get-Content $configFile)).configuration

$subscriptionName = $config.authentication.subscription.name
Write-Verbose "subscriptionName: $subscriptionName"

$sslCertificateName = $config.authentication.certificates.ssl
Write-Verbose "sslCertificateName: $sslCertificateName"

$adminName = $config.authentication.admin.name
Write-Verbose "adminName: $adminName"

$adminPassword = $config.authentication.admin.password

$baseImage = $config.service.image.baseimage
Write-Verbose "baseImage: $baseImage"

$storageAccount = $config.service.image.storageaccount
Write-Verbose "storageAccount: $storageAccount"

$resourceGroupName = $config.service.name
Write-Verbose "resourceGroupName: $resourceGroupName"

$installationDirectory = $config.desiredstate.installerpath
Write-Verbose "installationDirectory: $installationDirectory"

$installationScript = $config.desiredstate.entrypoint.name
Write-Verbose "installationScript: $installationScript"

$imageName = $config.service.image.name
Write-Verbose "imageName: $imageName"

$imageLabel = $config.service.image.label
Write-Verbose "imageLabel: $imageLabel"

# Set the storage account for the selected subscription
Set-AzureSubscription -SubscriptionName $subscriptionName -CurrentStorageAccount $storageAccount @commonParameterSwitches

# The name of the VM is technically irrevant because we're only after the disk in the end. So make sure it's unique but don't bother 
# with an actual name
$now = [System.DateTimeOffset]::Now
$vmName = ("ajm-" + $now.DayOfYear.ToString("000") + "-" + $now.Hour.ToString("00") + $now.Minute.ToString("00") + $now.Second.ToString("00"))
Write-Verbose "vmName: $vmName"

try
{
    New-AzureVmFromTemplate `
        -resourceGroupName $resourceGroupName `
        -storageAccount $storageAccount `
        -baseImage $baseImage `
        -vmName $vmName `
        -sslCertificateName $sslCertificateName `
        -adminName $adminName `
        -adminPassword $adminPassword

    $session = Get-PSSessionForAzureVM `
        -resourceGroupName $resourceGroupName `
        -vmName $vmName `
        -adminName $adminName `
        -adminPassword $adminPassword
    
    # Create the installer directory on the virtual machine
    $filesToCopy = Get-ChildItem -Path $installationDirectory -Recurse -Force @commonParameterSwitches | 
        Where-Object { -not $_.PsIsContainer } |
        Select-Object -ExpandProperty FullName
    $remoteDirectory = 'c:\installers'
    Add-AzureFilesToVM -session $session -remoteDirectory $remoteDirectory -filesToCopy $filesToCopy

    # Execute the remote installation scripts
    Invoke-Command `
        -Session $session `
        -ArgumentList @( (Join-Path $remoteDirectory (Split-Path -Leaf $installationScript)) ) `
        -ScriptBlock {
            param(
                [string] $installationScript
            )
        
            & $installationScript
        } `
         @commonParameterSwitches

    New-AzureSyspreppedVMImage -session $session -resourceGroupName $resourceGroupName -vmName $vmName -imageName $imageName -imageLabel $imageLabel
}
finally
{
    $vm = Get-AzureVM -ServiceName $resourceGroupName -Name $vmName
    if ($vm -ne $null)
    {
        Remove-AzureVM -ServiceName $resourceGroupName -Name $vmName -DeleteVHD @commonParameterSwitches
    }
}