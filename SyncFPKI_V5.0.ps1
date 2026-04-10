<#
.SYNOPSIS
    Synchronize Entra ID PKI trust store with Federal PKI.
    1. Fetches all Entra ID CAs (Handling Graph Pagination).
    2. Compares Entra ID CAs against Federal P7B.
    3. Uploads deltas to GitHub (with SHA256 Hashing).
    4. Cleans up expired CAs in Entra ID.
    5. Triggers Graph PkiBundle Upload.
    6. Logs and exports Current, Federal, Delta, and Expired CAs.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ============================
# 1. SETUP & CONFIGURATION
# ============================

$ConfigFile = Join-Path $ScriptPath "config.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found at $ConfigFile"
    exit
}

$Cfg = Get-Content $ConfigFile | ConvertFrom-Json
$Now = Get-Date
$Timestamp = $Now.ToString("yyyyMMdd_HHmm")

$LogFolder = Join-Path $ScriptPath "Logs"
if (-not (Test-Path $LogFolder)) { [void](New-Item -ItemType Directory -Path $LogFolder) }
$LogFile   = Join-Path $LogFolder "Sync_$Timestamp.log"

$GitLocalFile = Join-Path $ScriptPath (Split-Path $Cfg.GitHub.RepoPath -Leaf)
$GitApiUrl    = "https://api.github.com/repos/$($Cfg.GitHub.Owner)/$($Cfg.GitHub.Repo)/contents/$($Cfg.GitHub.RepoPath)"
$GitRawUrl    = "https://raw.githubusercontent.com/$($Cfg.GitHub.Owner)/$($Cfg.GitHub.Repo)/$($Cfg.GitHub.Branch)/$($Cfg.GitHub.RepoPath)"

Start-Transcript -Path $LogFile -Append

# ============================
# FUNCTIONS
# ============================

function Write-Log {
    param([string]$Message, [ConsoleColor]$Color = "White")
    $Stamp = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$Stamp] $Message" -ForegroundColor $Color
}

function Connect-GraphApp {
    Write-Log "Connecting to Microsoft Graph..." -Color Cyan
    Connect-MgGraph -TenantId $Cfg.Entra.TenantId `
                    -ClientId $Cfg.Entra.ClientId `
                    -CertificateThumbprint $Cfg.Entra.CertificateThumbprint
}

function Get-OrCreate-PkiContainer {
    $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations"
    foreach ($config in $resp.value) {
        if ($config.displayName -eq $Cfg.Entra.PkiDisplayName) { return $config }
    }

    Write-Log "Creating new PKI container..." -Color Yellow
    $payload = @{ displayName = $Cfg.Entra.PkiDisplayName }
    return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations" -Body ($payload | ConvertTo-Json)
}

function Get-EntraCAs {
    param($PkiId)
    Write-Log "Fetching all existing CAs from Entra ID..." -Color Cyan
    
    # FIX: Changed to [object] to match Graph's JSON deserialization
    $allCAs = [System.Collections.Generic.List[object]]::new()
    $uri = "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$PkiId/certificateAuthorities"
    
    do {
        $pageResult = Invoke-MgGraphRequest -Method GET -Uri $uri
        if ($pageResult.value) { 
            # FIX: Iterate and Add instead of AddRange to bypass PS 5.1 type casting errors
            foreach ($item in $pageResult.value) {
                $allCAs.Add($item)
            }
        }
        $uri = $pageResult.'@odata.nextLink'
    } while ($uri)
    
    return $allCAs
}

function Compare-CAs {
    param($EntraCAs, $SourceUrl, $ExportPath)
    Write-Log "Comparing Entra ID CAs with Federal source..." -Color Cyan
    
    if ($EntraCAs.Count -gt 0) {
        $EntraCAs | Export-Csv -Path (Join-Path $LogFolder "EntraCAs_$Timestamp.csv") -NoTypeInformation
    }
    
    $tempFile = Join-Path $env:TEMP "federal_source.p7b"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $tempFile -UseBasicParsing
    $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certs.Import([System.IO.File]::ReadAllBytes($tempFile))

    $global:FederalCAs = $certs | Select-Object Subject, Thumbprint, NotBefore, NotAfter, Issuer
    if ($global:FederalCAs) {
        $global:FederalCAs | Export-Csv -Path (Join-Path $LogFolder "FederalCAs_$Timestamp.csv") -NoTypeInformation
    }

    $thumbprintSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ca in $EntraCAs) {
        if ($ca.thumbprint) { [void]$thumbprintSet.Add($ca.thumbprint) }
    }

    $deltaList = [System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]]::new()
    foreach ($cert in $certs) {
        if (-not $thumbprintSet.Contains($cert.Thumbprint) -and $cert.NotAfter -gt $Now) {
            $deltaList.Add($cert)
        }
    }

    $global:DeltaCAs = $deltaList | Select-Object Subject, Thumbprint, NotBefore, NotAfter, Issuer
    if ($global:DeltaCAs.Count -gt 0) {
        $global:DeltaCAs | Export-Csv -Path (Join-Path $LogFolder "DeltaCAs_$Timestamp.csv") -NoTypeInformation
    }

    if ($deltaList.Count -gt 0) {
        Write-Log "Found $($deltaList.Count) new CAs. Exporting to $ExportPath..." -Color Yellow
        $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $collection.AddRange($deltaList.ToArray())
        [System.IO.File]::WriteAllBytes($ExportPath, $collection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7))
        
        return (Get-FileHash -Path $ExportPath -Algorithm SHA256).Hash
    }
    return $null
}

function Publish-ToGitHub {
    param($LocalFilePath, $ApiUrl)
    Write-Log "Uploading to GitHub..." -Color Cyan
    $B64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($LocalFilePath))
    $headers = @{ Authorization = "token $($Cfg.GitHub.Token)"; "User-Agent" = "ps-upload"; Accept = "application/vnd.github+json" }

    $existingSha = $null
    try {
        $ub = New-Object System.UriBuilder($ApiUrl); $ub.Query = "ref=$($Cfg.GitHub.Branch)"
        $existingSha = (Invoke-RestMethod -Method Get -Uri $ub.Uri.AbsoluteUri -Headers $headers -ErrorAction Stop).sha
    } catch { 
        if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw $_ } 
    }

    $body = @{ message = "Sync [Hash: $($Now.ToString('s'))]"; branch = $Cfg.GitHub.Branch; content = $B64 }
    if ($existingSha) { $body.sha = $existingSha }

    $result = Invoke-RestMethod -Method Put -Uri $ApiUrl -Headers $headers -Body ($body | ConvertTo-Json -Depth 2 -Compress) -ContentType "application/json"
    Write-Log "GitHub Update Successful: $($result.commit.html_url)" -Color Green
}

function Remove-ExpiredCAs {
    param($PkiId, $EntraCAs)
    if ($EntraCAs.Count -eq 0) { return }

    # FIX: Changed to [object] for consistency
    $expiredList = [System.Collections.Generic.List[object]]::new()

    foreach ($ca in $EntraCAs) {
        if ($ca.expirationDateTime -and ([DateTime]::Parse($ca.expirationDateTime) -lt $Now)) {
            Write-Log "Removing expired CA: $($ca.displayName)" -Color Yellow
            $expiredList.Add($ca)
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$PkiId/certificateAuthorities/$($ca.id)"
        }
    }

    $global:ExpiredCAs = $expiredList
    if ($global:ExpiredCAs.Count -gt 0) {
        $global:ExpiredCAs | Export-Csv -Path (Join-Path $LogFolder "ExpiredCAs_$Timestamp.csv") -NoTypeInformation
    }
}

function Cleanup-TempFiles {
    param([string[]]$FilesToPaths)
    Write-Log "Cleaning up temporary files..." -Color Cyan
    foreach ($FilePath in $FilesToPaths) {
        if (Test-Path $FilePath) {
            try { [void](Remove-Item -Path $FilePath -Force -ErrorAction Stop) } 
            catch { Write-Log "Failed to delete $FilePath : $($_.Exception.Message)" -Color Yellow }
        }
    }
}

# ============================
# MAIN EXECUTION
# ============================

try {    
    Connect-GraphApp
    $Pki = Get-OrCreate-PkiContainer
    
    $global:EntraCAs = Get-EntraCAs -PkiId $Pki.id
    
    $DeltaHash = Compare-CAs -EntraCAs $global:EntraCAs -SourceUrl $Cfg.Source.FpkiUrl -ExportPath $GitLocalFile

    if ($DeltaHash) {
        Publish-ToGitHub -LocalFilePath $GitLocalFile -ApiUrl $GitApiUrl
        
        $uploadBody = @{ uploadUrl = $GitRawUrl; sha256FileHash = $DeltaHash }
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$($Pki.id)/upload" -Body ($uploadBody | ConvertTo-Json -Compress)
        Write-Log "Entra ID Upload Job Triggered." -Color Green
    } else {
        Write-Log "No new CAs to upload." -Color Green
    }

    Remove-ExpiredCAs -PkiId $Pki.id -EntraCAs $global:EntraCAs
}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Color Red
}
finally {
    Cleanup-TempFiles -FilesToPaths @($GitLocalFile, (Join-Path $env:TEMP "federal_source.p7b"))
    Stop-Transcript
}