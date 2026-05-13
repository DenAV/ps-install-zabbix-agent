#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs or updates Zabbix Agent 2 on Windows via MSI (silent/unattended).

.DESCRIPTION
    Queries the Zabbix server API to determine the current server version, then downloads
    and installs the matching Zabbix Agent 2 MSI package silently with PSK encryption.
    After installation, registers the host in Zabbix server via API (host.create) with
    the correct host group, template, PSK configuration, and a Location tag.
    Supports fresh install and in-place upgrade. The MSI installer handles:
    - Service creation (delayed auto-start)
    - Configuration file generation
    - PSK file creation
    - Windows Firewall exception
    - Upgrade over existing version
    Supports monitoring via Zabbix Server directly or via a Zabbix Proxy.

.PARAMETER ZabbixServerAddress
    IP address or DNS name of the Zabbix server. Used for API version query and agent config.

.PARAMETER ZabbixApiUrl
    Full URL to the Zabbix API endpoint. Defaults to https://<ZabbixServerAddress>/api_jsonrpc.php.

.PARAMETER ZabbixAuthToken
    API authentication token (Bearer) for host.create and other authenticated API calls.
    Create the token in Zabbix UI under Administration > General > API tokens.

.PARAMETER HostGroupName
    Host group name to assign the host to. Defaults to 'Windows Servers'.
    The group must already exist on the Zabbix server.

.PARAMETER TemplateName
    Template name to link to the host. Defaults to 'Windows by Zabbix agent active'.
    The template must already exist on the Zabbix server.

.PARAMETER MonitoredBy
    Determines whether the host is monitored directly by the Zabbix Server or via a Zabbix Proxy.
    Accepted values: 'server' (default) or 'proxy'.
    When set to 'proxy', ZabbixProxyName must also be provided.

.PARAMETER ZabbixProxyName
    Name of the Zabbix Proxy as configured in the Zabbix UI.
    Required when MonitoredBy is set to 'proxy'.
    Used for API lookup (proxy.get) and as the agent connection address when ZabbixProxyAddress is not specified.

.PARAMETER ZabbixProxyAddress
    FQDN or IP address the Zabbix agent uses to connect to the proxy.
    Optional. Use when the proxy name in Zabbix is a short hostname but the agent must connect via FQDN or IP.
    Example: 'fkblvs-zbbxp1.example.com'
    If not specified, ZabbixProxyName is used as the connection address.

.PARAMETER Location
    Location value assigned as a Zabbix host tag (key: 'Location').
    Mandatory. Used downstream for automatic host group assignment via tag-based actions.

.PARAMETER LocalMsiPath
    Path to a local or network MSI package to use instead of downloading from cdn.zabbix.com.
    Use when the target server has no internet access.
    Example: '\\fileserver\share\zabbix_agent2-7.4.9-windows-amd64-openssl.msi'

.EXAMPLE
    .\Zabbix-Install-Agent-MSI.ps1 -ZabbixServerAddress '192.0.2.10' -ZabbixAuthToken 'your-api-token' -Location 'HO'

.EXAMPLE
    .\Zabbix-Install-Agent-MSI.ps1 -ZabbixServerAddress '192.0.2.10' -ZabbixAuthToken 'your-api-token' -Location 'HO' -LocalMsiPath '\\fileserver\share\zabbix_agent2-7.4.9-windows-amd64-openssl.msi'

.EXAMPLE
    .\Zabbix-Install-Agent-MSI.ps1 -ZabbixServerAddress 'zabbix.example.com' -ZabbixAuthToken 'your-api-token' -Location 'HO' -HostGroupName 'Linux Servers' -TemplateName 'Linux by Zabbix agent active'

.EXAMPLE
    .\Zabbix-Install-Agent-MSI.ps1 -ZabbixServerAddress '192.0.2.10' -ZabbixAuthToken 'your-api-token' -Location 'HO' -MonitoredBy 'proxy' -ZabbixProxyName 'proxy-HO-01'

.EXAMPLE
    .\Zabbix-Install-Agent-MSI.ps1 -ZabbixServerAddress '192.0.2.10' -ZabbixAuthToken 'your-api-token' -Location 'HO' -MonitoredBy 'proxy' -ZabbixProxyName 'proxy-HO-01' -ZabbixProxyAddress 'proxy-HO-01.example.com'
    # Use when the proxy name in Zabbix is a short hostname but the agent must connect via FQDN or IP.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ZabbixServerAddress,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ZabbixAuthToken,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ZabbixApiUrl,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$HostGroupName = 'Windows Servers',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TemplateName = 'Windows by Zabbix agent active',

    [Parameter()]
    [ValidateSet('server', 'proxy')]
    [string]$MonitoredBy = 'server',

    [Parameter()]
    [string]$ZabbixProxyName,

    [Parameter()]
    [string]$ZabbixProxyAddress,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [Parameter()]
    [string]$LocalMsiPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration
$installFolder = 'C:\Program Files\Zabbix Agent 2'
$tempDir       = Join-Path $env:TEMP 'ZabbixInstall'
$logPath       = Join-Path $tempDir 'zabbix-install.log'
$hostName      = $env:COMPUTERNAME
$hostFqdn      = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName

if (-not $ZabbixApiUrl) {
    $ZabbixApiUrl = "https://$ZabbixServerAddress/api_jsonrpc.php"
}

# Enforce TLS 1.2 for all web requests in this session
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($MonitoredBy -eq 'proxy' -and [string]::IsNullOrWhiteSpace($ZabbixProxyName)) {
    Write-Error "Parameter -ZabbixProxyName is required when -MonitoredBy is 'proxy'."
    return
}

Write-Host "Monitoring mode: $(if ($MonitoredBy -eq 'proxy') { "Proxy '$ZabbixProxyName'" } else { 'Server' })" -ForegroundColor Cyan
Write-Host "Location: $Location" -ForegroundColor Cyan

# Shared headers for authenticated API calls
$apiHeaders = @{
    'Content-Type'  = 'application/json-rpc'
    'Authorization' = "Bearer $ZabbixAuthToken"
}
#endregion

#region Helper — Invoke-ZabbixApiCall
function Invoke-ZabbixApiCall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][hashtable]$Params,
        [switch]$NoAuth
    )

    $body = @{
        jsonrpc = '2.0'
        method  = $Method
        params  = $Params
        id      = 1
    } | ConvertTo-Json -Depth 8 -Compress

    $splat = @{
        Uri             = $ZabbixApiUrl
        Method          = 'Post'
        Body            = $body
        ContentType     = 'application/json-rpc'
        UseBasicParsing = $true
    }
    if (-not $NoAuth) {
        $splat['Headers'] = $apiHeaders
    }

    $response = Invoke-RestMethod @splat

    if ($response.PSObject.Properties['error']) {
        throw "Zabbix API error ($Method): $($response.error.message) - $($response.error.data)"
    }

    return $response.result
}
#endregion

#region Query Zabbix server version via API
Write-Host "Querying Zabbix server version from $ZabbixApiUrl ..." -ForegroundColor Cyan

try {
    $zabbixRelease = Invoke-ZabbixApiCall -Method 'apiinfo.version' -Params @{} -NoAuth
} catch {
    Write-Error "Failed to query Zabbix API version: $($_.Exception.Message)"
    return
}

if (-not $zabbixRelease) {
    Write-Error 'Unexpected API response - no version returned.'
    return
}

$zabbixVersion = ($zabbixRelease -split '\.')[0..1] -join '.'
Write-Host "Zabbix server version: $zabbixRelease (major: $zabbixVersion)" -ForegroundColor Green
#endregion
#region Resolve Zabbix Proxy
$proxyId      = $null
$proxyAddress = $null

if ($MonitoredBy -eq 'proxy') {
    Write-Host "Resolving proxy '$ZabbixProxyName' ..." -ForegroundColor Cyan

    try {
        $proxyResult = @(Invoke-ZabbixApiCall -Method 'proxy.get' -Params @{
            filter = @{ name = $ZabbixProxyName }
            output = @('proxyid', 'name', 'address')
        })
    } catch {
        Write-Error "Failed to query proxy '$ZabbixProxyName': $($_.Exception.Message)"
        return
    }

    if ($proxyResult.Count -eq 0) {
        Write-Error "Proxy '$ZabbixProxyName' not found on Zabbix server."
        return
    }

    $proxyId      = $proxyResult[0].proxyid
    # Use ZabbixProxyAddress if provided (e.g. FQDN when proxy name in Zabbix is a short hostname).
    # Fall back to ZabbixProxyName. Never use the API 'address' field — it is always 127.0.0.1
    # for active proxies (the proxy initiates the connection to the server).
    $proxyAddress = if (-not [string]::IsNullOrWhiteSpace($ZabbixProxyAddress)) { $ZabbixProxyAddress } else { $ZabbixProxyName }
    Write-Host "Proxy '$ZabbixProxyName' found (proxyid: $proxyId, agent address: $proxyAddress)" -ForegroundColor Green
}
#endregion
#region Derived paths
$msiFileName = "zabbix_agent2-$zabbixRelease-windows-amd64-openssl.msi"
$msiUrl      = "https://cdn.zabbix.com/zabbix/binaries/stable/$zabbixVersion/$zabbixRelease/$msiFileName"
$msiPath     = Join-Path $tempDir $msiFileName
#endregion

#region Check existing installation
$agentExe = Join-Path $installFolder 'zabbix_agent2.exe'
$skipInstall = $false
if (Test-Path -Path $agentExe -PathType Leaf) {
    $existingVersion = (Get-Item -Path $agentExe).VersionInfo.ProductVersion
    if ($existingVersion -eq $zabbixRelease) {
        Write-Host "Zabbix Agent 2 $zabbixRelease is already installed." -ForegroundColor Green
        $svc = Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Start-Service -Name 'Zabbix Agent 2'
            Write-Host 'Service was stopped. Started Zabbix Agent 2.' -ForegroundColor Yellow
        }
        $skipInstall = $true
    } else {
        Write-Host "Existing version $existingVersion found. Upgrading to $zabbixRelease ..." -ForegroundColor Yellow
    }
}
#endregion

#region PSK identity (used for both install and host registration)
$pskIdentity = "$($env:COMPUTERNAME)_identity"
#endregion

if ($skipInstall) {
    #region Read existing PSK from installed agent
    $pskFile = Join-Path $installFolder 'psk.key'
    if (Test-Path -Path $pskFile -PathType Leaf) {
        $pskValue = (Get-Content -Path $pskFile -Raw).Trim()
        Write-Host "Read existing PSK from '$pskFile'." -ForegroundColor Cyan
    } else {
        Write-Warning "PSK file not found at '$pskFile'. Host registration may fail."
        $pskValue = ''
    }
    #endregion
} else {
    #region Generate PSK
    $pskBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($pskBytes)
    $pskValue = [BitConverter]::ToString($pskBytes).Replace('-', '').ToLower()
    #endregion

    #region Download MSI
    if (-not (Test-Path -Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $msiPath -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($LocalMsiPath)) {
            # Use pre-provided path — strip surrounding quotes from copy-paste
            $LocalMsiPath = $LocalMsiPath.Trim().Trim('"').Trim("'")
            if (-not (Test-Path -Path $LocalMsiPath -PathType Leaf)) {
                Write-Error "LocalMsiPath file not found: '$LocalMsiPath'. Installation aborted."
                return
            }
            Copy-Item -Path $LocalMsiPath -Destination $msiPath -Force
            Write-Host "MSI copied from '$LocalMsiPath'." -ForegroundColor Green
        } else {
            # Test connectivity to cdn.zabbix.com before attempting download
            $canDownload = $false
            try {
                $null = Invoke-WebRequest -Uri "https://cdn.zabbix.com" -Method Head -UseBasicParsing -TimeoutSec 10
                $canDownload = $true
            } catch {
                Write-Warning "Cannot reach cdn.zabbix.com: $($_.Exception.Message)"
            }

            if ($canDownload) {
                Write-Host "Downloading Zabbix Agent 2 MSI from $msiUrl ..." -ForegroundColor Cyan
                Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
                Write-Host 'Download completed.' -ForegroundColor Green
            } else {
                Write-Host 'No internet access. Please provide the path to the MSI package.' -ForegroundColor Yellow
                Write-Host "Expected filename: $msiFileName" -ForegroundColor Yellow
                Write-Host 'Enter local or network path to MSI (or press Enter to abort): ' -ForegroundColor Yellow -NoNewline
                $inputPath = Read-Host

                if ([string]::IsNullOrWhiteSpace($inputPath)) {
                    Write-Error 'No MSI path provided. Installation aborted.'
                    return
                }

                # Strip surrounding quotes that users often copy from Explorer or CMD
                $inputPath = $inputPath.Trim().Trim('"').Trim("'")

                if (-not (Test-Path -Path $inputPath -PathType Leaf)) {
                    Write-Error "File not found: '$inputPath'. Installation aborted."
                    return
                }

                Copy-Item -Path $inputPath -Destination $msiPath -Force
                Write-Host "MSI copied from '$inputPath'." -ForegroundColor Green
            }
        }
    } else {
        Write-Host "MSI file already exists at '$msiPath'. Skipping download." -ForegroundColor Yellow
    }
    #endregion

    #region Install via MSI
    Write-Host "Installing Zabbix Agent 2 $zabbixRelease ..." -ForegroundColor Cyan

    $agentServerAddress = if ($MonitoredBy -eq 'proxy') { $proxyAddress } else { $ZabbixServerAddress }

    $msiArgs = @(
        '/l*v', "`"$logPath`""
        '/i', "`"$msiPath`""
        '/qn'
        "ADDDEFAULT=ALL"
        "SERVER=$agentServerAddress"
        "SERVERACTIVE=$agentServerAddress"
        "HOSTNAME=$($env:COMPUTERNAME)"
        "INSTALLFOLDER=`"$installFolder`""
        "TLSCONNECT=psk"
        "TLSACCEPT=psk"
        "TLSPSKIDENTITY=$pskIdentity"
        "TLSPSKVALUE=$pskValue"
        "ENABLEPATH=1"
    )

    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Error "MSI installation failed with exit code $($process.ExitCode). Check log: $logPath"
        return
    }

    Write-Host 'MSI installation completed.' -ForegroundColor Green
    #endregion

    #region Verify installation
    $svc = Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Error "Zabbix Agent 2 service not found after installation. Check log: $logPath"
        return
    }

    if ($svc.Status -ne 'Running') {
        Start-Service -Name 'Zabbix Agent 2'
    }

    Write-Host "Zabbix Agent 2 $zabbixRelease installed and running." -ForegroundColor Green
    #endregion
}

#region Register host in Zabbix server via API
Write-Host 'Registering host in Zabbix server ...' -ForegroundColor Cyan

# Check if host already exists (search by technical name, visible name, and FQDN)
$existingHost = @()
try {
    # 1. Search by technical name (short hostname)
    $existingHost = @(Invoke-ZabbixApiCall -Method 'host.get' -Params @{
        filter = @{ host = $hostName }
        output = @('hostid', 'host', 'name')
    })

    # 2. Fallback: search by visible name
    if ($existingHost.Count -eq 0) {
        $existingHost = @(Invoke-ZabbixApiCall -Method 'host.get' -Params @{
            filter = @{ name = $hostName }
            output = @('hostid', 'host', 'name')
        })
    }

    # 3. Fallback: search by FQDN as technical name
    if ($existingHost.Count -eq 0 -and $hostFqdn -ne $hostName) {
        $existingHost = @(Invoke-ZabbixApiCall -Method 'host.get' -Params @{
            filter = @{ host = $hostFqdn }
            output = @('hostid', 'host', 'name')
        })
    }

    # 4. Fallback: search by FQDN as visible name
    if ($existingHost.Count -eq 0 -and $hostFqdn -ne $hostName) {
        $existingHost = @(Invoke-ZabbixApiCall -Method 'host.get' -Params @{
            filter = @{ name = $hostFqdn }
            output = @('hostid', 'host', 'name')
        })
    }
} catch {
    Write-Warning "Failed to check existing host: $($_.Exception.Message)"
    $existingHost = @()
}

if ($existingHost.Count -gt 0) {
    Write-Host "Found existing host: technical='$($existingHost[0].host)', visible='$($existingHost[0].name)'" -ForegroundColor Cyan
}

# Determine host IP address (needed for both create and update)
$ipAddresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -Property IPAddress, InterfaceAlias)

if ($ipAddresses.Count -eq 0) {
    $hostIp = '0.0.0.0'
    Write-Warning 'Could not determine host IP address. Using 0.0.0.0 - update manually in Zabbix.'
} elseif ($ipAddresses.Count -eq 1) {
    $hostIp = $ipAddresses[0].IPAddress
    Write-Host "Using IP address: $hostIp ($($ipAddresses[0].InterfaceAlias))" -ForegroundColor Cyan
} else {
    Write-Host "`nMultiple IPv4 addresses found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $ipAddresses.Count; $i++) {
        Write-Host "  [$i] $($ipAddresses[$i].IPAddress)  ($($ipAddresses[$i].InterfaceAlias))" -ForegroundColor White
    }
    Write-Host "`nSelect IP address [0-$($ipAddresses.Count - 1)] (default: 0 in 10 seconds): " -ForegroundColor Yellow -NoNewline

    $choice = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 10) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadLine()
            if ($key -match '^\d+$' -and [int]$key -ge 0 -and [int]$key -lt $ipAddresses.Count) {
                $choice = [int]$key
            }
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $stopwatch.Stop()

    if ($null -eq $choice) {
        $choice = 0
        Write-Host "`nNo selection - using default [0]." -ForegroundColor Yellow
    }

    $hostIp = $ipAddresses[$choice].IPAddress
    Write-Host "Selected IP: $hostIp ($($ipAddresses[$choice].InterfaceAlias))" -ForegroundColor Green
}

# Resolve host group ID (needed for both create and update)
$hostGroupResult = @(Invoke-ZabbixApiCall -Method 'hostgroup.get' -Params @{
    filter = @{ name = $HostGroupName }
    output = @('groupid')
})

if ($hostGroupResult.Count -eq 0) {
    Write-Host "Host group '$HostGroupName' not found. Creating ..." -ForegroundColor Cyan
    try {
        $createGroupResult = Invoke-ZabbixApiCall -Method 'hostgroup.create' -Params @{
            name = $HostGroupName
        }
        $groupId = $createGroupResult.groupids[0]
        Write-Host "Host group '$HostGroupName' created (groupid: $groupId)." -ForegroundColor Green
    } catch {
        Write-Error "Failed to create host group '$HostGroupName': $($_.Exception.Message)"
        return
    }
} else {
    $groupId = $hostGroupResult[0].groupid
}

# Resolve template ID (needed for both create and update)
$templateResult = @(Invoke-ZabbixApiCall -Method 'template.get' -Params @{
    filter = @{ host = $TemplateName }
    output = @('templateid')
})

if ($templateResult.Count -eq 0) {
    Write-Error "Template '$TemplateName' not found on Zabbix server. Create it first or specify a different template."
    return
}
$templateId = $templateResult[0].templateid

if ($existingHost.Count -gt 0) {
    $hostId = $existingHost[0].hostid
    Write-Host "Host '$hostName' already exists in Zabbix (hostid: $hostId). Updating configuration ..." -ForegroundColor Yellow

    # Check if a Zabbix agent interface (type=1) already exists
    $interfaces = @(Invoke-ZabbixApiCall -Method 'hostinterface.get' -Params @{
        hostids = $hostId
        output  = 'extend'
    })

    $agentInterface = $interfaces | Where-Object { $_.type -eq '1' }

    if ($agentInterface) {
        if ($agentInterface.ip -ne $hostIp) {
            Write-Host "Updating agent interface IP: $($agentInterface.ip) -> $hostIp" -ForegroundColor Yellow
            try {
                Invoke-ZabbixApiCall -Method 'hostinterface.update' -Params @{
                    interfaceid = $agentInterface.interfaceid
                    ip          = $hostIp
                } | Out-Null
                Write-Host 'Agent interface IP updated.' -ForegroundColor Green
            } catch {
                Write-Warning "Failed to update interface IP: $($_.Exception.Message)"
            }
        } else {
            Write-Host "Zabbix agent interface already exists with correct IP (interfaceid: $($agentInterface.interfaceid))." -ForegroundColor Green
        }
    } else {
        # Add Zabbix agent interface to existing host
        Write-Host "No Zabbix agent interface found. Adding agent interface ..." -ForegroundColor Cyan
        try {
            Invoke-ZabbixApiCall -Method 'hostinterface.create' -Params @{
                hostid = $hostId
                type   = 1
                main   = 1
                useip  = 1
                ip     = $hostIp
                dns    = ''
                port   = '10050'
            } | Out-Null
            Write-Host "Zabbix agent interface added to host '$hostName'." -ForegroundColor Green
        } catch {
            Write-Error "Failed to add agent interface: $($_.Exception.Message)"
            return
        }
    }

    # Merge existing host groups with the target group (additive)
    # Zabbix 7.x: selectGroups deprecated, use selectHostGroups (response property: hostgroups)
    $currentGroups = @(Invoke-ZabbixApiCall -Method 'host.get' -Params @{
        hostids          = $hostId
        selectHostGroups = @('groupid')
        selectTags       = 'extend'
        output           = @('hostid')
    })
    $existingGroups = @()
    if ($currentGroups.Count -gt 0 -and $currentGroups[0].PSObject.Properties['hostgroups']) {
        $existingGroups = @($currentGroups[0].hostgroups)
    }
    $existingTags = @()
    if ($currentGroups.Count -gt 0 -and $currentGroups[0].PSObject.Properties['tags']) {
        $existingTags = @($currentGroups[0].tags)
    }
    $mergedGroups = @($existingGroups | ForEach-Object { @{ groupid = $_.groupid } })
    $groupAdded = $false
    if (-not ($mergedGroups | Where-Object { $_.groupid -eq $groupId })) {
        $mergedGroups += @{ groupid = $groupId }
        $groupAdded = $true
    }

    # Merge existing templates with the target template (additive)
    $currentTemplates = @(Invoke-ZabbixApiCall -Method 'host.get' -Params @{
        hostids               = $hostId
        selectParentTemplates = @('templateid', 'host')
        output                = @('hostid')
    })
    $existingTemplates = @()
    if ($currentTemplates.Count -gt 0 -and $currentTemplates[0].PSObject.Properties['parentTemplates']) {
        $existingTemplates = @($currentTemplates[0].parentTemplates)
    }

    # Auto-remove SNMP templates (conflict with agent templates)
    # Use templates_clear to properly unlink and remove inherited items/inventory bindings
    $snmpTemplates = @($existingTemplates | Where-Object { $_.host -and $_.host -match 'SNMP' })
    $templatesToClear = @($snmpTemplates | ForEach-Object { @{ templateid = $_.templateid } })
    $existingTemplates = @($existingTemplates | Where-Object { -not ($_.host -and $_.host -match 'SNMP') })
    if ($templatesToClear.Count -gt 0) {
        $removedNames = @($snmpTemplates | ForEach-Object { $_.host })
        Write-Host "Removing SNMP templates: $($removedNames -join ', ')" -ForegroundColor Yellow
    }

    $mergedTemplates = @($existingTemplates | ForEach-Object { @{ templateid = $_.templateid } })
    $templateAdded = $false
    if (-not ($mergedTemplates | Where-Object { $_.templateid -eq $templateId })) {
        $mergedTemplates += @{ templateid = $templateId }
        $templateAdded = $true
    }

    # Update host: PSK, host groups (merged), templates (merged), monitored_by, and tags
    # templates_clear removes SNMP templates including their inherited items and inventory bindings
    try {
        # Merge Location tag into existing tags (keep all others, overwrite Location if changed)
        $mergedTags = @($existingTags | Where-Object { $_.tag -ne 'Location' } | ForEach-Object { @{ tag = $_.tag; value = $_.value } })
        $mergedTags += @{ tag = 'Location'; value = $Location }

        $updateParams = @{
            hostid           = $hostId
            groups           = $mergedGroups
            templates        = $mergedTemplates
            tls_connect      = 2
            tls_accept       = 2
            tls_psk_identity = $pskIdentity
            tls_psk          = $pskValue
            monitored_by     = if ($MonitoredBy -eq 'proxy') { 1 } else { 0 }
            tags             = $mergedTags
        }
        if ($MonitoredBy -eq 'proxy') {
            $updateParams['proxyid'] = $proxyId
        }
        if ($templatesToClear.Count -gt 0) {
            $updateParams['templates_clear'] = $templatesToClear
        }
        Invoke-ZabbixApiCall -Method 'host.update' -Params $updateParams | Out-Null

        Write-Host "Host '$hostName' updated:" -ForegroundColor Green
        if ($groupAdded) { Write-Host "  + Group '$HostGroupName' added" -ForegroundColor Green } else { Write-Host "  - Group '$HostGroupName' already assigned" -ForegroundColor DarkGray }
        if ($templateAdded) { Write-Host "  + Template '$TemplateName' added" -ForegroundColor Green } else { Write-Host "  - Template '$TemplateName' already assigned" -ForegroundColor DarkGray }
        if ($templatesToClear.Count -gt 0) { Write-Host '  + SNMP templates removed' -ForegroundColor Yellow }
        Write-Host '  + PSK configured' -ForegroundColor Green
        Write-Host "  + Monitored by: $(if ($MonitoredBy -eq 'proxy') { "Proxy '$ZabbixProxyName' (proxyid: $proxyId)" } else { 'Server' })" -ForegroundColor Green
        Write-Host "  + Tag Location: $Location" -ForegroundColor Green
    } catch {
        Write-Error "Failed to update host: $($_.Exception.Message)"
        Write-Host "PSK Identity: $pskIdentity" -ForegroundColor Yellow
        Write-Host "PSK Value:    $pskValue" -ForegroundColor Yellow
        return
    }
} else {
    # Create host with PSK encryption (tls_connect=2, tls_accept=2 = PSK)
    $hostCreateParams = @{
        host       = $hostName
        interfaces = @(
            @{
                type  = 1
                main  = 1
                useip = 1
                ip    = $hostIp
                dns   = ''
                port  = '10050'
            }
        )
        groups     = @(
            @{ groupid = $groupId }
        )
        templates  = @(
            @{ templateid = $templateId }
        )
        tls_connect      = 2
        tls_accept       = 2
        tls_psk_identity = $pskIdentity
        tls_psk          = $pskValue
        monitored_by     = if ($MonitoredBy -eq 'proxy') { 1 } else { 0 }
        tags             = @(
            @{ tag = 'Location'; value = $Location }
        )
    }
    if ($MonitoredBy -eq 'proxy') {
        $hostCreateParams['proxyid'] = $proxyId
    }

    try {
        $createResult = Invoke-ZabbixApiCall -Method 'host.create' -Params $hostCreateParams
        Write-Host "Host '$hostName' created in Zabbix (hostid: $($createResult.hostids[0])):" -ForegroundColor Green
        Write-Host "  + Monitored by: $(if ($MonitoredBy -eq 'proxy') { "Proxy '$ZabbixProxyName' (proxyid: $proxyId)" } else { 'Server' })" -ForegroundColor Green
        Write-Host "  + Tag Location: $Location" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create host via API: $($_.Exception.Message)"
        Write-Warning 'The agent is installed and running. Register the host manually in Zabbix.'
        Write-Host "PSK Identity: $pskIdentity" -ForegroundColor Yellow
        Write-Host "PSK Value:    $pskValue" -ForegroundColor Yellow
        return
    }
}
#endregion

#region Cleanup
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Temporary files cleaned up.' -ForegroundColor Green
#endregion
