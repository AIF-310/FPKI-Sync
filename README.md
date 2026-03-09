# Entra ID PKI Sync Tool

Automates the lifecycle of Federal PKI trust in Microsoft Entra ID by comparing your tenant’s CA configuration with the Federal Common Policy CA G2 source, generating a delta P7B bundle, and orchestrating the upload and sync process.

## Table of Contents
- [Overview](#overview)
- [Prerequisites & Setup](#prerequisites--setup)
  - [PowerShell Environment](#1-powershell-environment)
  - [Azure AD App Registration](#2-azure-ad-app-registration)
  - [Github account] with a [GitHub Personal Access Token (PAT)](#3-github-personal-access-token-pat)
- [Configuration (config.json)](#configuration-configjson)
- [Logic & Permissions Reference](#logic--permissions-reference)
- [Security & Local Cleanup](#security--local-cleanup)
- [How to Run](#how-to-run)

## Overview
This tool automates the lifecycle of Federal PKI trust in Microsoft Entra ID. It performs a delta comparison between the Federal Common Policy CA G2 source and your Entra ID tenant, generates the required P7B bundle, and orchestrates the upload and sync process.

## Prerequisites & Setup
### 1. PowerShell Environment
- At least Windows PowerShell 5.1
- Microsoft.Graph Module minimum version(v2.x):
```
https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation?view=graph-powershell-1.0
```

### 2. Entra ID App Registration - 
The script uses Certificate-Based Authentication (CBA) to interact with Microsoft Graph.
- Required Permission: PublicKeyInfrastructure.ReadWrite.All (Application)
- Admin Consent: Must be granted in Azure Portal
- Reference: [Register an application with Microsoft Identity](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)


### 3. GitHub Account - https://docs.github.com/en/get-started/onboarding/getting-started-with-your-github-account
Personal Access Token (PAT) - 
Used to publish the .p7b file to your GitHub repository.
- Scopes: repo (full control of private repositories)
- Reference: [Creating a personal access token (classic)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic)

## Configuration (config.json)
Create this file in the script's root directory.
**Important:** Contains secrets. Exclude from source control.
```json
{
  "Entra": {
    "TenantId": "00000000-0000-0000-0000-000000000000",
    "ClientId": "00000000-0000-0000-0000-000000000000",
    "CertificateThumbprint": "YOUR_CERT_THUMBPRINT",
    "PkiDisplayName": "Federal PKI"
  },
  "GitHub": {
    "Token": "github_pat_YOUR_TOKEN",
    "Owner": "YourAccount",
    "Repo": "YourRepo",
    "Branch": "main",
    "RepoPath": "certs/bundle.p7b"
  },
  "Source": {
    "FpkiUrl": "https://www.idmanagement.gov/implement/tools/CACertificatesValidatingToFederalCommonPolicyG2.p7b"
  }
}
```

## Logic & Permissions Reference
| Function | Endpoint | Method | Purpose |
|---------|----------|--------|---------|
| Get-OrCreate-PkiContainer | /directory/publicKeyInfrastructure/certificateBasedAuthConfigurations | GET/POST | Finds or creates PKI trust store |
| Compare-CAs | .../certificateAuthorities | GET | Inventories current CAs to detect deltas |
| Publish-ToGitHub | api.github.com/repos/... | GET/PUT | Publishes updated P7B bundle for Entra |
| Remove-ExpiredCAs | .../certificateAuthorities/{id} | DELETE | Removes expired certs to prevent sync failures |
| Start-EntraPkiUpload | .../upload | POST | Notifies Entra to pull updated bundle via URL + hash |

## Security & Local Cleanup
- The script deletes temporary .p7b and source files on completion.
- Add the following to .gitignore:
  - config.json
  - Logs/
This prevents accidental exposure of credentials or sensitive data.

## How to Run
Run the script from an elevated PowerShell session:
```
.\Sync-EntraPki.ps1
```
