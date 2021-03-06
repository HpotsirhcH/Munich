<#
.SYNOPSIS
Build the current powershell module as an artifact and push it to a designated feed

.DESCRIPTION
This method adjusts the module's manifest in two ways:
 - It assigns a new given or generated module version to the manifest
 - It extracts all public functions from this module and lists them in the manifest

 Subsequently it pushes the module as an artifact to a corresponding module feed as a nuget package where it can be downloaded from.

.PARAMETER feedName
Name of the feed to push the module to. By default it's 'Release-Modules'

.PARAMETER feedurl
Optional feedurl to set by pipeline. Use {0} in path to specify the feedname
e.g. "https://apps-custom.pkgs.visualstudio.com/_packaging/{0}/nuget/v2"

.PARAMETER customVersion
If the new version should not be generated you can specify a custom version. It must be higher than the latest version inside the module feed.

.PARAMETER systemAccessToken
Personal-Access-Token provieded by the pipeline or user to interact with the module feed

.PARAMETER queueById
Name/Email/Id of the user interacting with the module feed

.PARAMETER test
An optional parameter used by tests to only run code that is required for testing

.EXAMPLE
$(Build.SourcesDirectory)\$(module.name)\Pipeline\build.ps1 -systemAccessToken = "1235vas3" -queueById "testUser@myUser.org"

Execute the build.ps1 to push a module with the next available version to the default module feed 'Release-Modules'

.EXAMPLE
$(Build.SourcesDirectory)\$(module.name)\Pipeline\build.ps1 -feedname "Pipeline-Modules" -systemAccessToken = "1235vas3" -queueById "testUser@myUser.org" -customVersion "2.0.0"

Execute the build.ps1 to push a module with the desired version 2.0.0 to the module feed 'Pipeline-Modules'
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "Is provided by the pipeline as an encoded string")]
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $feedName,
    [Parameter(Mandatory = $true)]
    [string] $feedurl,
    [Parameter(Mandatory = $true)]
    [string] $systemAccessToken,
    [Parameter(Mandatory = $true)]
    [string] $queueById
)

#region functions

function Get-CurrentVersion {
    <#
.SYNOPSIS
Search for a certain module in the given feed to check it's version.

.DESCRIPTION
Search for a certain module in the given feed to check it's version. If no module can be found, version 0.0.0 is returned

.PARAMETER feedname
Name of the feed to search in

.PARAMETER moduleName
Name of the module to search for

.PARAMETER credential
The credentials required to access the feed

.EXAMPLE
$currentVersion = Get-CurrentVersion -moduleName "aks" -feedname "moduleFeed" -credential $credential

Search for module AKS in the feed moduleFeed to receive its version
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $feedname,
        [Parameter(Mandatory = $true)]
        [string] $moduleName,
        [Parameter(Mandatory = $true)]
        [PSCredential] $credential
    )

    Write-Verbose "Get Module"
    $module = Find-Module -Name "$moduleName*" -Repository $feedname -Credential $credential -ErrorAction SilentlyContinue -Verbose
    if ($module) {
        return $module.Version
    }
    else {
        Write-Warning "Module $moduleName not found"
        Write-Verbose "Assume first deployment"
        return New-Object System.Version("0.0.0")
    }
}

function Get-NewVersion {
    <#
.SYNOPSIS
Get a new version object

.DESCRIPTION
Generate a new version or return the custom version as a version object if set

.PARAMETER customVersion
The optionally set custom version

.PARAMETER currentVersion
The current version of the module

.EXAMPLE
Get-NewVersion -customVersion 0 -currentVersion 0.0.4

Get the new version 0.0.5

.EXAMPLE
Get-NewVersion -customVersion 0.0.6 -currentVersion 0.0.4

Get the new version 0.0.6
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [version] $currentVersion
    )

    $build = $currentVersion.Build
    $minor = $currentVersion.Minor
    $major = $currentVersion.Major

    if ($build -lt 65000) { $build++ }
    elseif ($minor -lt 65000) { $minor++ }
    else {
        throw "Minor and Build Versions exceeded. Run a build with a new custom major version. (e.g. 2.x.x)"
    }

    $newVersion = New-Object System.Version("{0}.{1}.{2}" -f $major, $minor, $build)
    
    return $newVersion
}

function Publish-NuGetModule {

    <#
.SYNOPSIS
Publish a given module to specified feed

.DESCRIPTION
Publish a given module to specified feed

.PARAMETER feedname
Nanm of the feed to push to

.PARAMETER credential
Credentials required by the feed

.EXAMPLE
Publish-NuGetModule -feedname "Release-Modules" -credential $credential -moduleName "Aks"

Push the module AKS to the feed 'Release-Modules'
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $feedname,
        [Parameter(Mandatory = $true)]
        [PSCredential] $credential,
        [Parameter(Mandatory = $true)]
        [string] $moduleBase,
        [Parameter(Mandatory = $true)]
        [string] $moduleName
    )

    try {
        Write-Verbose "Try pushing module $moduleName"
        Publish-Module -Path "$moduleBase" -NuGetApiKey 'VSTS' -Repository $feedname -Credential $credential -Force -Verbose
        Write-Verbose "Published module"
    }
    catch {
        Write-Verbose ("Unable to  upload module {0}" -f (Split-Path $PSScriptRoot -Leaf))
        $_.Exception | format-list -force
    }
}
function Set-LocalVersion {
    <#
.SYNOPSIS
Set the specified version to the module manifest

.DESCRIPTION
Set the specified version to the module manifest

.PARAMETER newVersion
The version to set

.PARAMETER moduleBase
The root folder of the module

.PARAMETER moduleName
The name of the module

.EXAMPLE
Set-LocalVersion -newVersion $newVersion -moduleBase "c:\modules\aks" -moduleName "aks"

Set the provided moduleVersion to the manifest of module aks in the folder 'c:\modules\aks'
#>
    [CmdletBinding(
        SupportsShouldProcess = $true
    )]
    param (
        [Parameter(Mandatory = $true)]
        [version] $newVersion,
        [Parameter(Mandatory = $true)]
        [string] $moduleBase,
        [Parameter(Mandatory = $true)]
        [string] $moduleName
    )

    $modulefile = "$moduleBase/$moduleName.psd1"
    if ($PSCmdlet.ShouldProcess("Module manifest", "Update")) {
        Update-ModuleManifest -Path $modulefile -ModuleVersion $newVersion
    }
}

function Update-ManifestExportedFunction {
    <#
.SYNOPSIS
Add the module's public functions to its manifest

.DESCRIPTION
Extracts all functions in the module's public folder to add them as 'FunctionsToExport' int he manifest

.PARAMETER moduleBase
The root folder of the module

.PARAMETER moduleName
The name of the module

.EXAMPLE
Update-ManifestExportedFunction  -moduleBase "c:\modules\aks" -moduleName "aks"

Add all public functions of module AKS to its manifest
#>
    [CmdletBinding(
        SupportsShouldProcess = $true
    )]
    param (
        [Parameter(Mandatory = $true)]
        [string] $moduleBase,
        [Parameter(Mandatory = $true)]
        [string] $moduleName
    )

    $publicFunctions = (Get-ChildItem -Path "$moduleBase\Public" -Filter '*.ps1').BaseName

    $modulefile = "$moduleBase\$moduleName.psd1"
    if ($PSCmdlet.ShouldProcess("Module manifest", "Update")) {
        Write-Verbose "Update Manifest $moduleFile"
        Update-ModuleManifest -Path $modulefile -FunctionsToExport $publicFunctions
    }
}
#endregion

$oldPreferences = $VerbosePreference
$VerbosePreference = "Continue"

try {
    $moduleBase = Split-Path "$PSScriptRoot" -Parent
    $moduleName = Split-Path $moduleBase -Leaf

    $feedurl = $feedurl -f $feedName
    Write-Verbose "Feed-Url: $feedurl"

    $password = ConvertTo-SecureString $systemAccessToken -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($queueById, $password)

    $currentVersion = Get-CurrentVersion -feedname $feedName -moduleName $moduleName -credential $credential
    Write-Verbose "Current version is $currentVersion"

    $newVersion = Get-NewVersion -currentVersion $currentVersion
    Write-Verbose "New version is $newVersion"

    Set-LocalVersion -newVersion $newVersion -moduleName $moduleName -moduleBase $moduleBase
    Write-Verbose "Updated local version to $newVersion"

    Update-ManifestExportedFunction  -moduleName $moduleName -moduleBase $moduleBase

    Test-ModuleManifest -Path "$moduleBase\$moduleName.psd1" | Format-List

    Publish-NuGetModule -feedname $feedname -credential $credential -moduleName $moduleName -moduleBase $moduleBase
}
finally {
    $VerbosePreference = $oldPreferences
}
