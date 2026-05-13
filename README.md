# Zabbix Agent 2 Windows Installer

PowerShell installer for Zabbix Agent 2 on Windows. The script installs or upgrades the matching Agent 2 MSI, configures PSK encryption, and creates or updates the host in Zabbix through the API.

## Files

- `Zabbix-Install-Agent-MSI.ps1` is the main installer.
- `Run-Install.cmd` is a convenience launcher. Edit its environment-specific values before running it.
- `AGENTS.md` contains repo-specific guidance for future OpenCode sessions.

## Requirements

- Windows with PowerShell or Windows PowerShell.
- Administrator privileges. The PowerShell script has `#Requires -RunAsAdministrator`.
- Reachable Zabbix API endpoint and valid API token.
- Existing Zabbix template, for example `Windows by Zabbix agent active`.
- Internet access to `cdn.zabbix.com` or a valid local/network MSI path.

## Required Parameters

- `-ZabbixServerAddress`: Zabbix server DNS name or IP address.
- `-ZabbixAuthToken`: Zabbix API bearer token.
- `-Location`: value written to the Zabbix host tag named `Location`.

Optional parameters include `-ZabbixApiUrl`, `-HostGroupName`, `-TemplateName`, `-LocalMsiPath`, and proxy settings.

## Direct Server Mode

```powershell
.\Zabbix-Install-Agent-MSI.ps1 `
  -ZabbixServerAddress 'zabbix.example.com' `
  -ZabbixAuthToken '<api-token>' `
  -Location 'HO'
```

If `-ZabbixApiUrl` is omitted, it defaults to `https://<ZabbixServerAddress>/api_jsonrpc.php`.

## Proxy Mode

```powershell
.\Zabbix-Install-Agent-MSI.ps1 `
  -ZabbixServerAddress 'zabbix.example.com' `
  -ZabbixAuthToken '<api-token>' `
  -Location 'HO' `
  -MonitoredBy 'proxy' `
  -ZabbixProxyName 'proxy-HO-01' `
  -ZabbixProxyAddress 'proxy-HO-01.example.com'
```

`-ZabbixProxyAddress` is optional. If omitted, the agent connects to `-ZabbixProxyName`. The script intentionally does not use the proxy API `address` field as the agent connection target.

## Offline MSI

Use `-LocalMsiPath` when the target host cannot download from `cdn.zabbix.com`:

```powershell
.\Zabbix-Install-Agent-MSI.ps1 `
  -ZabbixServerAddress 'zabbix.example.com' `
  -ZabbixAuthToken '<api-token>' `
  -Location 'HO' `
  -LocalMsiPath '\\fileserver\share\zabbix_agent2-7.4.9-windows-amd64-openssl.msi'
```

The script copies the MSI into `%TEMP%\ZabbixInstall` and writes the verbose MSI log to `%TEMP%\ZabbixInstall\zabbix-install.log`.

## Zabbix API Behavior

- Queries `apiinfo.version` and downloads the matching Agent 2 MSI.
- Creates the host group if it does not exist.
- Stops with an error if the template does not exist.
- Looks up an existing host by short hostname and FQDN as both technical and visible names.
- Updates existing hosts additively for groups, templates, and tags.
- Removes templates whose host name matches `SNMP` with `templates_clear`.
- Configures PSK TLS fields with identity `<COMPUTERNAME>_identity`.

## Verification

Full functional verification requires Windows, administrator privileges, a reachable Zabbix API, a valid API token, and either internet access or `-LocalMsiPath`.

Minimal syntax and static checks can be run with PowerShell and PSScriptAnalyzer:

```powershell
Invoke-ScriptAnalyzer -Path .\Zabbix-Install-Agent-MSI.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

This repository does not currently support full functional verification from Linux/WSL.
