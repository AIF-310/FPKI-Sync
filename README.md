Entra ID PKI Sync Tool🚀 OverviewThis tool automates the lifecycle of Federal PKI trust in Microsoft Entra ID. It performs a delta comparison between the Federal Common Policy CA G2 source and your Entra ID tenant, generates the required P7B bundle, and orchestrates the upload and sync process.🛠️ Prerequisites & Setup1. PowerShell EnvironmentWindows PowerShell 5.1 (Required for .NET X509 certificate collection handling).Microsoft.Graph Module (v2.x):PowerShellInstall-Module Microsoft.Graph -Scope CurrentUser
2. Azure AD App RegistrationThe script uses Certificate-Based Authentication (CBA) to interact with the Microsoft Graph API.Permissions: Add PublicKeyInfrastructure.ReadWrite.All (Application Permission).Admin Consent: An administrator must click "Grant admin consent" in the Azure Portal.Documentation: Register an application with Microsoft Identity3. GitHub Personal Access Token (PAT)The script requires a PAT to write the .p7b file to your repository.Scopes: Select repo (Full control of private repositories).Documentation: Creating a personal access token (classic)⚙️ Configuration (config.json)Create this file in the script root directory. Warning: This file contains secrets; ensure it is excluded from source control.JSON{
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
🔄 Logic & Permissions ReferenceThe script interacts with the following endpoints. Ensure your App Registration is scoped correctly.FunctionEndpointMethodPurposeGet-OrCreate-PkiContainer/directory/publicKeyInfrastructure/certificateBasedAuthConfigurationsGET/POSTLocates or creates the PKI trust store.Compare-CAs.../certificateAuthoritiesGETInventories current CAs to find missing ones.Publish-ToGitHubapi.github.com/repos/...GET/PUTHosts the new P7B delta for Entra ID to fetch.Remove-ExpiredCAs.../certificateAuthorities/{id}DELETERemoves expired certs to prevent sync errors.Start-EntraPkiUpload.../uploadPOSTDirects Entra ID to pull the new file via URL + Hash.🧹 Security & Local CleanupLocal Cleanup: The script deletes the local delta .p7b and temporary source files in the finally block to prevent sensitive data from lingering.Git Protection: Add config.json and Logs/ to your .gitignore file to prevent accidental credential leakage.📂 How to RunOpen PowerShell as an Administrator and execute:PowerShell.\Sync-EntraPki.ps1
