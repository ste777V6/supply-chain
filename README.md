# supply-chain-lab

An end-to-end **software supply-chain security pipeline** built only with production tools on
GitHub Actions: SAST (CodeQL), PR dependency gating, SBOM generation, vulnerability gating,
keyless image signing, SLSA build provenance, SBOM attestation, and consumer-side verification.

Project 1 of a series that covers the gaps for the EPAM *Senior Security Engineer* (MCP-driven
supply-chain security) role.

| EPAM requirement | Where it's covered here |
|---|---|
| GHAS / CodeQL, tuned to reduce noise | `codeql.yml`: `security-extended` queries, Python + GitHub Actions workflows, results categorised |
| Dependency risk management | `dependency-review.yml` (blocks a PR that adds a High/Critical vuln), Dependabot |
| SBOM generation / verification | Syft SBOM (SPDX 2.3) → signed SBOM attestation → `gh attestation verify --predicate-type` |
| Provenance & integrity controls | Cosign keyless signature + SLSA v1 build provenance, both verified in a read-only job |
| Policy enforcement in pipelines | Grype gate (High+, fix available), PR gate, signer identity pinned to an exact workflow |
| Least privilege, secure CI/CD | Per-job `permissions`, SHA-pinned actions, `persist-credentials: false`, audited with `zizmor` |

## Pipeline

```
push to main
  └─ build-scan-sign
       build image (local, not pushed)
       → Syft SBOM (SPDX 2.3 JSON)
       → Grype scan of SBOM ── fails on High/Critical with a fix ──► STOP (nothing pushed)
       → SARIF → Security › Code scanning
       → push to ghcr.io (by digest)
       → cosign sign (keyless: GitHub OIDC → Fulcio cert → Rekor log)
       → actions/attest: SLSA build provenance  (pushed to registry)
       → actions/attest: SBOM attestation       (pushed to registry)
  └─ verify   (separate job, read-only permissions, acts as the consumer)
       cosign verify      --certificate-identity <this exact workflow@ref>
       gh attestation verify  (provenance, signer workflow pinned)
       gh attestation verify  --predicate-type https://spdx.dev/Document/v2.3

pull_request
  ├─ ci                 pytest
  ├─ codeql             Python + Actions, security-extended
  └─ dependency-review  fail-on-severity: high
weekly
  ├─ codeql (schedule)
  └─ scorecard          OpenSSF Scorecard → code scanning
```

## Replicate it (about 15 minutes)

**Requirements:** a **public** GitHub repository on any plan. Public is required because:
- artifact attestations are available in public repos on all current plans, but private
  repos need GitHub Enterprise Cloud ([actions/attest README][attest]);
- code scanning and dependency review are available on public repos; private repos need
  GitHub Code Security ([GHAS docs][ghas], [dependency review docs][depreview]).

1. Create a new public repo and push this folder to `main`:
   ```bash
   git init -b main && git add . && git commit -m "supply-chain lab"
   git remote add origin git@github.com:<you>/supply-chain-lab.git
   git push -u origin main
   ```
2. **Settings › Code security**: make sure *Dependency graph* and *Dependabot alerts* are on
   (dependency review depends on the dependency graph).
3. **Settings › Actions › General › Workflow permissions**: leave the default *Read repository
   contents* — every job asks for exactly what it needs.
4. The push to `main` triggers `supply-chain`. Open the run: both jobs should be green, and
   the run summary lists the attestations.
5. Check the results:
   - **Security › Code scanning**: CodeQL, Grype and Scorecard findings (each in its own category)
   - **Packages**: `ghcr.io/<you>/supply-chain-lab` with signature and attestation artifacts
   - **Actions › Attestations** (repo sidebar): provenance + SBOM attestations

## Verify from your own laptop (consumer view)

```bash
IMAGE=ghcr.io/<you>/supply-chain-lab
# The digest is printed in the "Build and push image" step of the run, and shown on the
# package page. Or read the "Digest:" line of: docker buildx imagetools inspect $IMAGE:latest
DIGEST=sha256:<digest-from-the-run>

# 1. Signature: must come from THIS workflow on main, issued via GitHub Actions OIDC
cosign verify "$IMAGE@$DIGEST" \
  --certificate-identity "https://github.com/<you>/supply-chain-lab/.github/workflows/supply-chain.yml@refs/heads/main" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# 2. SLSA provenance, signer workflow pinned
gh attestation verify "oci://$IMAGE@$DIGEST" --repo <you>/supply-chain-lab \
  --signer-workflow <you>/supply-chain-lab/.github/workflows/supply-chain.yml

# 3. SBOM attestation
gh attestation verify "oci://$IMAGE@$DIGEST" --repo <you>/supply-chain-lab \
  --predicate-type https://spdx.dev/Document/v2.3
```

## Prove the controls work (do these — they make good interview stories)

**A. PR gate blocks a vulnerable dependency.**
On a branch, add `requests==2.19.1` to `requirements.txt` and open a PR. That version is
affected by **CVE-2018-18074 / GHSA-x84v-xcm2-53pg** (CVSS 7.5 High, fixed in 2.20.0)
([OSV][osv]). Expected: `dependency-review` fails and comments on the PR. Close the PR.

**B. Build gate stops a vulnerable image before it's published.**
Push the same change straight to `main` (or merge with an admin override). Expected: the Grype step
fails, the image is **not** pushed, nothing is signed, and the finding shows up in code scanning.
Revert.

**C. Verification rejects the wrong identity.**
Run the `cosign verify` above with `--certificate-identity` pointing to a different workflow
file (e.g. `.../ci.yml@refs/heads/main`). Expected: verification fails. This is the point
of *pinning the signer identity*: a valid Sigstore signature is not enough on its own.

**D. Accepted risk is recorded, not hidden.**
If Grype blocks on a finding you've triaged as not exploitable, add it to `.grype.yaml` with a
`reason` — the file becomes the audit trail for accepted risk.

## Design decisions (what to say in an interview)

- **Scan before push.** The image is loaded locally, SBOM'd and scanned; only a passing image
  is pushed, signed and attested. A failing image never reaches the registry.
- **Sign and attest the digest, never a tag.** Tags are mutable; digests aren't.
- **Keyless signing.** No long-lived signing keys to protect or rotate: the certificate is
  bound to the workflow's OIDC identity and recorded in the Rekor transparency log.
- **Verification pins the identity** (exact workflow file + ref + issuer). Otherwise, any
  GitHub workflow anywhere could produce a "valid" signature.
- **`only-fixed: true` on the Grype gate.** Blocks on what engineers can actually fix; unfixable
  base-image CVEs are still reported in code scanning for triage. Reduces noise and alert
  fatigue across many repos.
- **CodeQL also scans the workflows** (`language: actions`), because CI is part of the attack
  surface (e.g. script injection via `${{ github.event.* }}`).
- **Least privilege:** workflow-level `contents: read`, per-job grants, `id-token: write` only
  where signing happens, read-only `verify` job, `persist-credentials: false` on checkout.
- **Actions pinned to commit SHAs** (tag in a comment). Dependabot keeps them current. This
  protects against a compromised or force-moved tag on a third-party action.

## What was verified while building this

| Item | How it was checked |
|---|---|
| Action versions and commit SHAs | Resolved from each action's Git tags (`git ls-remote`) on 2026-11-03 |
| Action inputs/outputs used (`sbom`, `only-fixed`, `severity-cutoff`, `subject-digest`, `push-to-registry`, `sbom-path`, `fail-on-severity`, `comment-summary-in-pr`, `load`, `build-args`, …) | Read from each action's `action.yml` at the pinned tag |
| Attestation permissions (`id-token`, `attestations`, `artifact-metadata`) and plan limits | `actions/attest` v4.2.2 README |
| SBOM predicate type `https://spdx.dev/Document/v2.3` | `actions/attest` source (`src/sbom.ts`) + Syft default SPDX version `2.3` (`syft/format/internal/spdxutil/versions.go`, v1.56.0) |
| `cosign verify` flags and the GitHub Actions OIDC issuer | `sigstore/cosign` v3.1.4 `doc/cosign_verify.md` |
| `gh attestation verify` flags | `gh attestation verify --help` |
| CodeQL `actions` language, `build-mode: none` for interpreted languages | `github/codeql-action` v4.39.2 source + README |
| Unit tests | `pytest`: 2 passed |
| Workflow + Dependabot syntax | `check-jsonschema` (GitHub workflow and Dependabot schemas): valid |
| Workflow security | `zizmor 1.32.0` (auditor persona): no warnings or errors |

**Not yet verified:** the container build, scan, signing and verification only run on GitHub's
runners (no Docker daemon in the environment where this was written). The first green run of
`supply-chain` on your repo is the proof. If a step fails, the error message in the run log
tells you which control is involved.

## Sources

- actions/attest: https://github.com/actions/attest
- Using artifact attestations: https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds
- GitHub Advanced Security availability: https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security
- Dependency review: https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/about-dependency-review
- CodeQL action: https://github.com/github/codeql-action
- Syft SBOM action: https://github.com/anchore/sbom-action · Grype scan action: https://github.com/anchore/scan-action
- Cosign (keyless verify flags): https://github.com/sigstore/cosign/blob/main/doc/cosign_verify.md
- gh attestation verify: https://cli.github.com/manual/gh_attestation_verify
- SLSA provenance v1: https://slsa.dev/spec/v1.0/provenance
- OpenSSF Scorecard action: https://github.com/ossf/scorecard-action
- zizmor (GitHub Actions static analysis): https://github.com/zizmorcore/zizmor
- OSV entry used in demo A: https://osv.dev/vulnerability/GHSA-x84v-xcm2-53pg

[attest]: https://github.com/actions/attest
[ghas]: https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security
[depreview]: https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/about-dependency-review
[osv]: https://osv.dev/vulnerability/GHSA-x84v-xcm2-53pg
