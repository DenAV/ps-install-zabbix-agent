@echo off
:: Launches the Zabbix Agent 2 MSI install script (API-based) as Administrator.
:: Copy Run-Install.config.example.cmd to Run-Install.config.cmd and edit local values there.

set "ZABBIX_SERVER=your_zabbix_server_address"
set "ZABBIX_TOKEN=your_api_token"
set "TEMPLATE_NAME=Windows by Zabbix agent active"
set "LOCATION=your_location"

:: Optional proxy settings (leave MONITORED_BY=server if not using a proxy)
set "MONITORED_BY=server"
set "ZABBIX_PROXY_NAME="
:: Optional: FQDN or IP for the proxy agent connection (use when proxy name in Zabbix is a short hostname)
:: If empty, ZABBIX_PROXY_NAME is used as the connection address
set "ZABBIX_PROXY_ADDRESS="

:: Optional: set local/network MSI path to skip download (leave empty to download automatically)
set "LOCAL_MSI_PATH="

if exist "%~dp0Run-Install.config.cmd" (
    call "%~dp0Run-Install.config.cmd"
)

:: Self-elevate if not running as admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Zabbix-Install-Agent-MSI.ps1" -ZabbixServerAddress "%ZABBIX_SERVER%" -ZabbixAuthToken "%ZABBIX_TOKEN%" -TemplateName "%TEMPLATE_NAME%" -Location "%LOCATION%" -MonitoredBy "%MONITORED_BY%" -ZabbixProxyName "%ZABBIX_PROXY_NAME%" -ZabbixProxyAddress "%ZABBIX_PROXY_ADDRESS%" -LocalMsiPath "%LOCAL_MSI_PATH%"
pause
