# BL008_BLReadinessCheck.ps1
# Scriptlet: BL008 - BitLocker Encryption Readiness Dry Run
# Context: System | Version: 1.0

$ErrorActionPreference = 'SilentlyContinue'
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

Write-Output ''
Write-Output '=== BitLocker Encryption Readiness Dry Run ==='
Write-Output '[i]   Pre-flight check: Can this volume be encrypted right now?'
Write-Output ''

# Target the OS drive
$osDrive = $env:SystemDrive
if (-not $osDrive) { $osDrive = 'C:' }

# ============================================================
# Helper: Parse key-value from command output
# ============================================================
function Get-ParsedValue {
    param([string[]]$Lines, [string]$Label)
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        # manage-bde uses colons:  "Conversion Status:    Fully Decrypted"
        # bcdedit uses whitespace: "device                  partition=..."
        # Try colon format first, then fall back to 2+ whitespace separator.
        if ($trimmed -match "^${Label}\s*[:]\s*(.+)$") {
            return $Matches[1].Trim()
        }
        if ($trimmed -match "^${Label}\s{2,}(.+)$") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

# ============================================================
# Section 0: Service Dependency Gate
# ============================================================
Write-Output '--- Service Dependencies ---'

$svcChecks = @(
    @{ Name = 'BDESVC'; Display = 'BitLocker Drive Encryption Service' },
    @{ Name = 'TBS'; Display = 'TPM Base Services' },
    @{ Name = 'KeyIso'; Display = 'CNG Key Isolation' },
    @{ Name = 'BFE'; Display = 'Base Filtering Engine' },
    @{ Name = 'RpcSs'; Display = 'Remote Procedure Call (RPC)' }
)

$svcIssues = 0
foreach ($svc in $svcChecks) {
    $svcObj = $null
    try {
        $svcObj = Get-Service -Name $svc.Name -ErrorAction Stop
    }
    catch {
        # Service may not exist
    }

    if (-not $svcObj) {
        Write-Output "[!!]  $($svc.Display) ($($svc.Name)): NOT FOUND"
        Write-Output "       This service is required for BitLocker encryption."
        $blockers.Add("Service $($svc.Name) not found")
        $svcIssues++
        $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = 'Service not found on this system.' })
        continue
    }

    $status = $svcObj.Status
    $startType = $svcObj.StartType

    if ($svc.Name -eq 'RpcSs') {
        # RpcSs must be running
        if ($status -ne 'Running') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): $status"
            Write-Output "       RPC must be running for BitLocker WMI operations."
            $blockers.Add("Service $($svc.Name) is $status (must be Running)")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "Status: $status. Must be Running." })
        }
        else {
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): Running"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = 'Running.' })
        }
    }
    elseif ($svc.Name -eq 'BDESVC') {
        # BDESVC is Manual (Trigger Start) by default -- Disabled is a problem
        if ($startType -eq 'Disabled') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): DISABLED"
            Write-Output "       BDESVC startup type is Disabled. Encryption cannot proceed."
            $blockers.Add("Service BDESVC is Disabled")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "StartType: Disabled. Must not be Disabled." })
        }
        else {
            $detail = "Status: $status, StartType: $startType."
            if ($status -ne 'Running') {
                $detail += ' Not currently running (normal -- BDESVC is trigger-start).'
            }
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): $startType / $status"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = $detail })
        }
    }
    elseif ($svc.Name -eq 'TBS') {
        # TBS should be running or at least not Disabled
        if ($startType -eq 'Disabled') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): DISABLED"
            Write-Output "       TPM Base Services is Disabled. TPM-backed encryption cannot proceed."
            $blockers.Add("Service TBS is Disabled")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "StartType: Disabled. Required for TPM operations." })
        }
        elseif ($status -ne 'Running') {
            Write-Output "[!]   $($svc.Display) ($($svc.Name)): $status"
            Write-Output "       TBS is not running. TPM communication may fail."
            $warnings.Add("Service TBS is $status")
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'WARN'; Detail = "Status: $status. TPM operations may fail." })
        }
        else {
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): Running"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = 'Running.' })
        }
    }
    elseif ($svc.Name -eq 'KeyIso') {
        # KeyIso is Manual (Trigger Start) -- handles FVEK/VMK key generation via CNG.
        # If Disabled, key operations fail with 0x80090016 (NTE_BAD_KEYSET).
        if ($startType -eq 'Disabled') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): DISABLED"
            Write-Output "       CNG Key Isolation is Disabled. BitLocker key generation will fail."
            Write-Output "       Error 0x80090016 (NTE_BAD_KEYSET) is the typical symptom."
            $blockers.Add("Service KeyIso is Disabled")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "StartType: Disabled. Key generation blocked." })
        }
        else {
            $detail = "Status: $status, StartType: $startType."
            if ($status -ne 'Running') {
                $detail += ' Not currently running (normal -- KeyIso is trigger-start).'
            }
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): $startType / $status"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = $detail })
        }
    }
    elseif ($svc.Name -eq 'BFE') {
        # BFE must be running -- underpins WFP/WinHTTP for HTTPS key escrow.
        # If stopped, escrow to Azure AD/Entra ID fails with 0x80072EFE.
        if ($status -ne 'Running') {
            Write-Output "[!!]  $($svc.Display) ($($svc.Name)): $status"
            Write-Output "       BFE must be running for HTTPS key escrow to Azure AD/Entra ID."
            Write-Output "       Error 0x80072EFE (connection aborted) is the typical symptom."
            $blockers.Add("Service $($svc.Name) is $status (must be Running)")
            $svcIssues++
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'ISSUE'; Detail = "Status: $status. Must be Running for key escrow." })
        }
        else {
            Write-Output "[OK]  $($svc.Display) ($($svc.Name)): Running"
            $findings.Add([PSCustomObject]@{ Check = "Service: $($svc.Name)"; Status = 'OK'; Detail = 'Running.' })
        }
    }
}

if ($svcIssues -eq 0) {
    Write-Output "[OK]  All required services are available."
}
Write-Output ''

# ============================================================
# Section 0b: Third-Party FDE Collision Detection
# Prevents catastrophic double-encryption by detecting competing
# full-disk encryption products before BitLocker enablement.
# Detection uses only confirmed vendor artifacts (no Win32_Product).
# ============================================================
Write-Output '--- Third-Party FDE Collision Detection ---'

# --- Layer 1: Known FDE services (fastest, most definitive) ---
$fdeServices = @(
    @{ Short = 'veracrypt';      Vendor = 'VeraCrypt';              Severity = 'BLOCKER' }
    @{ Short = 'MfeEpePc';       Vendor = 'McAfee/Trellix';         Severity = 'BLOCKER' }
    @{ Short = 'SGNAuthService'; Vendor = 'Sophos SafeGuard';       Severity = 'BLOCKER' }
    @{ Short = 'Pointsec';       Vendor = 'Check Point (Pointsec)'; Severity = 'BLOCKER' }
    @{ Short = 'Pointsec_start'; Vendor = 'Check Point (Pointsec)'; Severity = 'BLOCKER' }
    @{ Short = 'KAVFS';          Vendor = 'Kaspersky';              Severity = 'WARN' }
    @{ Short = 'KAVFSGT';        Vendor = 'Kaspersky';              Severity = 'WARN' }
)

$fdeDetected = $false
$fdeVendors = [System.Collections.Generic.List[string]]::new()

foreach ($fdeSvc in $fdeServices) {
    $svcObj = $null
    try { $svcObj = Get-Service -Name $fdeSvc.Short -ErrorAction Stop } catch { }
    if ($svcObj) {
        $fdeDetected = $true
        $label = "$($fdeSvc.Vendor) service '$($fdeSvc.Short)' (Status: $($svcObj.Status))"
        if ($fdeSvc.Severity -eq 'BLOCKER') {
            Write-Output "[!!]  $label"
            Write-Output '       Third-party FDE agent found. DO NOT enable BitLocker -- risk of data loss.'
            $blockers.Add("Third-party FDE: $($fdeSvc.Vendor) ($($fdeSvc.Short))")
            $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'ISSUE'; Detail = $label })
        }
        else {
            Write-Output "[!]   $label"
            Write-Output '       Suite may include FDE. Verify encryption state before proceeding.'
            $warnings.Add("Possible FDE suite: $($fdeSvc.Vendor) ($($fdeSvc.Short))")
            $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'WARN'; Detail = $label })
        }
        if (-not $fdeVendors.Contains($fdeSvc.Vendor)) { $fdeVendors.Add($fdeSvc.Vendor) }
    }
}

# --- Layer 2: Registry uninstall keys (both 64-bit and WOW64 hives) ---
$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# Severity: BLOCKER = confirmed FDE, WARN = suite that MAY include FDE, INFO = BitLocker wrapper
$fdeProducts = @(
    @{ Pattern = 'VeraCrypt';                        Vendor = 'VeraCrypt';          Severity = 'BLOCKER' }
    @{ Pattern = 'McAfee Drive Encryption';          Vendor = 'McAfee/Trellix';     Severity = 'BLOCKER' }
    @{ Pattern = 'Trellix Drive Encryption';         Vendor = 'McAfee/Trellix';     Severity = 'BLOCKER' }
    @{ Pattern = 'Sophos SafeGuard Enterprise';      Vendor = 'Sophos SafeGuard';   Severity = 'BLOCKER' }
    @{ Pattern = 'Sophos Central Device Encryption'; Vendor = 'Sophos CDE';         Severity = 'INFO' }
    @{ Pattern = 'Check Point Full Disk Encryption'; Vendor = 'Check Point';        Severity = 'BLOCKER' }
    @{ Pattern = 'Check Point Endpoint Security';    Vendor = 'Check Point';        Severity = 'WARN' }
    @{ Pattern = 'DESlock';                          Vendor = 'DESlock/ESET';       Severity = 'BLOCKER' }
    @{ Pattern = 'ESET Full Disk Encryption';        Vendor = 'ESET';               Severity = 'BLOCKER' }
    @{ Pattern = 'ESET Endpoint Encryption';         Vendor = 'ESET';               Severity = 'BLOCKER' }
    @{ Pattern = 'WinMagic SecureDoc';               Vendor = 'WinMagic';           Severity = 'BLOCKER' }
    @{ Pattern = 'SecureDoc Disk Encryption';        Vendor = 'WinMagic';           Severity = 'BLOCKER' }
    @{ Pattern = 'Kaspersky Endpoint Security';      Vendor = 'Kaspersky';          Severity = 'WARN' }
    @{ Pattern = 'Symantec Endpoint Protection';     Vendor = 'Symantec/Broadcom';  Severity = 'WARN' }
)

$installedApps = @()
foreach ($regPath in $uninstallPaths) {
    try {
        $items = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($items) { $installedApps += $items }
    }
    catch { }
}

foreach ($fdeProd in $fdeProducts) {
    $alreadyFound = $fdeVendors.Contains($fdeProd.Vendor)
    foreach ($app in $installedApps) {
        if ($app.DisplayName -and $app.DisplayName -match [regex]::Escape($fdeProd.Pattern)) {
            $label = "Registry: '$($app.DisplayName)' ($($fdeProd.Vendor))"
            if ($fdeProd.Severity -eq 'BLOCKER' -and -not $alreadyFound) {
                $fdeDetected = $true
                Write-Output "[!!]  $label"
                Write-Output '       Third-party FDE installed. DO NOT enable BitLocker.'
                $blockers.Add("Third-party FDE: $($fdeProd.Vendor) ($($app.DisplayName))")
                $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'ISSUE'; Detail = $label })
            }
            elseif ($fdeProd.Severity -eq 'INFO') {
                Write-Output "[i]   $label"
                Write-Output '       Sophos CDE manages BitLocker natively -- not a competing FDE.'
                Write-Output '       BitLocker may already be enabled and managed by Sophos Central.'
                $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'INFO'; Detail = "$label (BitLocker wrapper)" })
            }
            elseif (-not $alreadyFound) {
                $fdeDetected = $true
                Write-Output "[!]   $label"
                Write-Output '       Suite may include FDE. Verify encryption state before proceeding.'
                $warnings.Add("Possible FDE suite: $($fdeProd.Vendor)")
                $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'WARN'; Detail = $label })
            }
            if (-not $fdeVendors.Contains($fdeProd.Vendor)) { $fdeVendors.Add($fdeProd.Vendor) }
            break
        }
    }
}

# --- Layer 3: Kernel filter drivers via fltmc (ultimate source of truth) ---
$fdeFilters = @(
    @{ Name = 'veracrypt'; Vendor = 'VeraCrypt' }
    @{ Name = 'MfeEpePC';  Vendor = 'McAfee/Trellix' }
    @{ Name = 'prot_2k';   Vendor = 'Check Point' }
    @{ Name = 'dlpcore';   Vendor = 'DESlock/ESET' }
    @{ Name = 'klflt';     Vendor = 'Kaspersky' }
    @{ Name = 'klif';      Vendor = 'Kaspersky' }
    @{ Name = 'SophosED';  Vendor = 'Sophos' }
)

$fltOutput = $null
try { $fltOutput = & fltmc.exe filters 2>&1 } catch { }

if ($fltOutput) {
    $fltLines = @($fltOutput | ForEach-Object { "$_" })

    # Check for known FDE filter drivers
    foreach ($fdeFilter in $fdeFilters) {
        foreach ($line in $fltLines) {
            if ($line -match "\b$([regex]::Escape($fdeFilter.Name))\b") {
                if (-not $fdeVendors.Contains($fdeFilter.Vendor)) {
                    $fdeDetected = $true
                    Write-Output "[!!]  Kernel filter '$($fdeFilter.Name)' loaded ($($fdeFilter.Vendor))"
                    Write-Output '       Active FDE driver in the storage stack. DO NOT enable BitLocker.'
                    $blockers.Add("FDE kernel driver: $($fdeFilter.Name) ($($fdeFilter.Vendor))")
                    $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'ISSUE'; Detail = "Kernel filter: $($fdeFilter.Name) ($($fdeFilter.Vendor))" })
                    $fdeVendors.Add($fdeFilter.Vendor)
                }
                break
            }
        }
    }

    # Altitude heuristic: any unknown driver in the crypto minifilter range (140000-149999).
    # Microsoft mandates that cryptographic minifilters operate in this altitude range.
    # This catches rebranded, obscure, or shadow-IT FDE products not in our known list.
    $knownFilterNames = @($fdeFilters | ForEach-Object { $_.Name })
    foreach ($line in $fltLines) {
        # Skip header and separator lines
        if ($line -match '^Filter' -or $line -match '^-') { continue }
        $tokens = $line.Trim() -split '\s+'
        if ($tokens.Count -lt 2) { continue }
        $driverName = $tokens[0]
        # Find the altitude value (5-6 digit number) in the line
        $altToken = $null
        foreach ($t in $tokens) {
            if ($t -match '^\d{5,6}$') { $altToken = $t; break }
        }
        if ($altToken) {
            $altitude = [int]$altToken
            if ($altitude -ge 140000 -and $altitude -le 149999) {
                if ($knownFilterNames -notcontains $driverName) {
                    Write-Output "[!]   Unknown crypto-range driver: $driverName (altitude $altitude)"
                    Write-Output '       Operating in the cryptographic minifilter range (140000-149999).'
                    Write-Output '       May indicate an unidentified FDE product. Investigate before proceeding.'
                    $warnings.Add("Unknown crypto-range driver: $driverName (altitude $altitude)")
                    $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'WARN'; Detail = "Unknown driver $driverName at crypto altitude $altitude" })
                }
            }
        }
    }
}

if (-not $fdeDetected) {
    Write-Output '[OK]  No third-party FDE products detected. Safe to proceed with BitLocker.'
    $findings.Add([PSCustomObject]@{ Check = 'FDE Collision'; Status = 'OK'; Detail = 'No competing FDE products found.' })
}

Write-Output ''

# # ============================================================
# Section 1: BitLocker Feature Gate (manage-bde availability)
# ============================================================
Write-Output '--- BitLocker Feature Gate ---'

$manageBdeAvailable = $true

try {
    $null = Get-Command -Name 'manage-bde.exe' -ErrorAction Stop
}
catch {
    $manageBdeAvailable = $false
}

if (-not $manageBdeAvailable) {
    Write-Output '[!!]  manage-bde.exe is not available.'
    Write-Output '       BitLocker feature may not be installed on this system.'
    $blockers.Add('manage-bde.exe not available')
    $findings.Add([PSCustomObject]@{ Check = 'manage-bde availability'; Status = 'ISSUE'; Detail = 'manage-bde.exe not available.' })
}
else {
    Write-Output '[OK]  manage-bde.exe is available. BitLocker feature is installed.'
    $findings.Add([PSCustomObject]@{ Check = 'manage-bde availability'; Status = 'OK'; Detail = 'Present.' })
}

Write-Output ''

# ============================================================
# Section 2: Volume State via WMI (Win32_EncryptableVolume)
# All data extraction uses WMI numeric return codes which are
# never localized -- unlike manage-bde text output.
# ============================================================
Write-Output '--- Volume State (Win32_EncryptableVolume) ---'

$wmiAvailable = $true
$encVol = $null

try {
    $encVol = Get-CimInstance -Namespace 'ROOT\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName 'Win32_EncryptableVolume' -Filter "DriveLetter='$osDrive'" -ErrorAction Stop
}
catch {
    $wmiAvailable = $false
}

if (-not $wmiAvailable -or -not $encVol) {
    # Fallback: Get-BitLockerVolume returns structured objects (enum values, not text).
    # Available when the BitLocker PowerShell module is installed, even if the
    # WMI provider is not registered. Fully L10N-safe.
    $blvFallback = $null
    try {
        $blvFallback = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop
    }
    catch { }

    if ($blvFallback) {
        Write-Output '[i]   WMI provider not available. Using Get-BitLockerVolume fallback.'

        # Conversion Status from VolumeStatus enum
        $wmiConvCode = -1
        $volStatus = [string]$blvFallback.VolumeStatus
        $volStatusToCode = @{
            'FullyDecrypted'       = 0
            'FullyEncrypted'       = 1
            'EncryptionInProgress' = 2
            'DecryptionInProgress' = 3
            'EncryptionPaused'     = 4
            'DecryptionPaused'     = 5
        }
        if ($volStatusToCode.ContainsKey($volStatus)) {
            $wmiConvCode = $volStatusToCode[$volStatus]
        }

        if ($wmiConvCode -eq 0) {
            Write-Output "[OK]  Conversion Status: $volStatus"
            Write-Output '       Volume is fully decrypted and eligible for encryption.'
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'OK'; Detail = "$volStatus -- eligible for encryption." })
        }
        elseif ($wmiConvCode -eq 1) {
            Write-Output "[i]   Conversion Status: $volStatus. Already encrypted."
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'INFO'; Detail = "$volStatus. Volume is already encrypted." })
        }
        elseif ($wmiConvCode -ge 2) {
            Write-Output "[!!]  Conversion Status: $volStatus"
            $pct = $blvFallback.EncryptionPercentage
            Write-Output "       EncryptionPercentage: $pct%. Volume is in a transitional state."
            $blockers.Add("Active conversion: $volStatus")
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'ISSUE'; Detail = "$volStatus -- transitional state." })
        }
        else {
            Write-Output "[!]   Conversion Status: $volStatus (could not map to known code)"
            $warnings.Add("Unknown VolumeStatus: $volStatus")
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'WARN'; Detail = "Unmapped VolumeStatus: $volStatus" })
        }

        # Protection Status from ProtectionStatus enum
        $wmiProtCode = -1
        $protStatus = [string]$blvFallback.ProtectionStatus
        $protToCode = @{ 'Off' = 0; 'On' = 1; 'Unknown' = 2 }
        if ($protToCode.ContainsKey($protStatus)) {
            $wmiProtCode = $protToCode[$protStatus]
        }
        Write-Output "[i]   Protection Status: $protStatus"
        $findings.Add([PSCustomObject]@{ Check = 'Protection Status'; Status = 'INFO'; Detail = $protStatus })

        # Ghost State
        if ($wmiConvCode -eq 1 -and $wmiProtCode -eq 0) {
            Write-Output '[!!]  GHOST STATE DETECTED: FullyEncrypted + Protection Off'
            Write-Output '       Volume appears encrypted but FVEK is stored in the clear.'
            Write-Output '       Remediation: manage-bde -off C: to fully decrypt, then re-encrypt cleanly.'
            $blockers.Add('Ghost state: FullyEncrypted with Protection Off')
            $findings.Add([PSCustomObject]@{ Check = 'Ghost State'; Status = 'ISSUE'; Detail = 'FullyEncrypted + Protection Off.' })
        }

        # Encryption Method from EncryptionMethod enum
        $encMeth = [string]$blvFallback.EncryptionMethod
        if ($encMeth -and $encMeth -ne 'None') {
            if ($wmiConvCode -eq 0) {
                Write-Output "[!]   Encryption Method: $encMeth (on a FullyDecrypted volume)"
                Write-Output '       Residual crypto metadata present.'
                $warnings.Add("Residual encryption method: $encMeth")
                $findings.Add([PSCustomObject]@{ Check = 'Encryption Method'; Status = 'WARN'; Detail = "Residual: $encMeth on decrypted volume." })
            }
            else {
                Write-Output "[i]   Encryption Method: $encMeth"
                $findings.Add([PSCustomObject]@{ Check = 'Encryption Method'; Status = 'INFO'; Detail = $encMeth })
            }
        }

        # Key Protectors from KeyProtector array
        $kpCount = 0
        $kpTypes = [System.Collections.Generic.List[string]]::new()
        if ($blvFallback.KeyProtector) {
            $kpCount = @($blvFallback.KeyProtector).Count
            foreach ($kp in $blvFallback.KeyProtector) {
                $kpType = [string]$kp.KeyProtectorType
                if ($kpType -and -not $kpTypes.Contains($kpType)) { $kpTypes.Add($kpType) }
            }
        }
        $kpTypesStr = if ($kpTypes.Count -gt 0) { $kpTypes -join ', ' } else { 'none' }

        if ($kpCount -gt 0 -and $wmiConvCode -eq 0) {
            Write-Output "[!!]  Key Protectors: $kpCount protector(s) on a FullyDecrypted volume ($kpTypesStr)"
            Write-Output '       Orphaned protectors may block fresh encryption.'
            $blockers.Add("$kpCount orphaned key protector(s) on decrypted volume")
            $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'ISSUE'; Detail = "$kpCount orphaned: $kpTypesStr" })
        }
        elseif ($kpCount -gt 0) {
            Write-Output "[i]   Key Protectors: $kpCount protector(s) found ($kpTypesStr)"
            $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'INFO'; Detail = "$kpCount protector(s): $kpTypesStr" })
        }
        elseif ($wmiConvCode -eq 0) {
            Write-Output '[OK]  No key protectors found. Clean slate for fresh encryption.'
            $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'OK'; Detail = 'Clean slate.' })
        }
    }
    else {
        Write-Output "[!]   Volume state cannot be assessed for $osDrive."
        Write-Output '       Neither WMI (Win32_EncryptableVolume) nor Get-BitLockerVolume is available.'
        Write-Output '       The BitLocker feature may not be installed on this system.'
        Write-Output '       On Windows Server: Install-WindowsFeature BitLocker -IncludeManagementTools'
        Write-Output '       On Windows 10/11: Enable via Settings > Apps > Optional Features > BitLocker'
        $warnings.Add('Volume state assessment unavailable (no WMI, no Get-BitLockerVolume)')
        $findings.Add([PSCustomObject]@{ Check = 'Volume State'; Status = 'WARN'; Detail = 'Neither WMI nor Get-BitLockerVolume available.' })
    }
}
else {
    # Known BitLocker HRESULT codes from Win32_EncryptableVolume WMI provider.
    $fveErrors = @{
        '0x80310008' = @{ Name = 'FVE_E_NOT_ACTIVATED';                         Detail = 'Protection not activated on this volume.';                          Action = 'Expected on unencrypted drives. No action needed for fresh encryption.' }
        '0x80310018' = @{ Name = 'FVE_E_TPM_NOT_OWNED';                         Detail = 'TPM present but not initialized or ownership not claimed by OS.';    Action = 'Run Initialize-Tpm or open tpm.msc to take ownership. See BL002 BLTpmHealth.' }
        '0x80310048' = @{ Name = 'FVE_E_FIRMWARE_TYPE_NOT_SUPPORTED';            Detail = 'System booting in Legacy BIOS/CSM. BitLocker requires native UEFI.'; Action = 'Convert to native UEFI boot and disable CSM in BIOS/UEFI settings.' }
        '0x8031004A' = @{ Name = 'FVE_E_NOT_ON_STACK';                          Detail = 'BitLocker system files or bdesvc filter driver missing/corrupt.';    Action = 'Run Windows Startup Repair (bootrec /fixboot). May need BitLocker feature reinstall.' }
        '0x80310052' = @{ Name = 'FVE_E_BCD_APPLICATIONS_PATH_INCORRECT';       Detail = 'BCD paths point to wrong partition (cloning/imaging artifact).';     Action = 'Rebuild BCD: bcdboot C:\Windows /s S: /f UEFI' }
        '0x80310059' = @{ Name = 'FVE_E_OVERLAPPED_UPDATE';                     Detail = 'Conflicting policy or active BitLocker operation in progress.';      Action = 'Wait for active operation. Check GPO: HKLM\SOFTWARE\Policies\Microsoft\FVE' }
        '0x803100B6' = @{ Name = 'FVE_E_NO_PREBOOT_KEYBOARD_OR_WINRE_DETECTED'; Detail = 'No pre-boot keyboard AND no functional WinRE. Fatal on tablets.';    Action = 'Run reagentc /enable. On tablets, ensure keyboard or USB recovery available.' }
        '0x80290107' = @{ Name = 'TPMAPI_E_INTERNAL_ERROR';                     Detail = 'Low-level TPM hardware/firmware crash during crypto operation.';     Action = 'Update BIOS/UEFI firmware. If persistent, CMOS clear + TPM re-init. See BL002.' }
        '0x80072F9A' = @{ Name = 'MDM_POLICY_CONFLICT';                         Detail = 'Local GPO conflicts with Intune/MDM CSP BitLocker directives.';      Action = 'Review: HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker' }
    }

    # --- Conversion Status ---
    $convResult = $null
    try {
        $convResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetConversionStatus' -ErrorAction Stop
    }
    catch { }

    $wmiConvCode = -1
    $convStatusMap = @{
        0 = 'FullyDecrypted'
        1 = 'FullyEncrypted'
        2 = 'EncryptionInProgress'
        3 = 'DecryptionInProgress'
        4 = 'EncryptionPaused'
        5 = 'DecryptionPaused'
    }

    if ($convResult -and $convResult.ReturnValue -eq 0) {
        $wmiConvCode = [int]$convResult.ConversionStatus
        $wmiPct = $convResult.EncryptionPercentage
        $wmiConvStatus = if ($convStatusMap.ContainsKey($wmiConvCode)) { $convStatusMap[$wmiConvCode] } else { "Code $wmiConvCode" }

        if ($wmiConvCode -eq 0) {
            Write-Output "[OK]  Conversion Status: $wmiConvStatus"
            Write-Output '       Volume is fully decrypted and eligible for encryption.'
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'OK'; Detail = "$wmiConvStatus -- eligible for encryption." })
        }
        elseif ($wmiConvCode -eq 1) {
            Write-Output "[i]   Conversion Status: $wmiConvStatus. Already encrypted."
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'INFO'; Detail = "$wmiConvStatus. Volume is already encrypted." })
        }
        else {
            Write-Output "[!!]  Conversion Status: $wmiConvStatus"
            Write-Output "       EncryptionPercentage: $wmiPct%. Volume is in a transitional state."
            Write-Output '       Cannot start a new encryption while another is in progress.'
            $blockers.Add("Active conversion: $wmiConvStatus")
            $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'ISSUE'; Detail = "$wmiConvStatus -- transitional state." })
        }

        # Partial encryption detection
        if ($null -ne $wmiPct -and [int]$wmiPct -gt 0 -and [int]$wmiPct -lt 100) {
            Write-Output "[!!]  Percentage Encrypted: $wmiPct%"
            Write-Output '       Partial encryption detected. Volume is in an incomplete state.'
            $blockers.Add("Partial encryption: $wmiPct%")
            $findings.Add([PSCustomObject]@{ Check = 'Percentage Encrypted'; Status = 'ISSUE'; Detail = "Partial: $wmiPct%" })
        }
    }
    else {
        $retVal = if ($convResult) { "0x{0:X8}" -f $convResult.ReturnValue } else { 'N/A' }
        Write-Output "[!]   GetConversionStatus returned: $retVal"
        if ($retVal -ne 'N/A' -and $fveErrors.ContainsKey($retVal)) {
            $errInfo = $fveErrors[$retVal]
            Write-Output "       $($errInfo.Name): $($errInfo.Detail)"
            Write-Output "       Fix: $($errInfo.Action)"
        }
        else {
            Write-Output '       Could not determine volume conversion state via WMI.'
            Write-Output '       Check BitLocker feature installation and WMI provider registration.'
        }
        $warnings.Add("WMI GetConversionStatus returned $retVal")
        $findings.Add([PSCustomObject]@{ Check = 'Conversion Status'; Status = 'WARN'; Detail = "GetConversionStatus returned $retVal" })
    }

    # --- Protection Status + Ghost State Detection ---
    $protResult = $null
    try {
        $protResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetProtectionStatus' -ErrorAction Stop
    }
    catch { }

    $wmiProtCode = -1
    if ($protResult -and $protResult.ReturnValue -eq 0) {
        $wmiProtCode = [int]$protResult.ProtectionStatus
        $protStatusMap = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Unknown' }
        $protLabel = if ($protStatusMap.ContainsKey($wmiProtCode)) { $protStatusMap[$wmiProtCode] } else { "Code $wmiProtCode" }

        Write-Output "[i]   Protection Status: $protLabel (code $wmiProtCode)"
        $findings.Add([PSCustomObject]@{ Check = 'Protection Status'; Status = 'INFO'; Detail = "$protLabel (code $wmiProtCode)" })

        # Ghost State: FullyEncrypted (1) + Protection Off (0)
        if ($wmiConvCode -eq 1 -and $wmiProtCode -eq 0) {
            Write-Output '[!!]  GHOST STATE DETECTED: FullyEncrypted + Protection Off'
            Write-Output '       Volume appears encrypted but FVEK is stored in the clear.'
            Write-Output '       This is the "Waiting for Activation" state. Data is NOT protected.'
            Write-Output '       Remediation: manage-bde -off C: to fully decrypt, then re-encrypt cleanly.'
            $blockers.Add('Ghost state: FullyEncrypted with Protection Off (Waiting for Activation)')
            $findings.Add([PSCustomObject]@{ Check = 'Ghost State'; Status = 'ISSUE'; Detail = 'FullyEncrypted + Protection Off. Remediate with manage-bde -off.' })
        }
    }
    elseif ($protResult) {
        $retVal = "0x{0:X8}" -f $protResult.ReturnValue
        Write-Output "[!]   GetProtectionStatus returned: $retVal"
        if ($fveErrors.ContainsKey($retVal)) {
            $errInfo = $fveErrors[$retVal]
            Write-Output "       $($errInfo.Name): $($errInfo.Detail)"
            Write-Output "       Fix: $($errInfo.Action)"
        }
        $warnings.Add("WMI GetProtectionStatus returned $retVal")
        $findings.Add([PSCustomObject]@{ Check = 'Protection Status'; Status = 'WARN'; Detail = "GetProtectionStatus returned $retVal" })
    }

    # --- Encryption Method ---
    $encMethodResult = $null
    try {
        $encMethodResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetEncryptionMethod' -ErrorAction Stop
    }
    catch { }

    if ($encMethodResult -and $encMethodResult.ReturnValue -eq 0) {
        $encMethodCode = [int]$encMethodResult.EncryptionMethod
        $encMethodMap = @{
            0 = 'None'
            1 = 'AES-128-Diffuser'
            2 = 'AES-256-Diffuser'
            3 = 'AES-128'
            4 = 'AES-256'
            5 = 'Hardware Encryption'
            6 = 'XTS-AES-128'
            7 = 'XTS-AES-256'
        }
        $encMethodLabel = if ($encMethodMap.ContainsKey($encMethodCode)) { $encMethodMap[$encMethodCode] } else { "Code $encMethodCode" }

        if ($encMethodCode -ne 0) {
            if ($wmiConvCode -eq 0) {
                Write-Output "[!]   Encryption Method: $encMethodLabel (on a FullyDecrypted volume)"
                Write-Output '       Residual crypto metadata present. May be from a previous encryption attempt.'
                $warnings.Add("Residual encryption method: $encMethodLabel on decrypted volume")
                $findings.Add([PSCustomObject]@{ Check = 'Encryption Method'; Status = 'WARN'; Detail = "Residual metadata: $encMethodLabel on decrypted volume." })
            }
            else {
                Write-Output "[i]   Encryption Method: $encMethodLabel"
                $findings.Add([PSCustomObject]@{ Check = 'Encryption Method'; Status = 'INFO'; Detail = $encMethodLabel })
            }
        }
    }

    # --- Key Protectors ---
    $kpResult = $null
    try {
        # Type 0 = all protector types
        $kpResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetKeyProtectors' -Arguments @{ KeyProtectorType = [uint32]0 } -ErrorAction Stop
    }
    catch { }

    $kpCount = 0
    $kpTypeMap = @{
        0 = 'Unknown'
        1 = 'TPM'
        2 = 'External Key'
        3 = 'Numerical Password'
        4 = 'TPM+PIN'
        5 = 'TPM+Startup Key'
        6 = 'TPM+PIN+Startup Key'
        7 = 'Certificate'
        8 = 'Password'
        9 = 'TPM Network Key'
    }

    if ($kpResult -and $kpResult.ReturnValue -eq 0 -and $kpResult.VolumeKeyProtectorID) {
        $protectorIds = @($kpResult.VolumeKeyProtectorID)
        $kpCount = $protectorIds.Count

        # Enumerate protector types
        $kpTypes = [System.Collections.Generic.List[string]]::new()
        foreach ($kpId in $protectorIds) {
            $typeResult = $null
            try {
                $typeResult = Invoke-CimMethod -InputObject $encVol -MethodName 'GetKeyProtectorType' -Arguments @{ VolumeKeyProtectorID = $kpId } -ErrorAction Stop
            }
            catch { }
            if ($typeResult -and $typeResult.ReturnValue -eq 0) {
                $typeCode = [int]$typeResult.KeyProtectorType
                $typeLabel = if ($kpTypeMap.ContainsKey($typeCode)) { $kpTypeMap[$typeCode] } else { "Type $typeCode" }
                if (-not $kpTypes.Contains($typeLabel)) { $kpTypes.Add($typeLabel) }
            }
        }
        $kpTypesStr = if ($kpTypes.Count -gt 0) { $kpTypes -join ', ' } else { 'unknown types' }

        if ($kpCount -gt 0 -and $wmiConvCode -eq 0) {
            Write-Output "[!!]  Key Protectors: $kpCount protector(s) on a FullyDecrypted volume ($kpTypesStr)"
            Write-Output '       Orphaned protectors may block fresh encryption. Remove with manage-bde -protectors -delete.'
            $blockers.Add("$kpCount orphaned key protector(s) on decrypted volume")
            $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'ISSUE'; Detail = "$kpCount orphaned protector(s): $kpTypesStr" })
        }
        elseif ($kpCount -gt 0) {
            Write-Output "[i]   Key Protectors: $kpCount protector(s) found ($kpTypesStr)"
            $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'INFO'; Detail = "$kpCount protector(s): $kpTypesStr" })
        }
    }

    if ($kpCount -eq 0 -and $wmiConvCode -eq 0) {
        Write-Output '[OK]  No key protectors found. Clean slate for fresh encryption.'
        $findings.Add([PSCustomObject]@{ Check = 'Key Protectors'; Status = 'OK'; Detail = 'No protectors on decrypted volume. Clean slate.' })
    }
}

Write-Output ''

# ============================================================
# Section 3: BCD Integrity (bcdedit /enum all)
# ============================================================
Write-Output '--- BCD Integrity ---'

$bcdOutput = $null
$bcdAvailable = $true

try {
    $bcdOutput = & bcdedit.exe /enum all 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $bcdOutput) {
        $bcdAvailable = $false
    }
}
catch {
    $bcdAvailable = $false
}

if (-not $bcdAvailable -or -not $bcdOutput) {
    Write-Output "[!]   bcdedit.exe failed or is not available."
    Write-Output '       Cannot validate Boot Configuration Data integrity.'
    $warnings.Add('bcdedit not available or failed')
    $findings.Add([PSCustomObject]@{ Check = 'BCD Integrity'; Status = 'WARN'; Detail = 'bcdedit not available or failed.' })
}
else {
    $bcdLines = @($bcdOutput | ForEach-Object { "$_" })
    $bcdIssues = 0

    # ----- L10N-safe BCD block parser -----
    # bcdedit field LABELS are localized (e.g. 'device' -> 'Geraet' on de-DE).
    # Field VALUES are never localized: {bootmgr}, {current}, partition=..., unknown.
    # Strategy: split on empty-line boundaries, identify blocks by the first
    # {word} value (always the identifier), check device health by scanning
    # for 'unknown' and 'partition=' value patterns.
    $blocks = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $bcdLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^-+$') { continue }
        if ($trimmed -eq '') {
            if ($currentLines.Count -gt 0) {
                # First {word} in the block is always the identifier value
                $blockId = $null
                foreach ($bl in $currentLines) {
                    if ($bl -match '(\{[a-zA-Z0-9_-]+\})') {
                        $blockId = $Matches[1]
                        break
                    }
                }
                $blocks.Add([PSCustomObject]@{ Identifier = $blockId; Lines = $currentLines })
                $currentLines = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }
        $currentLines.Add($trimmed)
    }
    # Flush last block (no trailing empty line)
    if ($currentLines.Count -gt 0) {
        $blockId = $null
        foreach ($bl in $currentLines) {
            if ($bl -match '(\{[a-zA-Z0-9_-]+\})') {
                $blockId = $Matches[1]
                break
            }
        }
        $blocks.Add([PSCustomObject]@{ Identifier = $blockId; Lines = $currentLines })
    }

    # ----- L10N-safe device value helpers -----
    # 'unknown' as a standalone value after whitespace = broken device reference.
    # 'partition=...' = healthy device reference (never localized).
    function _HasUnknownDevice ([string[]]$Lines) {
        foreach ($l in $Lines) {
            if ($l -match '\s{2,}unknown\s*$') { return $true }
        }
        return $false
    }

    function _GetDeviceValues ([string[]]$Lines) {
        $vals = [System.Collections.Generic.List[string]]::new()
        foreach ($l in $Lines) {
            if ($l -match '\s{2,}(partition=\S+)') {
                $vals.Add($Matches[1])
            }
        }
        return $vals
    }

    # ----- Boot Manager: {bootmgr} -----
    $bootMgrFound = $false
    foreach ($block in $blocks) {
        if ($block.Identifier -and $block.Identifier -match '\{bootmgr\}') {
            $bootMgrFound = $true
            if (_HasUnknownDevice $block.Lines) {
                Write-Output '[!!]  Boot Manager device: unknown'
                Write-Output '       Boot Manager points to an UNKNOWN volume. BCD is corrupted.'
                Write-Output '       Remediation: bcdboot C:\Windows /s S: /f UEFI'
                $blockers.Add('Boot Manager device is unknown -- BCD corrupted')
                $bcdIssues++
                $findings.Add([PSCustomObject]@{ Check = 'BCD Boot Manager device'; Status = 'ISSUE'; Detail = 'Device is UNKNOWN.' })
            }
            else {
                $devVals = _GetDeviceValues $block.Lines
                $devStr = if ($devVals.Count -gt 0) { $devVals -join ', ' } else { 'present' }
                Write-Output "[OK]  Boot Manager device: $devStr"
                $findings.Add([PSCustomObject]@{ Check = 'BCD Boot Manager device'; Status = 'OK'; Detail = $devStr })
            }
            break
        }
    }

    if (-not $bootMgrFound) {
        Write-Output '[!]   Could not locate Boot Manager ({bootmgr}) in BCD.'
        $warnings.Add('Boot Manager block not found in BCD')
        $findings.Add([PSCustomObject]@{ Check = 'BCD Boot Manager'; Status = 'WARN'; Detail = 'Block with identifier {bootmgr} not found.' })
    }

    # ----- OS Loader: {current} or {default} -----
    $osLoaderFound = $false
    foreach ($block in $blocks) {
        if ($block.Identifier -and ($block.Identifier -match '\{current\}' -or $block.Identifier -match '\{default\}')) {
            $osLoaderFound = $true
            $identifier = $block.Identifier
            if (_HasUnknownDevice $block.Lines) {
                Write-Output "[!!]  OS Loader ($identifier) contains an unknown device reference"
                Write-Output '       One or more device paths point to an UNKNOWN volume. BCD is broken.'
                Write-Output '       Remediation: bcdboot C:\Windows /s S: /f UEFI'
                $blockers.Add("OS Loader device is unknown ($identifier)")
                $bcdIssues++
                $findings.Add([PSCustomObject]@{ Check = "BCD OS Loader ($identifier)"; Status = 'ISSUE'; Detail = 'Device reference is UNKNOWN.' })
            }
            else {
                $devVals = _GetDeviceValues $block.Lines
                $devStr = if ($devVals.Count -gt 0) { $devVals -join ', ' } else { 'present' }
                Write-Output "[OK]  OS Loader ($identifier) devices: $devStr"
                $findings.Add([PSCustomObject]@{ Check = "BCD OS Loader ($identifier)"; Status = 'OK'; Detail = $devStr })
            }
            break
        }
    }

    if (-not $osLoaderFound) {
        Write-Output '[!]   Could not locate {current} or {default} OS Loader in BCD.'
        $warnings.Add('OS Loader block not found for {current}/{default}')
        $findings.Add([PSCustomObject]@{ Check = 'BCD OS Loader'; Status = 'WARN'; Detail = 'Could not find {current} or {default} loader.' })
    }

    if ($bcdIssues -eq 0 -and $bootMgrFound -and $osLoaderFound) {
        Write-Output '[OK]  All BCD paths are consistent. Boot configuration appears healthy.'
    }
}

Write-Output ''

# ============================================================
# Section 4: WinRE Health (ReAgent.xml -- L10N-safe)
# ============================================================
Write-Output '--- WinRE Health ---'

# Parse ReAgent.xml directly -- this is the source reagentc.exe reads from.
# XML is structured and language-independent.
$reAgentPath = Join-Path $env:WinDir 'System32\Recovery\ReAgent.xml'
$reAgentXml = $null

if (Test-Path $reAgentPath) {
    try {
        [xml]$reAgentXml = Get-Content -Path $reAgentPath -ErrorAction Stop
    }
    catch { }
}

if ($null -eq $reAgentXml) {
    Write-Output '[!]   ReAgent.xml not found or could not be parsed.'
    Write-Output '       WinRE configuration file missing. Recovery environment status unknown.'
    $warnings.Add('ReAgent.xml not found or unreadable')
    $findings.Add([PSCustomObject]@{ Check = 'WinRE Health'; Status = 'WARN'; Detail = 'ReAgent.xml not found or could not be parsed.' })
}
else {
    # InstallState: state="1" = Enabled, state="0" = Disabled
    $winreState = $reAgentXml.WindowsRE.InstallState.state
    if ($winreState -eq '1') {
        Write-Output '[OK]  WinRE Status: Enabled'
        $findings.Add([PSCustomObject]@{ Check = 'WinRE Status'; Status = 'OK'; Detail = 'Enabled.' })
    }
    elseif ($winreState -eq '0') {
        Write-Output '[!!]  WinRE Status: Disabled'
        Write-Output '       WinRE is DISABLED. Silent encryption (Intune/MDM) CANNOT proceed without WinRE.'
        Write-Output '       Remediation: reagentc /enable'
        Write-Output '       If that fails, the WinRE partition may be too small (CVE-2024-20666 fallout).'
        $blockers.Add('WinRE is Disabled -- silent encryption blocked')
        $findings.Add([PSCustomObject]@{ Check = 'WinRE Status'; Status = 'ISSUE'; Detail = 'Disabled. Silent encryption blocked. Run reagentc /enable.' })
    }
    else {
        Write-Output "[!]   WinRE Status: Unknown (InstallState = $winreState)"
        $warnings.Add('Could not determine WinRE status')
        $findings.Add([PSCustomObject]@{ Check = 'WinRE Status'; Status = 'WARN'; Detail = "Unknown InstallState value: $winreState" })
    }

    # WinreLocation: path and partition info from XML
    $winreLocNode = $reAgentXml.WindowsRE.WinreLocation
    if ($winreLocNode) {
        $winrePath = $winreLocNode.path
        $winreGuid = $winreLocNode.guid
        if (-not [string]::IsNullOrWhiteSpace($winrePath)) {
            Write-Output "[OK]  WinRE Location: $winrePath"
            if ($winreGuid) {
                Write-Output "       Partition GUID: $winreGuid"
            }
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Location'; Status = 'OK'; Detail = $winrePath })
        }
        elseif ($winreState -eq '1') {
            Write-Output '[!]   WinRE Location: empty despite WinRE being enabled.'
            Write-Output '       WinRE image path may be missing or corrupted.'
            $warnings.Add('WinRE location empty despite enabled status')
            $findings.Add([PSCustomObject]@{ Check = 'WinRE Location'; Status = 'WARN'; Detail = 'Empty despite WinRE enabled.' })
        }
    }

    # WinreBCD: BCD identifier from XML
    $winreBcdNode = $reAgentXml.WindowsRE.WinreBCD
    if ($winreBcdNode) {
        $reBcdId = $winreBcdNode.id
        if ($reBcdId -match '\{00000000-0000-0000-0000-000000000000\}') {
            Write-Output "[!!]  BCD identifier: $reBcdId"
            Write-Output '       NULL GUID detected. Severe BCD-to-WinRE linkage failure.'
            Write-Output '       The boot manager cannot locate the recovery environment.'
            Write-Output '       Remediation: reagentc /setreimage /path <WinRE_path> then reagentc /enable'
            $blockers.Add('WinRE BCD identifier is null GUID -- severe linkage break')
            $findings.Add([PSCustomObject]@{ Check = 'WinRE BCD ID'; Status = 'ISSUE'; Detail = 'NULL GUID. Severe BCD/WinRE linkage failure.' })
        }
        elseif ($reBcdId -match '\{[0-9a-fA-F-]+\}') {
            Write-Output "[OK]  BCD identifier: $reBcdId (valid)"
            $findings.Add([PSCustomObject]@{ Check = 'WinRE BCD ID'; Status = 'OK'; Detail = "$reBcdId (valid)" })
        }
        elseif (-not [string]::IsNullOrWhiteSpace($reBcdId)) {
            Write-Output "[!]   BCD identifier: $reBcdId (unexpected format)"
            $warnings.Add("WinRE BCD identifier unexpected: $reBcdId")
            $findings.Add([PSCustomObject]@{ Check = 'WinRE BCD ID'; Status = 'WARN'; Detail = "$reBcdId (unexpected format)" })
        }
    }
}

Write-Output ''

# ============================================================
# Section 5: PCR Validation Profile (manage-bde -protectors -get)
# ============================================================
Write-Output '--- PCR Validation Profile ---'

$pcrOutput = $null

if ($manageBdeAvailable) {
    try {
        $pcrOutput = & manage-bde.exe -protectors -get $osDrive 2>&1
    }
    catch { }
}

if (-not $pcrOutput) {
    Write-Output "[i]   manage-bde -protectors -get not available or returned no output."
    Write-Output '       PCR validation profile cannot be assessed.'
    $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = 'manage-bde protectors output not available.' })
}
else {
    $pcrLines = @($pcrOutput | ForEach-Object { "$_" })

    # Look for TPM protector block and PCR Validation Profile
    $tpmBlockFound = $false
    $pcrProfile = $null
    $inTpmBlock = $false

    foreach ($line in $pcrLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\s*TPM\s*:?\s*$' -or $trimmed -match '^\s*TPM\s*$') {
            $inTpmBlock = $true
            $tpmBlockFound = $true
            continue
        }
        if ($inTpmBlock) {
            if ($trimmed -match 'PCR Validation Profile') {
                $pcrProfile = $trimmed -replace '.*PCR Validation Profile\s*[:]?\s*', ''
                break
            }
            # Exit TPM block if we hit another protector type
            if ($trimmed -match '^\s*(Numerical Password|External Key|Recovery Password|Startup Key|Password|Certificate)\s*:?\s*$') {
                $inTpmBlock = $false
            }
        }
    }

    if (-not $tpmBlockFound) {
        Write-Output "[i]   No TPM protector found on $osDrive."
        Write-Output '       This is expected if the volume is not yet encrypted.'
        Write-Output '       PCR binding will be established when encryption begins.'
        $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = 'No TPM protector found. Expected if volume is not encrypted.' })
    }
    elseif ($pcrProfile) {
        # Analyze PCR profile
        $pcrNumbers = @($pcrProfile -replace '[^0-9,\s]', '' -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })

        $isIdeal = ($pcrNumbers.Count -eq 2 -and $pcrNumbers -contains 7 -and $pcrNumbers -contains 11)
        $isDegraded = ($pcrNumbers -contains 0 -and $pcrNumbers -contains 2 -and $pcrNumbers -contains 4 -and $pcrNumbers -contains 11 -and $pcrNumbers -notcontains 7)

        if ($isIdeal) {
            Write-Output "[OK]  PCR Validation Profile: $pcrProfile"
            Write-Output '       Ideal binding: PCR 7 (Secure Boot) + PCR 11 (BitLocker Access Control).'
            Write-Output '       Firmware updates will NOT trigger recovery key prompts.'
            $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'OK'; Detail = "$pcrProfile -- ideal Secure Boot binding." })
        }
        elseif ($isDegraded) {
            Write-Output "[!!]  PCR Validation Profile: $pcrProfile"
            Write-Output '       DEGRADED LEGACY PROFILE: PCR 0,2,4,11 detected.'
            Write-Output '       The system fell back to legacy PCR measurements instead of PCR 7 (Secure Boot).'
            Write-Output '       This typically indicates unsigned Option ROM (OROM) interference from dGPU or RAID controller.'
            Write-Output '       Impact: minor firmware/driver changes WILL trigger BitLocker recovery key prompts.'
            Write-Output '       Resolution: update BIOS/UEFI firmware, or disable Secure Boot for the offending device.'
            Write-Output '       This is NOT fixable from the OS -- requires BIOS/vendor action.'
            $warnings.Add('Degraded PCR profile (0,2,4,11) -- OROM fallback detected')
            $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'WARN'; Detail = "$pcrProfile -- degraded legacy profile. OROM interference likely." })
        }
        else {
            Write-Output "[i]   PCR Validation Profile: $pcrProfile"
            Write-Output '       Custom or non-standard PCR binding detected.'
            $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = "$pcrProfile -- non-standard profile." })
        }
    }
    else {
        Write-Output "[i]   TPM protector found but no PCR Validation Profile line detected."
        $findings.Add([PSCustomObject]@{ Check = 'PCR Validation'; Status = 'INFO'; Detail = 'TPM protector present but PCR profile not found in output.' })
    }
}

Write-Output ''

# ============================================================
# Readiness Verdict
# ============================================================
Write-Output '--- Readiness Verdict ---'

$blockerCount = $blockers.Count
$warningCount = $warnings.Count

if ($blockerCount -eq 0 -and $warningCount -eq 0) {
    Write-Output 'RESULT: READY FOR ENCRYPTION. No blocking conditions detected.'
}
elseif ($blockerCount -eq 0 -and $warningCount -gt 0) {
    Write-Output "RESULT: CONDITIONALLY READY. $warningCount warning(s) found but no hard blockers."
    Write-Output '        Review warnings above before proceeding with encryption.'
}
else {
    Write-Output "RESULT: NOT READY. $blockerCount blocker(s) and $warningCount warning(s) detected."
    Write-Output '        Address the issues marked [!!] above before attempting encryption.'
    Write-Output ''
    Write-Output '        Blockers:'
    foreach ($b in $blockers) {
        Write-Output "        - $b"
    }
}

if ($warningCount -gt 0 -and $blockerCount -gt 0) {
    Write-Output ''
    Write-Output '        Warnings:'
    foreach ($w in $warnings) {
        Write-Output "        - $w"
    }
}

Write-Output ''
Write-Output 'NEXT:   If WinRE disabled         -> run: reagentc /enable'
Write-Output '        If boot config broken      -> run: bcdboot C:\Windows /s S: /f UEFI'
Write-Output '        If ghost state detected    -> run: manage-bde -off C: (then re-encrypt)'
Write-Output '        If orphaned protectors     -> run: manage-bde -protectors -delete C: -type RecoveryPassword'
Write-Output '        If TPM issues              -> run BL002 BLTpmHealth'
Write-Output '        If hardware prerequisites  -> run BL003 BLHardwarePrereqs'
Write-Output '        If policy issues           -> run BL006 BLPolicyConflict'
Write-Output '        If all checks pass         -> system is ready for encryption'
Write-Output ''

