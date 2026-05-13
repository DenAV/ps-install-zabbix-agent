@echo off
:: Copy this file to Run-Install.config.cmd and set environment-specific values.
:: Run-Install.config.cmd is ignored by git because it contains local server names and tokens.

set "ZABBIX_SERVER=your_zabbix_server_address"
set "ZABBIX_TOKEN=your_api_token"
set "TEMPLATE_NAME=Windows by Zabbix agent active"
set "LOCATION=your_location"

:: Optional proxy settings (leave MONITORED_BY=server if not using a proxy)
set "MONITORED_BY=server"
set "ZABBIX_PROXY_NAME="
set "ZABBIX_PROXY_ADDRESS="

:: Optional: set local/network MSI path to skip download (leave empty to download automatically)
set "LOCAL_MSI_PATH="
