# Layer 1 — Commit-time security checks (pre-commit hooks)

**Project:** supply-chain (v2: full vulnerability lifecycle)
**Branch:** `New-supply-chain-with-SBOM`
**Date:** 2026-11-26

## 1. Purpose

Catch secrets, insecure code and Dockerfile mistakes **before they leave the developer laptop**.

Pre-commit hooks give fast feedback, but they are a **convenience, not a control**: any developer can skip them with `git commit --no-verify`. The controls that cannot be skipped run on the server side (GitHub push protection) and in CI (`pr.yml`). This layer is the first of four:

| Layer | Where | Purpose |
|---|---|---|
| **1. Commit** | Developer laptop | Fast feedback (this document) |
| 2. Pull request | GitHub Actions | Blocking checks before merge |
| 3. Build on main | GitHub Actions | Image scan gate, SBOM, signing, provenance |
| 4. Admission | Kubernetes cluster | Only verified images can run |

## 2. Tools

| Job | Tool | Notes |
|---|---|---|
| Secrets | **gitleaks** | Scans staged changes; config in `.gitleaks.toml` |
| SAST (Python, JavaScript) | **Semgrep Community Edition** | Replaced bandit; same tool can run in CI |
| Dockerfile lint | **hadolint** (`hadolint-docker` hook) | Runs in a container, needs Docker running |
| Hygiene | **pre-commit-hooks** | Private keys, large files, merge conflicts, YAML syntax |
| Secrets at push (server side) | **GitHub push protection** | Cannot be skipped with `--no-verify` |

**Why Semgrep instead of bandit:** one engine and one rule format for Python and JavaScript, used both locally and in CI. Semgrep CE analyses one file at a time; cross-file analysis needs the paid AppSec Platform.

## 3. Files added to the repository

| File | Purpose |
|---|---|
| `.pre-commit-config.yaml` | Hook definitions (gitleaks, Semgrep, hadolint, hygiene hooks) |
| `.gitleaks.toml` | gitleaks default rules plus a narrow allowlist (`docs/evidence/`) |
| `.gitattributes` | Forces LF line endings (see section 6.3) |

### `.pre-commit-config.yaml` (summary)

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    hooks:
      - id: gitleaks
  - repo: https://github.com/semgrep/pre-commit
    hooks:
      - id: semgrep
        entry: semgrep
        args: ['--config', 'p/python', '--config', 'p/javascript', '--error', '--skip-unknown-extensions']
  - repo: https://github.com/hadolint/hadolint
    hooks:
      - id: hadolint-docker
  - repo: https://github.com/pre-commit/pre-commit-hooks
    hooks:
      - id: detect-private-key
      - id: check-added-large-files
      - id: check-merge-conflict
      - id: check-yaml
        args: ['--allow-multiple-documents']
```

All hook versions are pinned to commit SHAs with `pre-commit autoupdate --freeze` (lesson from the Trivy GitHub Actions compromise of 19 March 2026: tags can be moved, SHAs cannot).

## 4. Setup (per clone)

```powershell
pip install pre-commit
pre-commit install                # hooks run on every git commit
pre-commit autoupdate --freeze    # latest releases, pinned to SHAs
pre-commit run --all-files        # baseline scan of the whole repo
```

GitHub side (repository **Settings → Advanced Security**): **Secret Protection** enabled and **Push protection: On**. The repository is public, so both are free.

## 5. Result of the first full run

```
Detect hardcoded secrets.....................Passed
semgrep......................................Passed
Lint Dockerfiles.............................(no files to check) Skipped
detect private key...........................Passed
check for added large files..................Passed
check for merge conflicts....................Passed
check yaml...................................Passed
```

Commit `f0c6039` ("Updated pre-commit") added `.gitleaks.toml` and `.pre-commit-config.yaml`. hadolint was skipped because the commit contained no Dockerfile.

## 6. Problems found and how they were solved

### 6.1 Semgrep crashed on Windows

**Symptom:** `semgrep-core exited with 3` and `Mingw-w64 runtime failure: VirtualProtect failed with code 0x5af`.

**Cause:** Windows error 0x5AF (1455) means *"The paging file is too small for this operation to complete"*: Windows refused to reserve more virtual memory for Semgrep's parallel workers. Semgrep's native Windows support is recent (2025); WSL and containers were the long-standing alternatives.

**Fix options:**
1. Limit Semgrep: add `'--jobs', '1', '--max-memory', '2000'` to the hook `args`.
2. Increase the Windows page file (System → Advanced system settings → Performance → Virtual memory → System managed size).
3. Long term: run the hooks from WSL2 (Ubuntu), which matches the Linux CI runners and containers.

**Outcome:** on the next run Semgrep passed.

### 6.2 hadolint could not start

**Symptom:** `failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine`.

**Cause:** the `hadolint-docker` hook runs hadolint in a container and Docker Desktop was not running.

**Fix:** start Docker Desktop before committing, or install the hadolint Windows binary and switch the hook to `id: hadolint`.

### 6.3 Line endings (LF vs CRLF)

**Symptom:** `warning: LF will be replaced by CRLF the next time Git touches it`.

**Risk:** shell scripts or entrypoints with Windows line endings fail inside Linux containers (`/bin/sh^M: bad interpreter`).

**Fix:** `.gitattributes` forcing LF for text files (CRLF only for `.bat`, `.cmd`, `.ps1`), then:

```powershell
git add .gitattributes
git add --renormalize .
git commit -m "Enforce LF line endings via .gitattributes"
```

## 7. Control tests

### 7.1 Secret detection: local hook vs GitHub push protection

| # | Test | Control | Result |
|---|---|---|---|
| 1 | Synthetic AWS access key ID only | GitHub push protection | **Not blocked**: AWS keys are detected as an ID + secret pair |
| 2 | Synthetic ID + 25-character lowercase "secret" | GitHub push protection | **Not blocked**: the secret does not have AWS's 40-character format |
| 3 | Valid-format synthetic pair (`AKIA` + 16 base32 characters, 40-character secret), normal commit | gitleaks hook | **Blocked** (`RuleID: generic-api-key`, line 2, entropy 5.17) |
| 4 | Same pair, `git commit --no-verify` then `git push` | GitHub push protection | **Not blocked**: push accepted (commit `8ca63de`) |
| 5 | After the push | GitHub secret scanning | **No alert** (0 open / 0 closed) |

**Lesson on test data:** the 16 characters after `AKIA` in a real AWS key ID are base32-encoded (A–Z and 2–7) and contain the account number. An early test key contained a `9`, which no real key can contain, so scanners correctly ignored it.

**Conclusion:**

> The local gitleaks hook blocked a synthetic AWS key pair. GitHub push protection (enabled) accepted the same pair when the hook was bypassed with `--no-verify`, and secret scanning raised no alert afterwards. GitHub's provider detection targets genuine credentials and cannot be tested reliably with synthetic keys. Defence in depth: gitleaks runs again in CI (`pr.yml`), so a bypassed local hook is caught before merge.

### 7.2 Remaining hook tests

| Test | Expected | Status |
|---|---|---|
| Python file with `subprocess.call(input(), shell=True)` | Semgrep blocks the commit | Pending |
| Dockerfile with `FROM python:latest` and `RUN sudo apt-get update` (Docker running) | hadolint blocks the commit | Pending |
| File starting with a PEM private-key header (the "BEGIN … PRIVATE KEY" line, written out in full in the test file) | detect-private-key blocks the commit | Pending |

## 8. Cleanup after the secret tests

The test commits were removed from the feature branch before opening the pull request, so no test secrets reach `main`:

```powershell
git log --oneline -10                       # find the commit before the first test
git reset --hard <last-good-commit>
git push --force-with-lease origin New-supply-chain-with-SBOM
```

Any secret scanning alert raised by tests is closed with the reason **"Used in tests"**.

**If a real secret were ever pushed, the order is:**
1. Revoke or rotate the credential first (removing it from Git does not undo exposure).
2. Check whether it was used (e.g. AWS CloudTrail).
3. Then clean history: `git-filter-repo --sensitive-data-removal --invert-paths --path <file>` (version 2.47 or later), force-push all refs, and contact GitHub Support for cached views and pull request references. Forks keep their copies.

## 9. Lessons learned

- **Hooks are convenience, server-side checks are controls.** `--no-verify` skips every local hook.
- **No single control catches everything.** gitleaks caught what GitHub push protection did not; the same check runs again in CI.
- **Test data must be realistic** to test a detector; structurally impossible secrets prove nothing.
- **Pin tools by SHA**, not by tag.
- **Documentation can trigger the checks too.** An earlier version of this file quoted a full private-key header as test input, and `detect-private-key` blocked the commit. The hook matches the header text alone, wherever it appears; the fix was to describe the header rather than paste it, not to exclude `docs/` from scanning.
- **Windows is not the target platform:** Linux CI, Linux containers and a Linux cluster favour working from WSL2.

## 10. Next step

Layer 2, pull request checks: `codeql.yml` (blocking SAST via a code scanning ruleset) and `pr.yml` (gitleaks, dependency review, Semgrep and Snyk reports, hadolint, unit tests, Trivy image gate).
