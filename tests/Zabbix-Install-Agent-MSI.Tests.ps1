Describe 'Zabbix-Install-Agent-MSI static contract' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..' 'Zabbix-Install-Agent-MSI.ps1'
        $scriptText = Get-Content -Path $scriptPath -Raw
    }

    It 'requires administrator privileges' {
        $scriptText | Should -Match '#Requires -RunAsAdministrator'
    }

    It 'uses strict error handling' {
        $scriptText | Should -Match 'Set-StrictMode -Version Latest'
        $scriptText | Should -Match "\$ErrorActionPreference = 'Stop'"
    }

    It 'requires the expected user-supplied parameters' {
        $scriptText | Should -Match '\[string\]\$ZabbixServerAddress'
        $scriptText | Should -Match '\[string\]\$ZabbixAuthToken'
        $scriptText | Should -Match '\[string\]\$Location'
    }

    It 'restricts monitoring mode values' {
        $scriptText | Should -Match "\[ValidateSet\('server', 'proxy'\)\]"
    }

    It 'enforces TLS 1.2 for web requests' {
        $scriptText | Should -Match '\[Net\.SecurityProtocolType\]::Tls12'
    }

    It 'keeps the documented active proxy address fallback' {
        $scriptText | Should -Match '\$ZabbixProxyAddress'
        $scriptText | Should -Match 'else \{ \$ZabbixProxyName \}'
        $scriptText | Should -Match 'Never use the API ''address'' field'
    }
}
