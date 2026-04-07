# INT001_IntuneForceComplianceCheck.ps1
# Scriptlet: INT001 - Force Intune Compliance Check
# Context: System | Version: 1.0

$ErrorActionPreference = 'Stop'

$imePath = 'C:\Program Files (x86)\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe'

if (-not (Test-Path -Path $imePath)) {
    Write-Output ''
    Write-Output '[ERR] Intune Management Extension not found.'
    Write-Output "      Expected at: $imePath"
    Write-Output '      This device may not be Intune-enrolled.'
    Write-Output ''
    return
}

Write-Output ''
Write-Output '=== Intune Compliance Sync ==='
Write-Output ''

try {
    $proc = Start-Process -FilePath $imePath -ArgumentList 'intunemanagementextension://synccompliance' -PassThru
    if ($null -ne $proc) {
        Write-Output '[OK] Compliance sync triggered successfully.'
        Write-Output '     The device will evaluate compliance policies shortly.'
    } else {
        Write-Output '[ERR] Start-Process returned no process object. Sync may not have triggered.'
    }
}
catch {
    Write-Output "[ERR] Failed to trigger compliance sync: $($_.Exception.Message)"
}

Write-Output ''
