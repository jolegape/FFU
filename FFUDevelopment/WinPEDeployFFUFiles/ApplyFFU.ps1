### VARIABLES
$FFUServerHost = "SERVER.example.com"
$FFUSharePath = "\\$FFUServerHost\FFU\ExamBuild"
$FFUDriverPath = "\\$FFUServerHost\Drivers"
$FFUShareUser = "EXAMPLE\svc_account"
$FFUSharePass = "Sup3rS3cr3tPa55w0rd"
$SnipeURI = "https://assets.example.com/api/v1/hardware/byserial"
$SnipeApiKey = "SuperSecretAPIKeyHere!!!!!"
# $FFUCredential = New-Object -TypeName System.Management.Automation.PSCredential -argumentlist $FFUShareUser, $FFUSharePass


function Get-FFUShare() {	

    Write-Host "Mapping M: to [$FFUSharePath]"

    for ($i = 1; $i -le 12; $i++) {
        net use M: /delete /y 2>$null | Out-Null
        net use M: $FFUSharePath /user:$FFUShareUser $FFUSharePass /persistent:yes | Out-Null
        $NetUseResult = $LASTEXITCODE

        if ($NetUseResult -eq 0 -and (Test-Path "M:\")) {
            Write-Host "M: mapped successfully"
            return "M:"
        }

        Write-Host "Mapping attempt $i failed"

        if ($i -lt 12) {
            Start-Sleep -Seconds 5
        }
    }
    
    Write-Host "Failed to map M:"
}

function Get-DriverShare() {	

    Write-Host "Mapping N: to [$FFUDriverPath]"

    for ($i = 1; $i -le 12; $i++) {
        net use N: /delete /y 2>$null | Out-Null
        net use N: $FFUDriverPath /user:$FFUShareUser $FFUSharePass /persistent:yes | Out-Null
        $NetUseResult = $LASTEXITCODE

        if ($NetUseResult -eq 0 -and (Test-Path "N:\")) {
            Write-Host "N: mapped successfully"
            return "N:"
        }

        Write-Host "Mapping attempt $i failed"

        if ($i -lt 12) {
            Start-Sleep -Seconds 5
        }
    }
    
    Write-Host "Failed to map N:"
}

function WriteLog($LogText) { 
    Add-Content -path $LogFile -value "$((Get-Date).ToString()) $LogText"
}

function Stop-Script {
    param(
        [string]$Message
    )
    Write-Host "`n"
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Error -Message $Message
    }
    WriteLog "Copying dism log to $LogRoot"
    Invoke-Process xcopy "X:\Windows\logs\dism\dism.log $LogRoot /Y" 
    WriteLog "Copying dism log to $LogRoot succeeded"
    Read-Host "Press Enter to exit"
    Exit
}

function Invoke-Process {
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ArgumentList,

        [Parameter()]
        [switch]$IgnoreExitCode,

        [Parameter()]
        [switch]$PassThruExitCode
    )

    $ErrorActionPreference = 'Stop'

    try {
        $stdOutTempFile = "$env:TEMP\$((New-Guid).Guid)"
        $stdErrTempFile = "$env:TEMP\$((New-Guid).Guid)"

        $startProcessParams = @{
            FilePath               = $FilePath
            ArgumentList           = $ArgumentList
            RedirectStandardError  = $stdErrTempFile
            RedirectStandardOutput = $stdOutTempFile
            Wait                   = $true;
            PassThru               = $true;
            NoNewWindow            = $true;
        }
        if ($PSCmdlet.ShouldProcess("Process [$($FilePath)]", "Run with args: [$($ArgumentList)]")) {
            $cmd = Start-Process @startProcessParams
            $cmdOutput = Get-Content -Path $stdOutTempFile -Raw
            $cmdError = Get-Content -Path $stdErrTempFile -Raw

            if ($cmd.ExitCode -ne 0) {
                # Non-terminating mode: capture output to Scriptlog and continue
                if ($IgnoreExitCode) {
                    if ([string]::IsNullOrEmpty($cmdOutput) -eq $false) {
                        WriteLog $cmdOutput
                    }
                    if ([string]::IsNullOrEmpty($cmdError) -eq $false) {
                        WriteLog $cmdError
                    }
                    if ($PassThruExitCode) {
                        return $cmd.ExitCode
                    }
                    return
                }

                if ($cmdError) {
                    throw $cmdError.Trim()
                }
                if ($cmdOutput) {
                    throw $cmdOutput.Trim()
                }
                throw "Process failed. ExitCode = $($cmd.ExitCode)."
            }
            else {
                if ([string]::IsNullOrEmpty($cmdOutput) -eq $false) {
                    WriteLog $cmdOutput
                }
            }

            if ($PassThruExitCode) {
                return $cmd.ExitCode
            }
        }
    }
    catch {
        #$PSCmdlet.ThrowTerminatingError($_)
        WriteLog $_
        Write-Host 'Script failed - check scriptlog.txt on the USB drive for more info'
        throw $_

    }
    finally {
        Remove-Item -Path $stdOutTempFile, $stdErrTempFile -Force -ErrorAction Ignore
        
    }
    
}

function Write-SectionHeader($Title) {
    $width = 51
    $leftPad = [math]::Floor(($width - $Title.Length) / 2)
    $rightPad = $width - $Title.Length - $leftPad
    $centeredTitle = (' ' * $leftPad) + $Title + (' ' * $rightPad)

    Write-Host "`n" # Add a newline for spacing
    Write-Host ('-' * $width) -ForegroundColor Yellow
    Write-Host $centeredTitle -ForegroundColor Yellow
    Write-Host ('-' * $width) -ForegroundColor Yellow
}

function Get-HardDrive() {
    $systemInfo = Get-CimInstance -Class 'Win32_ComputerSystem'
    $manufacturer = $systemInfo.Manufacturer
    $model = $systemInfo.Model
    WriteLog 'Getting Hard Drive info'
    if ($manufacturer -eq 'Microsoft Corporation' -and $model -eq 'Virtual Machine') {
        WriteLog 'Running in a Hyper-V VM. Getting virtual disk on Index 0 and SCSILogicalUnit 0'
        $diskDriveCandidates = @(Get-CimInstance -Class 'Win32_DiskDrive' | Where-Object { $_.MediaType -eq 'Fixed hard disk media' `
                    -and $_.Model -eq 'Microsoft Virtual Disk' `
                    -and $_.Index -eq 0 `
                    -and $_.SCSILogicalUnit -eq 0
            })
    }
    else {
        WriteLog 'Not running in a VM. Getting physical disk drive'
        $diskDriveCandidates = @(Get-CimInstance -Class 'Win32_DiskDrive' | Where-Object { $_.MediaType -eq 'Fixed hard disk media' -and $_.Model -ne 'Microsoft Virtual Disk' })
    }

    # Return the array of candidates for selection in main script
    return $diskDriveCandidates
}

function Read-MenuSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string]$InvalidInputMessage,

        [Parameter()]
        [int[]]$ValidSelections,

        [Parameter()]
        [int]$Minimum = [int]::MinValue,

        [Parameter()]
        [int]$Maximum = [int]::MaxValue,

        [Parameter()]
        [switch]$AllowSkip
    )

    do {
        $userInput = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($userInput)) {
            Write-Host $InvalidInputMessage
            continue
        }

        $selection = 0
        if (-not [int]::TryParse($userInput, [ref]$selection)) {
            Write-Host $InvalidInputMessage
            continue
        }

        if ($AllowSkip -and $selection -eq 0) {
            return 0
        }

        if ($PSBoundParameters.ContainsKey('ValidSelections')) {
            if ($ValidSelections -notcontains $selection) {
                Write-Host $InvalidInputMessage
                continue
            }
        }
        elseif ($selection -lt $Minimum -or $selection -gt $Maximum) {
            Write-Host $InvalidInputMessage
            continue
        }

        return $selection
    } until ($false)
}

function Get-NormalizedManufacturer {
    param(
        [string]$Manufacturer
    )

    if ([string]::IsNullOrWhiteSpace($Manufacturer)) {
        return $null
    }

    $normalized = $Manufacturer.Trim().ToUpperInvariant()
    if ($normalized -like '*DELL*') {
        return 'Dell'
    }
    elseif ($normalized -like '*HP*' -or $normalized -like '*HEWLETT*') {
        return 'HP'
    }
    elseif ($normalized -like '*LENOVO*') {
        return 'Lenovo'
    }
    elseif ($normalized -like '*MICROSOFT*' -or $normalized -like '*SURFACE*') {
        return 'Microsoft'
    }
    elseif ($normalized -like '*PANASONIC*') {
        return 'Panasonic Corporation'
    }
    elseif ($normalized -like '*VIGLEN*') {
        return 'Viglen'
    }
    elseif ($normalized -like '*AZW*') {
        return 'AZW'
    }
    elseif ($normalized -like '*FUJITSU*') {
        return 'Fujitsu'
    }
    elseif ($normalized -like '*GETAC*') {
        return 'Getac'
    }
    elseif ($normalized -like '*BYTESPEED*') {
        return 'ByteSpeed'
    }
    elseif ($normalized -like '*INTEL*') {
        return 'Intel'
    }

    return $Manufacturer.Trim()
}

function Get-SystemIdentityMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Management.Infrastructure.CimInstance]$ComputerSystem,
        [Parameter()]
        [Microsoft.Management.Infrastructure.CimInstance]$ComputerSystemProduct,
        [Parameter()]
        [Microsoft.Management.Infrastructure.CimInstance]$MsSystemInformation
    )

    # Consolidate manufacturer normalization so UI and driver mapping share the same identifiers.
    $normalizedManufacturer = Get-NormalizedManufacturer -Manufacturer $ComputerSystem.Manufacturer
    if (-not $ComputerSystemProduct) {
        $ComputerSystemProduct = Get-CimInstance -Class Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    }
    $baseBoardInfo = Get-CimInstance -Class Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $baseBoardSku = if ($baseBoardInfo -and -not [string]::IsNullOrWhiteSpace($baseBoardInfo.SKU)) { $baseBoardInfo.SKU.Trim() } else { $null }
    $msBaseBoardProduct = if ($MsSystemInformation -and $MsSystemInformation.BaseBoardProduct) { $MsSystemInformation.BaseBoardProduct.Trim() } else { $null }

    $modelCandidate = if ($normalizedManufacturer -eq 'Lenovo' -and $ComputerSystemProduct -and -not [string]::IsNullOrWhiteSpace($ComputerSystemProduct.Version)) {
        $ComputerSystemProduct.Version
    }
    else {
        $ComputerSystem.Model
    }
    if ([string]::IsNullOrWhiteSpace($modelCandidate)) {
        $modelCandidate = $ComputerSystem.Model
    }
    if ($modelCandidate) {
        $modelCandidate = $modelCandidate.Trim()
    }

    $identity = [pscustomobject]@{
        ManufacturerOriginal   = $ComputerSystem.Manufacturer
        ManufacturerNormalized = if ($normalizedManufacturer) { $normalizedManufacturer } else { $ComputerSystem.Manufacturer }
        ModelOriginal          = $modelCandidate
        ModelNormalized        = ConvertTo-ComparableModelName -Text $modelCandidate
        SystemSkuNormalized    = $null
        FallbackSkuNormalized  = $null
        MachineTypeNormalized  = $null
        IdentifierLabel        = 'System ID'
        IdentifierValue        = $null
    }

    if ($MsSystemInformation -and $MsSystemInformation.SystemSku) {
        $identity.SystemSkuNormalized = $MsSystemInformation.SystemSku.Trim().ToUpperInvariant()
    }

    switch ($identity.ManufacturerNormalized) {
        'Dell' {
            if ($MsSystemInformation -and $MsSystemInformation.SystemSku) {
                $identity.SystemSkuNormalized = $MsSystemInformation.SystemSku.Trim().ToUpperInvariant()
            }
            $oemStringArray = $ComputerSystem | Select-Object -ExpandProperty OEMStringArray -ErrorAction SilentlyContinue
            if ($oemStringArray) {
                $joinedOemString = ($oemStringArray -join ' ')
                $fallbackMatches = [regex]::Matches($joinedOemString, '\[\S*]')
                if ($fallbackMatches.Count -gt 0) {
                    $identity.FallbackSkuNormalized = $fallbackMatches[0].Value.TrimStart('[').TrimEnd(']').Trim().ToUpperInvariant()
                }
            }
            if ($identity.FallbackSkuNormalized) {
                $identity.IdentifierValue = $identity.FallbackSkuNormalized
            }
            elseif ($identity.SystemSkuNormalized) {
                $identity.IdentifierValue = $identity.SystemSkuNormalized
            }
            break
        }
        'HP' {
            if ($msBaseBoardProduct) {
                $identity.SystemSkuNormalized = $msBaseBoardProduct.ToUpperInvariant()
            }
            break
        }
        'Lenovo' {
            $modelValue = $ComputerSystem.Model
            if (-not [string]::IsNullOrWhiteSpace($modelValue) -and $modelValue.Length -ge 4) {
                $identity.MachineTypeNormalized = $modelValue.Substring(0, 4).Trim().ToUpperInvariant()
            }
            $identity.IdentifierLabel = 'Machine Type'
            if ($identity.MachineTypeNormalized) {
                $identity.IdentifierValue = $identity.MachineTypeNormalized
            }
            break
        }
        'Panasonic Corporation' {
            $identity.IdentifierLabel = 'System ID'
            if ($msBaseBoardProduct) {
                $identity.SystemSkuNormalized = $msBaseBoardProduct.ToUpperInvariant()
                $identity.IdentifierValue = $msBaseBoardProduct
            }
            break
        }
        'Viglen' {
            $identity.IdentifierLabel = 'System ID'
            if ($baseBoardSku) {
                $identity.SystemSkuNormalized = $baseBoardSku.ToUpperInvariant()
                $identity.IdentifierValue = $baseBoardSku
            }
            break
        }
        'AZW' {
            $identity.IdentifierLabel = 'System ID'
            if ($msBaseBoardProduct) {
                $identity.SystemSkuNormalized = $msBaseBoardProduct.ToUpperInvariant()
                $identity.IdentifierValue = $msBaseBoardProduct
            }
            break
        }
        'Fujitsu' {
            $identity.IdentifierLabel = 'System ID'
            if ($baseBoardSku) {
                $identity.SystemSkuNormalized = $baseBoardSku.ToUpperInvariant()
                $identity.IdentifierValue = $baseBoardSku
            }
            break
        }
        'Getac' {
            $identity.IdentifierLabel = 'System ID'
            if ($msBaseBoardProduct) {
                $identity.SystemSkuNormalized = $msBaseBoardProduct.ToUpperInvariant()
                $identity.IdentifierValue = $msBaseBoardProduct
            }
            break
        }
        'Intel' {
            $identity.IdentifierLabel = 'Model'
            if ($identity.ModelOriginal) {
                $identity.IdentifierValue = $identity.ModelOriginal
            }
            break
        }
        'ByteSpeed' {
            $modelValue = if ($ComputerSystem.Model) { $ComputerSystem.Model.Trim() } else { $null }
            if ($modelValue -and $modelValue -like '*NUC*') {
                $identity.ManufacturerNormalized = 'Intel'
                if ($msBaseBoardProduct) {
                    $identity.ModelOriginal = $msBaseBoardProduct
                    $identity.ModelNormalized = ConvertTo-ComparableModelName -Text $msBaseBoardProduct
                    $identity.IdentifierLabel = 'Model'
                    $identity.IdentifierValue = $msBaseBoardProduct
                }
                elseif ($modelValue) {
                    $identity.IdentifierLabel = 'Model'
                    $identity.IdentifierValue = $modelValue
                }
            }
            else {
                $identity.IdentifierLabel = 'Model'
                if ($modelValue) {
                    $identity.IdentifierValue = $modelValue
                }
            }
            break
        }
        default {
            break
        }
    }

    if ($null -eq $identity.IdentifierValue) {
        if ($identity.MachineTypeNormalized) {
            $identity.IdentifierValue = $identity.MachineTypeNormalized
        }
        elseif ($identity.SystemSkuNormalized) {
            $identity.IdentifierValue = $identity.SystemSkuNormalized
        }
    }

    return $identity
}

function Get-SystemInformation {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HardDrive
    )

    $computerSystem = Get-CimInstance -Class Win32_ComputerSystem
    $computerSystemProduct = Get-CimInstance -Class Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $msSystemInformation = Get-CimInstance -Namespace 'root\WMI' -Class MS_SystemInformation -ErrorAction SilentlyContinue
    $systemIdentity = Get-SystemIdentityMetadata -ComputerSystem $computerSystem -ComputerSystemProduct $computerSystemProduct -MsSystemInformation $msSystemInformation

    $biosInfo = Get-CimInstance -Class Win32_Bios
    $processorInfo = Get-CimInstance -Class Win32_Processor | Select-Object -First 1
    $processor = if ($processorInfo) { $processorInfo.Name } else { 'Unknown' }
    $totalMemory = (Get-CimInstance -Class Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    if ($null -eq $totalMemory) {
        $totalMemory = 0
    }
    $totalMemoryGB = [math]::Round(($totalMemory / 1GB), 2)
    $diskSizeGB = [math]::Round(($HardDrive.DiskSize / 1GB), 2)

    $baseBoardManufacturer = if ($msSystemInformation -and $msSystemInformation.BaseBoardManufacturer) { $msSystemInformation.BaseBoardManufacturer.Trim() } else { $null }
    $baseBoardProduct = if ($msSystemInformation -and $msSystemInformation.BaseBoardProduct) { $msSystemInformation.BaseBoardProduct.Trim() } else { $null }
    $baseBoardVersion = if ($msSystemInformation -and $msSystemInformation.BaseBoardVersion) { $msSystemInformation.BaseBoardVersion.Trim() } else { $null }
    $biosMajorRelease = if ($msSystemInformation -and $null -ne $msSystemInformation.BiosMajorRelease) { [string]$msSystemInformation.BiosMajorRelease } else { $null }
    $biosMinorRelease = if ($msSystemInformation -and $null -ne $msSystemInformation.BiosMinorRelease) { [string]$msSystemInformation.BiosMinorRelease } else { $null }
    $biosReleaseDate = $null
    if ($msSystemInformation -and $msSystemInformation.BiosReleaseDate) {
        try {
            $biosReleaseDate = [System.Management.ManagementDateTimeConverter]::ToDateTime($msSystemInformation.BiosReleaseDate).ToString('yyyy-MM-dd HH:mm:ss')
        }
        catch {
            $biosReleaseDate = $msSystemInformation.BiosReleaseDate
        }
    }
    $biosVendor = if ($msSystemInformation -and $msSystemInformation.BiosVendor) { $msSystemInformation.BiosVendor.Trim() } else { $null }
    $biosVersion = if ($msSystemInformation -and $msSystemInformation.BiosVersion) { $msSystemInformation.BiosVersion.Trim() } else { $null }
    $ecFirmwareMajorRelease = if ($msSystemInformation -and $null -ne $msSystemInformation.ECFirmwareMajorRelease) { [string]$msSystemInformation.ECFirmwareMajorRelease } else { $null }
    $ecFirmwareMinorRelease = if ($msSystemInformation -and $null -ne $msSystemInformation.ECFirmwareMinorRelease) { [string]$msSystemInformation.ECFirmwareMinorRelease } else { $null }

    $displayManufacturer = if ($systemIdentity.ManufacturerNormalized) { $systemIdentity.ManufacturerNormalized } else { $computerSystem.Manufacturer }
    $displayModel = if ($systemIdentity.ModelNormalized) { $systemIdentity.ModelNormalized } else { $systemIdentity.ModelOriginal }

    $sysInfoData = [ordered]@{
        "Manufacturer"           = $displayManufacturer
        "Model"                  = $displayModel
        "Serial Number"          = $biosInfo.SerialNumber
        "Processor"              = $processor
        "Memory"                 = "{0} GB" -f $totalMemoryGB
        "Disk Size"              = "{0} GB" -f $diskSizeGB
        "Logical Sector Size"    = "$($HardDrive.BytesPerSector) Bytes"
        "BaseBoardManufacturer"  = if ($baseBoardManufacturer) { $baseBoardManufacturer } else { 'Not Detected' }
        "BaseBoardProduct"       = if ($baseBoardProduct) { $baseBoardProduct } else { 'Not Detected' }
        "BaseBoardVersion"       = if ($baseBoardVersion) { $baseBoardVersion } else { 'Not Detected' }
        "BiosMajorRelease"       = if ($biosMajorRelease) { $biosMajorRelease } else { 'Not Detected' }
        "BiosMinorRelease"       = if ($biosMinorRelease) { $biosMinorRelease } else { 'Not Detected' }
        "BiosReleaseDate"        = if ($biosReleaseDate) { $biosReleaseDate } else { 'Not Detected' }
        "BiosVendor"             = if ($biosVendor) { $biosVendor } else { 'Not Detected' }
        "BiosVersion"            = if ($biosVersion) { $biosVersion } else { 'Not Detected' }
        "ECFirmwareMajorRelease" = if ($ecFirmwareMajorRelease) { $ecFirmwareMajorRelease } else { 'Not Detected' }
        "ECFirmwareMinorRelease" = if ($ecFirmwareMinorRelease) { $ecFirmwareMinorRelease } else { 'Not Detected' }
        "ManufacturerNormalized" = $systemIdentity.ManufacturerNormalized
        "ModelNormalized"        = $systemIdentity.ModelNormalized
        "DriverIdentifierLabel"  = $systemIdentity.IdentifierLabel
        "DriverIdentifierValue"  = $systemIdentity.IdentifierValue
        "SystemSkuNormalized"    = $systemIdentity.SystemSkuNormalized
        "FallbackSkuNormalized"  = $systemIdentity.FallbackSkuNormalized
        "MachineTypeNormalized"  = $systemIdentity.MachineTypeNormalized
    }
    $sysInfoData[$systemIdentity.IdentifierLabel] = if ($systemIdentity.IdentifierValue) { $systemIdentity.IdentifierValue } else { 'Not Detected' }

    return [PSCustomObject]$sysInfoData
}

function Write-SystemInformation {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$SystemInformation
    )

    $hiddenProperties = @(
        'SystemSkuNormalized',
        'FallbackSkuNormalized',
        'MachineTypeNormalized',
        'ManufacturerNormalized',
        'ModelNormalized',
        'DriverIdentifierLabel',
        'DriverIdentifierValue'
    )

    WriteLog '--- System Information ---'
    foreach ($property in $SystemInformation.psobject.Properties) {
        if ($hiddenProperties -contains $property.Name) {
            continue
        }
        WriteLog "$($property.Name): $($property.Value)"
    }
    WriteLog '--- End System Information ---'

    Write-SectionHeader -Title 'System Information'
    $displayData = [ordered]@{}
    foreach ($property in $SystemInformation.psobject.Properties) {
        if ($hiddenProperties -contains $property.Name) {
            continue
        }
        $displayData[$property.Name] = $property.Value
    }
    $consoleOutput = ([pscustomobject]$displayData | Format-List | Out-String)
    Write-Host $consoleOutput.Trim()
    Write-Host
}

function ConvertTo-ComparableModelName {
    [CmdletBinding()]
    param(
        [string]$Text
    )
    # Normalize model strings with HP-specific adjustments.
    # Remove inch unit variants (23.8-in, 23.8 inch, 23inch, 23-in, etc.) keeping only the numeric size.
    # Canonicalize All-in-One variants (All in One, All-in-One, All-in-One PC, AiO, AIO) to 'AIO'.
    # Convert any non-alphanumeric sequence to a single space, collapse whitespace, and trim.
    if ($null -eq $Text) { return '' }
    $original = $Text
    # Remove inch unit variants while preserving the numeric size
    $Text = [regex]::Replace($Text, '(?i)(\d+(?:\.\d+)?)(?:\s*[-]?\s*)(?:in|inch)\b', '$1')
    # Canonicalize All-in-One variants
    $Text = [regex]::Replace($Text, '(?i)\bAll[\s-]*in[\s-]*One(?:\s*PC)?\b', 'AIO')
    $Text = [regex]::Replace($Text, '(?i)\bAiO\b', 'AIO')
    # Generic normalization
    $normalized = ($Text -replace '[^A-Za-z0-9]+', ' ')
    $normalized = ($normalized -replace '\s+', ' ').Trim()
    if ($normalized -ne $original) {
        WriteLog "Normalized model string: Original='$original' -> Normalized='$normalized'"
    }
    return $normalized
}

function Get-UnattendComputerNameValue {
    if ($null -eq $UnattendFile) {
        return $null
    }

    [xml]$xml = Get-Content $UnattendFile
    foreach ($component in $xml.unattend.settings.component) {
        if ($component.ComputerName) {
            return [string]$component.ComputerName
        }
    }

    return $null
}

function Test-LegacyPromptComputerName($computername) {
    if ([string]::IsNullOrWhiteSpace($computername)) {
        return $false
    }

    $normalizedName = $computername.Trim().ToLowerInvariant()
    return $normalizedName -in @('mycomputer', 'default')
}

function Get-NormalizedComputerName($computername) {
    if ([string]::IsNullOrWhiteSpace($computername)) {
        throw 'Computer name cannot be empty.'
    }

    $normalizedName = ($computername -replace "\s", '').Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        throw 'Computer name cannot be empty after removing spaces.'
    }

    if ($normalizedName.Length -gt 15) {
        $normalizedName = $normalizedName.Substring(0, 15)
    }

    return $normalizedName
}

function Set-ConfiguredComputerName($computername) {
    $normalizedName = Get-NormalizedComputerName($computername)
    $normalizedName = Set-Computername($normalizedName)
    Writelog "Computer name will be set to $normalizedName"
    Write-Host "Computer name will be set to $normalizedName"
    return $normalizedName
}

function Set-Computername($computername) {
    [xml]$xml = Get-Content $UnattendFile
    $components = $xml.unattend.settings.component
    $found = $false
    foreach ($component in $components) {
        if ($component.ComputerName) {
            $component.ComputerName = $computername
            $found = $true
            break
        }
    }
    if (-not $found) {
        WriteLog 'ComputerName element not found in unattend.xml.'
        throw 'ComputerName element not found in unattend.xml.'
    }
    $xml.Save($UnattendFile)
    return $computername
}

function Resolve-ComputerNameTemplate($computerNameTemplate, $serialNumber) {
    if ([string]::IsNullOrWhiteSpace($computerNameTemplate)) {
        throw 'Computer name template cannot be empty.'
    }

    $resolvedName = $computerNameTemplate -replace '(?i)%serial%', $serialNumber
    if ($resolvedName -match '%') {
        throw 'Unsupported device name variable found. Only %serial% is supported.'
    }

    return Get-NormalizedComputerName($resolvedName)
}

function Get-WindowsPartitionFromAppliedDisk {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber
    )

    $basicDataPartitions = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' })
    foreach ($partition in $basicDataPartitions) {
        if ([string]::IsNullOrWhiteSpace($partition.DriveLetter)) { continue }
        $volume = Get-Volume -DriveLetter $partition.DriveLetter -ErrorAction SilentlyContinue
        if ($null -ne $volume -and $volume.FileSystemLabel -eq 'Windows') {
            return $partition
        }
    }

    return $basicDataPartitions | Select-Object -First 1
}

function Get-FFUDataPartitionDriveLetterDeploymentContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPartitionRoot
    )

    $runtimeDirectory = Join-Path -Path $WindowsPartitionRoot -ChildPath 'Windows\Setup\Scripts\FFUDL'
    $runtimeScriptPath = Join-Path -Path $runtimeDirectory -ChildPath 'Apply.ps1'
    $manifestPath = Join-Path -Path $runtimeDirectory -ChildPath 'Manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
            throw "Data partition drive-letter runtime directory exists without a manifest at $manifestPath."
        }
        return $null
    }

    if (-not (Test-Path -LiteralPath $runtimeScriptPath -PathType Leaf)) {
        throw "Data partition drive-letter manifest exists without its runtime script at $runtimeScriptPath."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$manifest.SchemaVersion -ne 1) {
        throw "Unsupported data partition drive-letter manifest schema version '$($manifest.SchemaVersion)'."
    }
    if (@($manifest.Partitions).Count -eq 0) {
        throw 'Data partition drive-letter manifest does not contain any partitions.'
    }

    $processorArchitecture = ([string]$manifest.ProcessorArchitecture).Trim().ToLowerInvariant()
    if ($processorArchitecture -notin @('amd64', 'arm64')) {
        throw "Unsupported data partition drive-letter processor architecture '$processorArchitecture'."
    }

    WriteLog "Found data partition drive-letter assignment manifest with $(@($manifest.Partitions).Count) partition(s)."
    return [pscustomobject]@{
        RuntimeDirectory      = $runtimeDirectory
        RuntimeScriptPath     = $runtimeScriptPath
        ManifestPath          = $manifestPath
        ProcessorArchitecture = $processorArchitecture
    }
}

# Ensure network operability
Start-Sleep -Seconds 5
Write-Host "Waiting for SMB connection..."
while (!(Test-Connection -ComputerName $FFUServerHost -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    Write-Host "Attempt failed. Retrying in 15 seconds..."
    Start-Sleep -Seconds 15
}
Write-Host "Network connection established"

#Get Drive Roots and create log file
$DeployRoot = Get-FFUShare
$DriverRoot = Get-DriverShare

if (-not $DeployRoot -or -not $DriverRoot) {
    Write-Host "Required network share could not be mapped. Aborting."
    exit 1
}

$serialNumber = (Get-CimInstance -ClassName Win32_Bios).SerialNumber.Trim()
$LogFileName = 'ScriptLog.txt'
$LogRoot = "$($DeployRoot)\Logs\$($serialNumber)"
New-item -Path "$($LogRoot)" -Name $LogFileName -ItemType "file" -Force | Out-Null
$LogFile = "$($LogRoot)\$($LogFileName)"
$version = '2609.1'
WriteLog 'Begin Logging'
WriteLog "Script version: $version"
WriteLog "Deploy Root is $($DeployRoot)"
WriteLog "Driver Root is $($DriverRoot)"

# Display banner and version
$banner = @"

███████╗███████╗██╗   ██╗    ██████╗ ██╗   ██╗██╗██╗     ██████╗ ███████╗██████╗ 
██╔════╝██╔════╝██║   ██║    ██╔══██╗██║   ██║██║██║     ██╔══██╗██╔════╝██╔══██╗
█████╗  █████╗  ██║   ██║    ██████╔╝██║   ██║██║██║     ██║  ██║█████╗  ██████╔╝
██╔══╝  ██╔══╝  ██║   ██║    ██╔══██╗██║   ██║██║██║     ██║  ██║██╔══╝  ██╔══██╗
██║     ██║     ╚██████╔╝    ██████╔╝╚██████╔╝██║███████╗██████╔╝███████╗██║  ██║
╚═╝     ╚═╝      ╚═════╝     ╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═╝
                                                                                                                                                                
"@
Write-Host $banner -ForegroundColor Cyan
Write-Host "Version $version" -ForegroundColor Cyan
Write-Host "Deploy Root is $($DeployRoot)\"
Write-Host "Driver Root is $($DriverRoot)\"

#Find PhysicalDrive
Write-SectionHeader -Title 'Target Disk Selection'
$diskDriveCandidates = @(Get-HardDrive)
$diskCount = $diskDriveCandidates.Count

# Raise error if no disks found
if ($diskCount -eq 0) {
    $errorMessage = 'No hard drive found. You may need to add storage drivers to the WinPE image.'
    WriteLog ($errorMessage + ' Exiting.')
    WriteLog 'To add drivers, place them in the PEDrivers folder and re-run the creation script with -CopyPEDrivers $true, or add them manually via DISM.'
    Stop-Script -Message $errorMessage
}

# Select target disk - prompt user if multiple disks found
if ($diskCount -eq 1) {
    $selectedDisk = $diskDriveCandidates[0]
    WriteLog "Single fixed disk detected: DiskNumber=$($selectedDisk.Index), Model=$($selectedDisk.Model)"
    Write-Host "Single fixed disk detected: $($selectedDisk.Model)"
}
else {
    WriteLog "Found $diskCount fixed disks. Prompting for selection."
    Write-Host "Found $diskCount fixed disks"
    
    # Build list of available disk indexes for validation
    $validDiskIndexes = @($diskDriveCandidates | ForEach-Object { $_.Index })
    
    # Display disk list using actual disk index as the selection value
    $displayList = @()
    foreach ($currentDisk in $diskDriveCandidates) {
        $sizeGB = [math]::Round(($currentDisk.Size / 1GB), 2)
        $displayList += [PSCustomObject]@{
            Disk        = $currentDisk.Index
            'Size (GB)' = $sizeGB
            'Sector'    = $currentDisk.BytesPerSector
            'Bus Type'  = $currentDisk.InterfaceType
            Model       = $currentDisk.Model
        }
    }
    $displayList | Format-Table -AutoSize -Property Disk, 'Size (GB)', Sector, 'Bus Type', Model

    $diskSelection = Read-MenuSelection -Prompt 'Enter the disk number to apply the FFU to' -InvalidInputMessage 'Invalid disk number. Please select from the available disks.' -ValidSelections $validDiskIndexes

    $selectedDisk = $diskDriveCandidates | Where-Object { $_.Index -eq $diskSelection }
    WriteLog "Disk selection: DiskNumber=$($selectedDisk.Index), Model=$($selectedDisk.Model), SizeGB=$([math]::Round(($selectedDisk.Size / 1GB), 2)), BusType=$($selectedDisk.InterfaceType)"
    Write-Host "`nDisk $($selectedDisk.Index) selected: $($selectedDisk.Model)"
}

# Set variables from selected disk
$PhysicalDeviceID = $selectedDisk.DeviceID
$BytesPerSector = $selectedDisk.BytesPerSector
$DiskID = $selectedDisk.Index
$diskSizeGB = [math]::Round(($selectedDisk.Size / 1GB), 2)

# Create hardDrive object for Get-SystemInformation compatibility
$hardDrive = [PSCustomObject]@{
    DeviceID       = $PhysicalDeviceID
    BytesPerSector = $BytesPerSector
    DiskSize       = $selectedDisk.Size
    DiskNumber     = $DiskID
}

WriteLog "Physical DeviceID is $PhysicalDeviceID"
WriteLog "DiskNumber is $DiskID with size $diskSizeGB GB"

# Gather and write system information
$sysInfoObject = Get-SystemInformation -HardDrive $hardDrive
Write-SystemInformation -SystemInformation $sysInfoObject

#Find FFU Files
Write-SectionHeader 'FFU File Selection'
[array]$FFUFiles = @(Get-ChildItem -Path "$($DeployRoot)\*.ffu")
$FFUCount = $FFUFiles.Count

#If multiple FFUs found, ask which to install
If ($FFUCount -gt 1) {
    WriteLog "Found $FFUCount FFU Files"
    Write-Host "Found $FFUCount FFU Files"
    $array = @()

    for ($i = 0; $i -le $FFUCount - 1; $i++) {
        $Properties = [ordered]@{Number = $i + 1 ; FFUFile = $FFUFiles[$i].FullName }
        $array += New-Object PSObject -Property $Properties
    }
    $array | Format-Table -AutoSize -Property Number, FFUFile | Out-Host
    $FFUSelected = Read-MenuSelection -Prompt 'Enter the FFU number to install' -InvalidInputMessage 'Input was not in correct format. Please enter a valid FFU number.' -Minimum 1 -Maximum $FFUCount
    $FFUSelected = $FFUSelected - 1

    $FFUFileToInstall = $array[$FFUSelected].FFUFile
    WriteLog "$FFUFileToInstall was selected"
}
elseif ($FFUCount -eq 1) {
    WriteLog "Found $FFUCount FFU File"
    Write-Host "Found $FFUCount FFU File"
    $FFUFileToInstall = $FFUFiles[0].FullName
    WriteLog "$FFUFileToInstall will be installed"
    Write-Host "$FFUFileToInstall will be installed"
} 
else {
    $errorMessage = 'No FFU files found.'
    Writelog $errorMessage
    Stop-Script -Message $errorMessage
}

#FindUnattend
$UnattendFolder = "$($DeployRoot)\unattend"
$UnattendSourceFile = Get-ChildItem -Path "$($UnattendFolder)\unattend.xml"
$UnattendWorkingFilePath = "$($env:TEMP)\unattend.xml"

If (Test-Path -Path $UnattendSourceFile) {
	# Write-Host $UnattendSourceFile
	If ($UnattendSourceFile) {
		try {
			WriteLog "Copying source unattend file $($UnattendSourceFile.FullName) to temporary working file $UnattendWorkingFilePath"
			Copy-Item -Path $UnattendSourceFile.FullName -Destination $UnattendWorkingFilePath -Force -ErrorAction Stop
			$UnattendFile = Get-ChildItem -Path $UnattendWorkingFilePath -ErrorAction Stop
			WriteLog "Using temporary unattend working file $($UnattendFile.FullName)"
			$Unattend = $true
		}
		catch {
            WriteLog "Copying source unattend file to temporary working file failed with error: $_"
            Stop-Script -Message "Copying source unattend file to temporary working file failed with error: $_"
        }
	}
}

$UnattendConfiguredComputerName = $null
$RequiresTemplateDeviceName = $false
if ($Unattend) {
	$UnattendConfiguredComputerName = Get-UnattendComputerNameValue
	if (-not [string]::IsNullOrWhiteSpace($UnattendConfiguredComputerName) -and $UnattendConfiguredComputerName -match '(?i)%serial%') {
        $RequiresTemplateDeviceName = $true
    }
	elseif (-not [string]::IsNullOrWhiteSpace($UnattendConfiguredComputerName) -and $UnattendConfiguredComputerName -eq '*') {
        $RequiresDeviceNameLookup = $true
    }
	$RequiresLegacyDeviceNamePrompt = Test-LegacyPromptComputerName($UnattendConfiguredComputerName)
}

# Look up device name from asset register, failing that, fall back to serial number
if ($RequiresTemplateDeviceName -or $RequiresDeviceNameLookup -or $RequiresLegacyDeviceNamePrompt) {
	$serialNumber = (Get-CimInstance -ClassName Win32_Bios).SerialNumber.Trim()
	Write-SectionHeader 'Device Name Selection'
	if ($Unattend -and $RequiresTemplateDeviceName) {
        Writelog 'Unattend file found with a %serial% computer name template. Resolving the template.'
        Write-Host 'Unattend file found with a %serial% computer name template. Resolving the template.'
        [string]$computername = Set-ConfiguredComputerName((Resolve-ComputerNameTemplate -computerNameTemplate $UnattendConfiguredComputerName -serialNumber $serialNumber))
    }
	elseif ($Unattend -and $RequiresDeviceNameLookup) {
		Writelog 'Looking up device name in asset register'
		Write-Host 'Looking up device name in asset register'

        $headers = @{
            Authorization = "Bearer $($SnipeApiKey)"
            Accept = "application/json"
        }

        $response = (Invoke-RestMethod -Uri "$($SnipeURI)/$($serialNumber)" -Method Get -Headers $headers).rows

        if ($response -ne $null){
            Writelog "Matching asset found. Device name set to $($response.name)."
            Write-Host "Matching asset found. Device name set to $($response.name)."
            [string]$computername = "$($response.name)"           
        } else {
            Writelog "No matching asset found. Falling back to dynamic %serial% naming."
            Write-Host "No matching asset found. Falling back to dynamic %serial% naming."
            [string]$computername = Set-ConfiguredComputerName($serialNumber)
        }
	}
	elseif ($Unattend -and $RequiresLegacyDeviceNamePrompt) {
        Writelog 'Asking for device name'
        Write-Host 'Please enter a device name.'
        [string]$computername = Set-ConfiguredComputerName((Read-Host 'Enter device name'))
    }
	else {
		Writelog 'Unattend file found with a %serial% computer name template. Resolving the template.'
        Write-Host 'Unattend file found with a %serial% computer name template. Resolving the template.'
        [string]$computername = Set-ConfiguredComputerName((Resolve-ComputerNameTemplate -computerNameTemplate $UnattendConfiguredComputerName -serialNumber $serialNumber))
	}

}
elseif ($Unattend) {
    WriteLog 'Unattend file found. Device naming is not required, but unattend settings will still be applied.'
}
else {
    WriteLog 'No unattend folder found. Device name will be set via PPKG, AP JSON, or default OS name.'
}

# Find Drivers
$DriversPath = $DriverRoot
$DriverManufacturerPath = "$($DriversPath)\$($sysInfoObject.ManufacturerNormalized)"
$DriverModelPath = Get-ChildItem -Path $DriverManufacturerPath -Directory -Recurse | Where-Object { $_.Name -like "*$($sysInfoObject.ModelNormalized)*" } | Select-Object -First 1
$DriverSourcePath = $null
$DriverSourceType = $null # Will be 'WIM' or 'Folder'

If (Test-Path -Path $DriversPath) {
    Write-SectionHeader -Title 'Drivers Selection'
}

WriteLog "Searching for driver WIM in $DriversPath"
if ($DriverModelPath) {
    # Get first WIM file in driver model folder
    $wimFiles = Get-ChildItem -Path "$($DriverModelPath.FullName)" -Filter *.wim -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($wimFiles.Count -gt 0){
        WriteLog "Automatic match found: Manufacturer='$($sysInfoObject.ManufacturerNormalized)', Model='$($sysInfoObject.ModelNormalized)'"
        Write-Host "Automatic match found: Manufacturer='$($sysInfoObject.ManufacturerNormalized)', Model='$($sysInfoObject.ModelNormalized)'"
        $DriverSourcePath = $wimFiles.FullName

        WriteLog "Automatically selected driver source. Path: $DriverSourcePath"
        Write-Host "Automatically selected driver source. Path: $DriverSourcePath"
    }
    else {
        WriteLog "Driver folder exists but no WIM file found."
        Write-Host "Driver folder exists but no WIM file found."
    }
}
else {
    WriteLog "No drivers found. Manufactuer: $($sysInfoObject.ManufacturerNormalized), Model: $($sysInfoObject.ModelNormalized)"
    Write-Host "No drivers found. Manufactuer: $($sysInfoObject.ManufacturerNormalized), Model: $($sysInfoObject.ModelNormalized)"
}

#Partition drive
Write-SectionHeader -Title 'Cleaning Disk'
Writelog 'Cleaning Disk'
$originalProgressPreference = $ProgressPreference
try {
    $ProgressPreference = 'SilentlyContinue'
    $Disk = Get-Disk -Number $DiskID
    if ($Disk.PartitionStyle -ne "RAW") {
        WriteLog "Data found on drive - clearing drive..."
        Write-Host "Data found on drive - clearing drive..."
        $Disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
    }
    else {
        WriteLog "Drive is already unformatted. Continuing..."
        Write-Host "Drive is already unformatted. Continuing..."
    }
}
catch {
    WriteLog 'Cleaning disk failed. Exiting'
    throw $_
}
finally {
    $ProgressPreference = $originalProgressPreference
}
Writelog 'Cleaning Disk succeeded'
Write-Host 'Cleaning Disk succeeded'

#Apply FFU
Write-SectionHeader -Title 'Applying FFU'
WriteLog "Applying FFU to $PhysicalDeviceID"
WriteLog "Running command dism /apply-ffu /ImageFile:$FFUFileToInstall /ApplyDrive:$PhysicalDeviceID"
#In order for Applying Image progress bar to show up, need to call dism directly. Might be a better way to handle, but must have progress bar show up on screen.
dism /apply-ffu /ImageFile:$FFUFileToInstall /ApplyDrive:$PhysicalDeviceID
$dismExitCode = $LASTEXITCODE

if ($dismExitCode -ne 0) {
    $errorMessage = "Failed to apply FFU. LastExitCode = $dismExitCode."
    if ($dismExitCode -eq 1393) {
        WriteLog "Failed to apply FFU - LastExitCode = $dismExitCode"
        WriteLog "This is likely due to a mismatched LogicalSectorSizeBytes"
        WriteLog "BytesPerSector value from Win32_Diskdrive is $BytesPerSector"
        if ($BytesPerSector -eq 4096) {
            WriteLog "The FFU build process by default uses a 512 LogicalSectorSizeBytes. Rebuild the FFU by adding -LogicalSectorSizeBytes 4096 to the command line"
        }
        elseif ($BytesPerSector -eq 512) {
            WriteLog "This FFU was likely built with a LogicalSectorSizeBytes of 4096. Rebuild the FFU by adding -LogicalSectorSizeBytes 512 to the command line"
        }
        $errorMessage += " This is likely due to a mismatched logical sector size. Check logs for details."
    }
    else {
        Writelog "Failed to apply FFU - LastExitCode = $dismExitCode also check dism.log on the USB drive for more info"
        $errorMessage += " Check dism.log on the USB drive for more info."
    }
    Stop-Script -Message $errorMessage
}

WriteLog 'Successfully applied FFU'

# Verify Windows partition exists and assign drive letter
$windowsPartition = Get-WindowsPartitionFromAppliedDisk -DiskNumber $DiskID
if ($null -eq $windowsPartition) {
    $errorMessage = "Windows partition not found after applying FFU, even though DISM reported success."
    WriteLog $errorMessage
    Stop-Script -Message $errorMessage
}

WriteLog "Assigning drive letter 'W' to Windows partition."
Write-Host "Assigning drive letter 'W' to Windows partition."
Set-Partition -InputObject $windowsPartition -NewDriveLetter W

# Verify the drive letter was set
$windowsVolume = Get-Volume -DriveLetter W -ErrorAction SilentlyContinue
if ($null -eq $windowsVolume) {
    $errorMessage = "Failed to assign drive letter 'W' to the Windows partition after applying FFU."
    WriteLog $errorMessage
    Stop-Script -Message $errorMessage
}
WriteLog "Successfully assigned drive letter 'W'."

$recoveryPartition = Get-Partition -DiskNumber $DiskID | Where-Object Type -eq Recovery | Select-Object -First 1
if ($recoveryPartition) {
    WriteLog 'Setting recovery partition attributes'
    Write-Host 'Setting recovery partition attributes'
    $diskpartScript = @(
        "SELECT DISK $($Disk.Number)",
        "SELECT PARTITION $($recoveryPartition.PartitionNumber)",
        "GPT ATTRIBUTES=0x8000000000000001",
        "EXIT"
    )
    $diskpartScript | diskpart.exe | Out-Null
    WriteLog 'Setting recovery partition attributes complete'
    Write-Host 'Setting recovery partition attributes complete'
}

#Copy modified WinRE if folder exists, else copy inbox WinRE
$WinRE = "$($DeployRoot)\winre\winre.wim"
If (Test-Path -Path $WinRE) {
    WriteLog 'Copying modified WinRE to Recovery directory'
    Write-Host 'Copying modified WinRE to Recovery directory'
    if ($null -eq $recoveryPartition) {
        $errorMessage = 'Recovery partition not found after applying FFU. Cannot copy modified WinRE.'
        WriteLog $errorMessage
        Stop-Script -Message $errorMessage
    }
    Set-Partition -InputObject $recoveryPartition -NewDriveLetter R
    Invoke-Process xcopy.exe "/h $WinRE R:\Recovery\WindowsRE\ /Y"
    WriteLog 'Copying WinRE to Recovery directory succeeded'
    Write-Host 'Copying WinRE to Recovery directory succeeded'
    WriteLog 'Registering location of recovery tools'
    Write-Host 'Registering location of recovery tools'
    Invoke-Process W:\Windows\System32\Reagentc.exe "/Setreimage /Path R:\Recovery\WindowsRE /Target W:\Windows"
    Remove-PartitionAccessPath -InputObject $recoveryPartition -AccessPath R:
    WriteLog 'Registering location of recovery tools succeeded'
    Write-Host 'Registering location of recovery tools succeeded'
}

#Set DeviceName
If ($Unattend) {
    $unattendSectionTitle = if ($computername) { 'Applying Computer Name and Unattend Configuration' } else { 'Applying Unattend Configuration' }
    Write-SectionHeader -Title $unattendSectionTitle
    try {
        $PantherDir = "W:\Windows\panther"
        If (Test-Path -Path $PantherDir) {
            Writelog "Copying $UnattendFile to $PantherDir"
            Write-Host "Copying $UnattendFile to $PantherDir"
            Invoke-process xcopy "$UnattendFile $PantherDir /Y"
            WriteLog "Copying $UnattendFile to $PantherDir succeeded"
            Write-Host "Copying $UnattendFile to $PantherDir succeeded"
        }
        else {
            Writelog "$PantherDir doesn't exist, creating it"
            New-Item -Path $PantherDir -ItemType Directory -Force
            Writelog "Copying $UnattendFile to $PantherDir"
            Write-Host "Copying $UnattendFile to $PantherDir"
            Invoke-Process xcopy.exe "$UnattendFile $PantherDir"
            WriteLog "Copying $UnattendFile to $PantherDir succeeded"
            Write-Host "Copying $UnattendFile to $PantherDir succeeded"
        }
    }
    catch {
        WriteLog 'Copying Unattend.xml to Panther failed'
        Stop-Script -Message "Copying Unattend.xml to Panther failed with error: $_"
    }
}

# Add Drivers
if ($null -ne $DriverSourcePath) {
    Write-SectionHeader -Title 'Installing Drivers'
    WriteLog "Installing drivers from WIM: $DriverSourcePath"
    Write-Host "Installing drivers from WIM: $DriverSourcePath"
    $TempDriverDir = "W:\TempDrivers"
    try {
        # Create working folder for WIM-based drivers
        WriteLog "Creating temporary directory for drivers at $TempDriverDir"
        New-Item -Path $TempDriverDir -ItemType Directory -Force | Out-Null

        # Mount the driver WIM read-only so DISM can recurse the extracted INF tree
        WriteLog "Mounting WIM contents to $TempDriverDir"
        Write-Host "Mounting WIM contents to $TempDriverDir"
        # For some reason can't use /mount-image with invoke-process, so using dism.exe directly
        dism.exe /Mount-Image /ImageFile:$DriverSourcePath /Index:1 /MountDir:$TempDriverDir /ReadOnly /optimize
        $mountExitCode = $LASTEXITCODE
        if ($mountExitCode -ne 0) {
            throw "DISM WIM mount failed. LastExitCode = $mountExitCode."
        }
        WriteLog "WIM mount successful."

        # Inject drivers into the offline Windows image; failures here should not stop deployment
        WriteLog "Injecting drivers from $TempDriverDir"
        Write-Host "Injecting drivers from $TempDriverDir"
        Write-Host "This may take a while, please be patient."
        $driverInjectExitCode = Invoke-Process -FilePath dism.exe -ArgumentList "/image:W:\ /Add-Driver /Driver:""$TempDriverDir"" /Recurse" -IgnoreExitCode -PassThruExitCode
        if ($driverInjectExitCode -ne 0) {
            $warningMessage = "Warning: One or more drivers failed to inject from WIM. ExitCode = $driverInjectExitCode. Continuing deployment."
            WriteLog $warningMessage
            Write-Host $warningMessage -ForegroundColor Yellow

            # Copy setupapi.offline.log to DeployRoot when driver injection fails
            $setupApiLogPath = 'W:\Windows\INF\setupapi.offline.log'
            if (Test-Path -Path $setupApiLogPath) {
                try {
                    Invoke-Process xcopy.exe """$setupApiLogPath"" ""$LogRoot"" /Y"
                }
                catch {
                    WriteLog "Warning: Failed to copy setupapi.offline.log to $LogRoot. "
                }
            }
            else {
                WriteLog "Warning: setupapi.offline.log not found at $setupApiLogPath"
            }
        }
        else {
            WriteLog "Driver injection from WIM succeeded."
            Write-Host "Driver injection from WIM succeeded."
        }
    }
    catch {
        $warningMessage = "Warning: An error occurred during WIM driver installation. Continuing deployment."
        WriteLog $warningMessage
        Write-Host $warningMessage -ForegroundColor Yellow

        # Copy troubleshooting logs to DeployRoot when driver installation fails
        try {
            Invoke-Process cmd.exe "/c copy /Y ""X:\Windows\logs\dism\dism.log"" ""$($LogRoot)dism_driverinject.log"""
        }
        catch {
            WriteLog "Warning: Failed to copy dism.log to $LogRoot." 
        }

        $setupApiLogPath = 'W:\Windows\INF\setupapi.offline.log'
        if (Test-Path -Path $setupApiLogPath) {
            try {
                Invoke-Process xcopy.exe """$setupApiLogPath"" ""$LogRoot"" /Y"
            }
            catch {
                WriteLog "Warning: Failed to copy setupapi.offline.log to $LogRoot."
            }
        }
        else {
            WriteLog "Warning: setupapi.offline.log not found at $setupApiLogPath"
        }
    }
    finally {
        if (Test-Path -Path $TempDriverDir) {
            # Always attempt to unmount and clean up; unmount failures should not stop deployment
            WriteLog "Unmounting WIM from $TempDriverDir"
            Write-Host "Unmounting WIM from $TempDriverDir"
            try {
                Invoke-Process dism.exe "/Unmount-Image /MountDir:""$TempDriverDir"" /Discard"
                WriteLog "Unmount successful."
                Write-Host "Unmount successful."
            }
            catch {
                $warningMessage = "Warning: Failed to unmount WIM from $TempDriverDir. Continuing cleanup."
                WriteLog $warningMessage
                Write-Host $warningMessage -ForegroundColor Yellow
            }

            WriteLog "Cleaning up temporary driver directory: $TempDriverDir"
            Write-Host "Cleaning up temporary driver directory: $TempDriverDir"
            try {
                Remove-Item -Path $TempDriverDir -Recurse -Force
                WriteLog "Cleanup successful."
                Write-Host "Cleanup successful."
            }
            catch {
                $warningMessage = "Warning: Failed to clean up temporary driver directory: $TempDriverDir."
                WriteLog $warningMessage
                Write-Host $warningMessage -ForegroundColor Yellow
            }
        }
    }
}
else {
    WriteLog "No drivers to install."
    Write-Host "No drivers to install."
}

# Set boot configuration
Write-SectionHeader -Title 'Setting Boot Configuration'
WriteLog "Setting Windows Boot Manager to be first in the firmware display order."
Write-Host "Setting Windows Boot Manager to be first in the firmware display order."
Invoke-Process bcdedit.exe "/set {fwbootmgr} displayorder {bootmgr} /addfirst"
WriteLog "Setting Windows Boot Manager to be first in the default display order."
Write-Host "Setting Windows Boot Manager to be first in the default display order."
Invoke-Process bcdedit.exe "/set {bootmgr} displayorder {default} /addfirst"

#Copy DISM log to USBDrive
WriteLog "Copying dism log to $LogRoot"
invoke-process xcopy "X:\Windows\logs\dism\dism.log $LogRoot /Y" 
WriteLog "Copying dism log to $LogRoot succeeded"