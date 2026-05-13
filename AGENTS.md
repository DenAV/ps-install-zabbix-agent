# AGENTS.md

## Repo Shape
- This repo is a Windows Zabbix Agent 2 installer, not a buildable multi-package project.
- Main logic lives in `Zabbix-Install-Agent-MSI.ps1`; `Run-Install.cmd` is a convenience launcher that users edit with environment-specific values before running.
- `README.md` documents usage; `.github/workflows/ci.yml` runs static PowerShell checks, Pester tests, and gitleaks.
- Pester tests in `tests/` are static contract checks; they do not execute the installer or contact Zabbix.

## Runtime Requirements
- `Zabbix-Install-Agent-MSI.ps1` has `#Requires -RunAsAdministrator` and is intended to run on Windows with Windows PowerShell/PowerShell, `msiexec.exe`, Windows services, and networking cmdlets such as `Get-NetIPAddress`.
- Do not assume this can be fully verified from Linux. In this workspace, `pwsh` was not installed when checked.
- The CMD wrapper self-elevates, then invokes PowerShell with `-NoProfile -ExecutionPolicy Bypass`.

## Installer Behavior
- Required PowerShell parameters are `-ZabbixServerAddress`, `-ZabbixAuthToken`, and `-Location`.
- `-ZabbixApiUrl` defaults to `https://<ZabbixServerAddress>/api_jsonrpc.php`.
- The script queries `apiinfo.version`, derives the matching Agent 2 MSI filename, and downloads from `https://cdn.zabbix.com/zabbix/binaries/stable/...` unless `-LocalMsiPath` is supplied.
- Use `-LocalMsiPath` for offline or no-internet targets; the script copies that MSI into `%TEMP%\ZabbixInstall`.
- It installs to `C:\Program Files\Zabbix Agent 2`, writes verbose MSI logs to `%TEMP%\ZabbixInstall\zabbix-install.log`, then removes the temp directory at the end.

## Zabbix API Side Effects
- The script creates or updates the Zabbix host after installation using the bearer token from `-ZabbixAuthToken`.
- Host lookup tries short hostname and FQDN as both technical and visible names before creating a new host.
- If the host group does not exist, the script creates it. If the template does not exist, the script stops with an error.
- Existing hosts are updated additively for host groups, templates, and tags, but templates whose host name matches `SNMP` are intentionally removed via `templates_clear`.
- The script always sets PSK TLS fields and writes/uses PSK identity `<COMPUTERNAME>_identity`.
- `Location` is stored as a Zabbix host tag named `Location` and replaces only an existing `Location` tag value.

## Proxy Mode
- `-MonitoredBy` accepts only `server` or `proxy`; proxy mode requires `-ZabbixProxyName`.
- In proxy mode, the script resolves `proxyid` via `proxy.get` but uses `-ZabbixProxyAddress` as the agent connection target when provided, otherwise `-ZabbixProxyName`.
- Do not replace that fallback with the API `address` field; the script documents that active proxies often report `127.0.0.1` there.

## Verification
- CI installs `PSScriptAnalyzer` 1.22.0 and `Pester` 5.6.1, then runs `Invoke-ScriptAnalyzer` and `Invoke-Pester -Path ./tests -CI`.
- On a Windows machine, minimally validate syntax with `powershell.exe -NoProfile -Command "& { . .\Zabbix-Install-Agent-MSI.ps1 }"` only if you account for the script's mandatory parameters and admin requirement.
- Functional verification requires a reachable Zabbix API, a valid API token, an existing template such as `Windows by Zabbix agent active`, and either internet access to `cdn.zabbix.com` or a valid `-LocalMsiPath`.
