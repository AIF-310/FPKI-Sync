# Entra ID PKI Sync Tool

## ���lHݙ\��Y]\���]]�X]\�HY�X�X�Hو�Y\�[�H�\�[�ZXܛ��ٝ[��HQ�]\��ܛ\�H[H��\\�\�ۈ�]�Y[�H�Y\�[��[[ۈ�X�H�H̈��\��H[�[�\�[��HQ[�[��[�\�]\�H�\]Z\�YЈ�[�Kܘ�\��]\�H\�Y[��[�����\�˂��KKB����<'案�\�\]Z\�]\�	��]\�����K���\��[[��\�ۛY[���
���[������\��[K�J��
�\]Z\�Y�܈��ULH�\�Y�X�]H��X�[ۈ[�[��K���
��ZXܛ��ٝ�ܘ\[�[H
���
N�����\��[[��[S[�[HZXܛ��ٝ�ܘ\T���H�\��[�\�\���������^�\�HQ\�Y�\��][ۂ�H�ܚ\\�\�
���\�Y�X�]KP�\�Y]][�X�][ۈ
АJJ���[�\�X��]HZXܛ��ٝܘ\TK���
��\�Z\��[ۜΊ��YX�X��^R[���\��X�\�K��XYܚ]K�[
\X�][ۈ\�Z\��[ۊK���
���YZ[��ۜ�[����[�YZ[�\��]܈]\��X��
���ܘ[�YZ[��ۜ�[��܈�[�[�H���[�H^�\�Hܝ[���
����[Y[�][ێ����ԙY�\�\�[�\X�][ۈ�]HZXܛ��ٝY[�]H]�ܛWJ΋��X\���ZXܛ��ٝ���K�[�]\��[��K�Y[�]K\]�ܛK�]ZX���\�\�Y�\�\�X\
B�����ˈ�]X�\��ۘ[X��\����[�
U
B�H�ript requires a PAT to write the `.p7b` file to your repository.
+ **Scopes:** Select `repo` (Full control of private repositories).
+ **$Documentation:** [Creating a personal access token (classic)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic)

---

## ♫️ Configuration (`config.json`)
Create this file in the script root directory. **Warning: This file contains secrets; ensure it is excluded from source control.**

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

---

## ↿ Logic & Permissions Reference
The script interacts with the following endpoints.

| Function | Endpoint | Method | Purpose |
| :C_-- | :--- | :--- | :--- |
| `Get-OrCreate-PkiContainer` | `/directory/publicKeyInfrastructure/certificateBasedAuthConfigurations` | `GET/POST` | Locates or creates the PKI trust store. |
| `Compare-CAs` | `.../certificateAuthorities` | [GET] | Inventories current CAs. |
| `Publish-ToGitHub` | `api.github.com/repos/...` | [GET/PUT] | Hosts the new P7B delta. |
| `Remove-ExpiredCAs` | `.../certificateAuthorities/{id}`| [DELETE] | Removes expired certs. |
| `Start-EntraPkiUpload` | `.../upload` | [POST] | Triggers Entra sync via URL. |

---

## 🫗 Security & Local Cleanup
 
1. *(Local Cleanup:** Script deletes the local delta `.p7b` and temp source files in the `finally` block.
2. **Git Protection:** Add `config.json` and `Logs/` to your `.gitignore`.

---

## 📂 How to Run
`Fpowershell
.\Sync-EntraPki.ps1
```
