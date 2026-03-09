<#
.SYNOPSIS
    Synchronize Entra ID PKI trust store with Federal PKI.
    1. Compares Entra ID CAs against Federal P7B.
    2. Uploads deltas to GitHub (with SHA256 Hashing).
    3. Cleans up expired CAs in Entra ID.
    4. Triggers Graph PkiBundle Upload.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 1. LOAD CONFIGURATION
$ConfigFile = Join-Path $ScriptPath "config.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found at $ConfigFile"
}

$Cfg = Get-Content $ConfigFile | ConvertFrom-Json
$Timestamp = Get-Date -Format "yyyyMMdd_HHmm"

# 2. DYNAMIC PATH SETUP
$LogFolder = Join-Path $ScriptPath "Logs"
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder | Out-Null }
$LogFile   = Join-Path $LogFolder "Sync_$Timestamp.log"

# Setup GitHub specific URIs
$GitLocalFile = Join-Path $ScriptPath (Split-Path $Cfg.GitHub.RepoPath -Leaf)
$GitApiUrl    = "https://api.github.com/repos/$($Cfg.GitHub.Owner)/$($Cfg.GitHub.Repo)/contents/$($Cfg.GitHub.RepoPath)"
$GitRawUrl    = "https://raw.githubusercontent.com/$($Cfg.GitHub.Owner)/$($Cfg.GitHub.Repo)/$($Cfg.GitHub.Branch)/$($Cfg.GitHub.RepoPath)"

Start-Transcript -Path $LogFile -Append

# ============================
# FUNCTIONS
# ============================

function Write-Log {
    param([string]$Message, [ConsoleColor]$Color = "White")
    $Stamp = Get-Date -Format "HH:mm:ss"
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
    $existing = $resp.value | Where-Object { $_.displayName -eq $Cfg.Entra.PkiDisplayName }
    if ($existing) { return $existing }

    Write-Log "Creating new PKI container..." -Color Yellow
    $payload = @{ displayName = $Cfg.Entra.PkiDisplayName }
    return Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations" -Body ($payload | ConvertTo-Json)
}

function Compare-CAs {
    param($PkiId, $SourceUrl, $ExportPath)
    Write-Log "Comparing Entra ID CAs with Federal source..." -Color Cyan
    
    $currentCAs = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$PkiId/certificateAuthorities"
    $tempFile = Join-Path $env:TEMP "federal_source.p7b"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $tempFile -UseBasicParsing
    
    $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certs.Import([System.IO.File]::ReadAllBytes($tempFile))

    $delta = @($certs) | Where-Object { ($_.Thumbprint -notin $currentCAs.value.thumbprint) -and ($_.NotAfter -gt (Get-Date)) }

    if ($delta.Count -gt 0) {
        Write-Log "Found $($delta.Count) new CAs. Exporting to $ExportPath..." -Color Yellow
        $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $collection.AddRange($delta)
        [IO.File]::WriteAllBytes($ExportPath, $collection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7))
        
        return (Get-FileHash -Path $ExportPath -Algorithm SHA256).Hash
    }
    return $null
}

function Publish-ToGitHub {
    param($LocalFilePath, $ApiUrl)
    Write-Log "Uploading to GitHub..." -Color Cyan
    $B64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalFilePath))
    $headers = @{ Authorization = "token $($Cfg.GitHub.Token)"; "User-Agent" = "ps-upload"; Accept = "application/vnd.github+json" }

    $existingSha = $null
    try {
        $ub = New-Object System.UriBuilder($ApiUrl); $ub.Query = "ref=$($Cfg.GitHub.Branch)"
        $resp = Invoke-RestMethod -Method Get -Uri $ub.Uri.AbsoluteUri -Headers $headers -ErrorAction Stop
        $existingSha = $resp.sha
    } catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw $_ } }

    $body = @{ message = "Sync [Hash: $(Get-Date -Format 's')]"; branch = $Cfg.GitHub.Branch; content = $B64 }
    if ($existingSha) { $body.sha = $existingSha }

    $result = Invoke-RestMethod -Method Put -Uri $ApiUrl -Headers $headers -Body ($body | ConvertTo-Json -Depth 5) -ContentType "application/json"
    Write-Log "GitHub Update Successful: $($result.commit.html_url)" -Color Green
}

function Remove-ExpiredCAs {
    param($PkiId)
    $cas = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$PkiId/certificateAuthorities").value
    foreach ($ca in $cas) {
        if ($ca.expirationDateTime -and ([DateTime]::Parse($ca.expirationDateTime) -lt (Get-Date))) {
            Write-Log "Removing expired CA: $($ca.displayName)" -Color Yellow
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$PkiId/certificateAuthorities/$($ca.id)"
        }
    }
}

function Cleanup-TempFiles {
    param(
        [string[]]$FilesToPaths
    )
    Write-Log "Cleaning up temporary files..." -Color Cyan
    foreach ($FilePath in $FilesToPaths) {
        if (Test-Path $FilePath) {
            try {
                Remove-Item -Path $FilePath -Force -ErrorAction Stop
                Write-Log "Deleted: $(Split-Path $FilePath -Leaf)" -Color Gray
            } catch {
                Write-Log "Failed to delete $FilePath : $($_.Exception.Message)" -Color Yellow
            }
        }
    }
}

# ============================
# MAIN EXECUTION
# ============================

try {    
    Connect-GraphApp
    $Pki = Get-OrCreate-PkiContainer
    $DeltaHash = Compare-CAs -PkiId $Pki.id -SourceUrl $Cfg.Source.FpkiUrl -ExportPath $GitLocalFile

    if ($DeltaHash) {
        
        Publish-ToGitHub -LocalFilePath $GitLocalFile -ApiUrl $GitApiUrl
        Remove-ExpiredCAs -PkiId $Pki.id
        
        # Trigger Entra ID Upload Action
        $uploadBody = @{ uploadUrl = $GitRawUrl; sha256FileHash = $DeltaHash }
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations/$($Pki.id)/upload" -Body ($uploadBody | ConvertTo-Json)
        Write-Log "Entra ID Upload Job Triggered." -Color Green

    } else {
        Write-Log "No changes detected." -Color Green
    }
}
catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Color Red
}
finally {
    # Cleanup the local P7B and the temp source file
    Cleanup-TempFiles -FilesToPaths @($GitLocalFile, (Join-Path $env:TEMP "federal_source.p7b"))
    Stop-Transcript
}