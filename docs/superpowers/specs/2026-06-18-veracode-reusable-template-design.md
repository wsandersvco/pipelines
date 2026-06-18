# Veracode Reusable Template Design
**Date:** 2026-06-18  
**Author:** William Sanders

---

## Executive Summary

Create a centralized, parameterized Azure DevOps template (`templates/veracode-scan.yml`) that consuming projects reference via repository resources. The template orchestrates all Veracode scanning (SCA, Pipeline Scan, Sandbox Scan, Policy Scan) with branch-aware automation, optional packaging, and scoped rollout control for safe adoption across the organization.

---

## Problem Statement

Current state:
- Veracode scanning pipeline logic exists in `azure-devops/azure-pipelines/default/` and `workflowextension/`
- Each project that wants integrated Veracode scanning must copy the entire pipeline YAML
- No single source of truth for scanning strategy
- Difficult to update scanning logic across all projects
- No mechanism for staged rollout to pilot projects first

Desired state:
- One reusable template that all projects reference
- Consuming projects provide minimal configuration (app name, credentials location, etc.)
- Safe, scoped rollout starting with pilot projects, expandable org-wide
- Flexible artifact handling (use autopackager or pre-built artifacts)
- Zero duplication, easy maintenance

---

## Architecture

### File Structure

```
pipelines/
├── templates/
│   └── veracode-scan.yml              # Main reusable template
├── azure-devops/
│   └── azure-pipelines/
│       ├── default/                   # (reference implementation, kept for docs)
│       ├── workflowextension/         # (reference implementation, kept for docs)
│       └── README.md
├── docs/
│   ├── superpowers/specs/
│   │   └── 2026-06-18-veracode-reusable-template-design.md
│   └── TEMPLATE-USAGE.md              # How to consume the template
└── (existing files unchanged)
```

---

## Template Parameters

Consuming projects pass these optional parameters to the template:

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `appName` | string | `${org}/${project}/${repo}` | Override auto-detected Veracode app name. If omitted, template constructs from org/project/repo. |
| `sandboxName` | string | `azure-release` | Sandbox identifier for release branch scans. |
| `credentialGroup` | string | `veracode-credentials` | Variable group name containing `VERACODE_API_ID`, `VERACODE_API_KEY`, `SRCCLR_API_TOKEN`. |
| `pipelinePolicy` | string | `Veracode Recommended Very High` | Policy name for PR pipeline gate enforcement. |
| `allowedProjects` | string array | (empty = all) | **Rollout control:** If provided, only these projects execute the template. If omitted, runs for all projects in org. |
| `artifactPath` | string | (empty) | **New:** Path to pre-built artifacts (e.g., `$(Build.ArtifactStagingDirectory)`). If provided, skip Package stage. If omitted, run autopackager. |

---

## Stage Flow

### Branch-Triggered Execution

All stages depend on **Package** (or artifact validation if `artifactPath` provided). Downstream scanning stages are conditional on branch context:

```
┌─────────────────────────────────────────────────────────────┐
│ Stage 1: Package OR ValidateArtifacts                       │
│ - If artifactPath empty: Run Veracode CLI autopackager     │
│ - If artifactPath provided: Validate artifacts exist        │
│ - Output: artifact_list.txt, verascan/ or provided path    │
└─────────────────────────────────────────────────────────────┘
                           ↓
        ┌──────────────────┼──────────────────┐
        ↓                  ↓                  ↓
   [Feature]           [Pull Request]      [Release/Main]
   feature/*           PR to main          release/*, main
        ↓                  ↓                  ↓
┌────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│ SCA Scan       │  │ SCA Scan         │  │ SCA Scan        │
│ (dependsOn: ✓) │  │ (dependsOn: ✓)   │  │ (dependsOn: ✓)  │
│ (parallel)     │  │ (parallel)       │  │ (parallel)      │
└────────────────┘  └──────────────────┘  └─────────────────┘
        ↓                  ↓                  ↓
   [Pipeline Scan]   ┌──────────────────┐  ┌─────────────────┐
   (no gate)         │ Pipeline Scan    │  │ Sandbox Scan    │
                     │ (BLOCKING gate)  │  │ (async, async)  │
                     └──────────────────┘  └─────────────────┘
                            ↓                  ↓
                     ┌──────────────────┐  ┌─────────────────┐
                     │ Sandbox Scan     │  │ Policy Scan     │
                     │ (async, no-block)│  │ (official cert) │
                     └──────────────────┘  └─────────────────┘
```

### Stage Definitions

**Stage 1: Package / ValidateArtifacts** (always runs, conditional logic)
- If `artifactPath` is empty:
  - Install Veracode CLI
  - Validate credentials
  - Set app name (auto-detect or parameter)
  - Run autopackager → `verascan/`
  - Generate `artifact_list.txt`
- If `artifactPath` provided:
  - Validate directory exists
  - Scan for `.jar`, `.war`, `.zip` files
  - Generate `artifact_list.txt`
  - Ensure artifacts are scannable

**Stage 2: SCA** (always runs, parallel)
- Run Veracode Agent-Based SCA
- Detects CVEs in third-party dependencies
- Publishes results

**Stage 3a: Pipeline Scan (feature branches)** (feature/* only, no PR)
- Condition: `ne(Build.Reason, 'PullRequest') AND startsWith(Build.SourceBranch, 'refs/heads/feature/') AND ne(Build.SourceBranch, 'refs/heads/main')`
- Run Pipeline Scan on each artifact without policy gate
- Purpose: Fast developer feedback during active development
- Exit code: 0 (informational only)

**Stage 3b: Pipeline Scan (pull requests)** (PR to main only)
- Condition: `eq(Build.Reason, 'PullRequest')`
- Run Pipeline Scan with policy gate (`--policy_name` from parameter)
- Gate on Very High/High severity flaws
- **BLOCKING:** Failure exits with code 1, prevents PR completion
- Then trigger Sandbox Scan (Stage 4b) as async, non-blocking follow-up

**Stage 4a: Sandbox Scan (release branches)** (release/* only)
- Condition: `startsWith(Build.SourceBranch, 'refs/heads/release/')`
- Full SAST in isolated sandbox environment
- Async, non-blocking (does not gate pipeline progress)
- Publishes results to Veracode Platform

**Stage 4b: Sandbox Scan (pull requests, async)** (triggered by PR stage)
- Condition: `eq(Build.Reason, 'PullRequest')`
- Triggered after Pipeline Scan completes (even if gate fails)
- Full SAST in sandbox, non-blocking
- Allows teams to observe comprehensive scans without delaying PR merge

**Stage 5: Policy Scan (main branch only)** (main only, post-merge)
- Condition: `eq(Build.SourceBranch, 'refs/heads/main') AND ne(Build.Reason, 'PullRequest')`
- Full SAST against corporate policies
- Official production certification
- Published to Veracode Platform with full history

---

## Consumption Patterns

### Basic Usage (Autopackager)
Consuming project's `azure-pipelines.yml`:
```yaml
trigger:
  branches:
    include:
      - main
      - feature/*
      - release/*

pr:
  branches:
    include:
      - main

resources:
  repositories:
    - repository: veracode-templates
      type: git
      name: YourOrg/pipelines
      ref: main

stages:
  - stage: Build
    jobs:
      - job: CompileApp
        steps:
          - script: echo "Building..."

  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyAwesomeApp'
      sandboxName: 'release-validation'
```

### Pre-Built Artifacts
```yaml
stages:
  - stage: Build
    jobs:
      - job: Compile
        steps:
          - script: mvn clean package -DskipTests
          - task: PublishPipelineArtifact@1
            inputs:
              targetPath: '$(Build.ArtifactStagingDirectory)'
              artifactName: 'compiled-app'

  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyAwesomeApp'
      artifactPath: '$(Build.ArtifactStagingDirectory)'
```

### Scoped Rollout (Pilot Phase)
```yaml
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyAwesomeApp'
      allowedProjects:
        - 'ProjectA'
        - 'ProjectB'
        # Once proven, omit this parameter to go org-wide
```

### Custom Credentials & Policy
```yaml
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyAwesomeApp'
      credentialGroup: 'my-team-veracode-secrets'
      pipelinePolicy: 'My Custom Policy'
```

---

## Rollout Control

### Staged Rollout Strategy

**Phase 1: Pilot (with `allowedProjects`)**
- Selected projects use the template with `allowedProjects` parameter
- Template validates `System.TeamProject` against the list
- If not in list, template skips all stages with an info message (no failure)
- Allows safe testing with early adopters

**Phase 2: Expand (remove `allowedProjects`)**
- As confidence increases, projects remove the `allowedProjects` parameter
- Template runs org-wide for any project that references it
- No need to update template itself, just consuming projects remove the parameter

**Phase 3: Org-Wide (mandatory)**
- Consider making the template required in organization policies
- All projects inherit Veracode scanning automatically

---

## Artifact Handling

### Mode A: Autopackager (Default)
- `artifactPath` parameter omitted
- Template runs Veracode CLI autopackager on source code
- Detects language/framework automatically, compiles and packages
- Output in `verascan/` directory

### Mode B: Pre-Built Artifacts
- `artifactPath` parameter provided (e.g., `$(Build.ArtifactStagingDirectory)`)
- Template skips Package stage
- Validates directory contains `.jar`, `.war`, or `.zip` files
- Uses provided artifacts directly for scanning
- Allows flexibility: consuming project handles build/packaging, template handles scanning

### Validation
Both modes validate:
- Directory exists and is readable
- At least one scannable artifact (`.jar`, `.war`, `.zip`) is present
- Fail early if validation errors occur

---

## Credentials & Secrets

### Variable Group Convention
Template expects one of:
1. Default: `veracode-credentials` (organization-scoped)
2. Custom: Parameter `credentialGroup: 'my-team-veracode-secrets'`

Variable group must contain:
- `VERACODE_API_ID` (Secret)
- `VERACODE_API_KEY` (Secret)
- `SRCCLR_API_TOKEN` (Secret, optional for SCA)

### Best Practice
- Link variable groups to Azure Key Vault for credential rotation
- Use organization-scoped groups for shared secrets
- Allow project-scoped overrides via `credentialGroup` parameter

---

## Results & Reports

### Pipeline Scan
- `results.json` (all findings)
- `filtered_results.json` (per-policy findings)
- Exit code: 0 (pass) or 1 (fail on gate)
- Published as Azure Artifact

### SCA
- Vulnerable dependencies list
- CVE scores and advisories
- License analysis
- Inline code comments in IDE

### Sandbox / Policy Scan
- Reports in Veracode Platform
- Downloadable PDF
- Dashboard with trends
- Historical comparison

---

## Implementation Notes

### File Locations
- Template: `templates/veracode-scan.yml` (new)
- Documentation: `docs/TEMPLATE-USAGE.md` (new)
- Reference: Keep existing `azure-devops/azure-pipelines/default/` and `workflowextension/` for documentation

### Stage Conditions
All scanning stages (3a, 3b, 4a, 4b, 5) use `condition:` property with explicit branch/PR logic. Each stage checks:
- `succeeded()` (prior stages passed)
- `Build.SourceBranch` (branch pattern matching)
- `Build.Reason` (PullRequest vs. IndividualCI)
- Optional: `System.TeamProject` (for allowedProjects rollout control)

### Variables & Outputs
- `APP_NAME`: Set in Package/ValidateArtifacts stage, used by Sandbox/Policy scans
- `ARTIFACT_COUNT`: Output from artifact listing step
- `artifact_list.txt`: Passed between stages via artifacts

### Error Handling
- Package/ValidateArtifacts fails if no artifacts found
- Pipeline Scan gate failure exits with code 1 (blocks PR)
- Sandbox/Policy scans are non-blocking (fail on severity but continue pipeline)
- SCA continues even if errors (|| echo "SCA completed")

---

## Benefits

✅ **Single source of truth** — All Veracode logic in one template  
✅ **Zero duplication** — No copy-paste pipelines across projects  
✅ **Safe rollout** — `allowedProjects` gates adoption to pilots  
✅ **Flexible credentials** — Each team can override variable group location  
✅ **Flexible packaging** — Use autopackager or bring pre-built artifacts  
✅ **Easy updates** — Fix bugs or improve scanning in one place, all projects benefit  
✅ **Branch-aware** — Scanning strategy automatically adapts to branch context  
✅ **Parallel execution** — SCA runs async alongside SAST for speed  
✅ **Non-blocking scans** — Sandbox scans on PRs don't delay merge

---

## Success Criteria

✅ Template is reusable and accepted by consuming projects  
✅ Pilot projects successfully adopt without code duplication  
✅ Pipeline Scan gates block vulnerable PRs (blocking behavior verified)  
✅ Sandbox scans trigger on PRs and run async (non-blocking behavior verified)  
✅ Policy scans run post-merge on main (verified)  
✅ Autopackager and pre-built artifact modes both work  
✅ Allowedprojects rollout control works as designed  
✅ Documentation is clear for consuming projects to adopt

---

## Future Considerations

- **Webhook notifications** — Slack/Teams alerts on scan completion
- **SARIF export** — Publish pipeline results as SARIF for GitHub Advanced Security
- **Custom policies** — Parameter for branch-specific policy names
- **Scan result aggregation** — Combine multi-artifact results into single report
