# Veracode Scanning Template - Usage Guide

Reusable Azure DevOps template for comprehensive Veracode security scanning across your entire organization.

**Template location:** `templates/veracode-scan.yml`

---

## Quick Start

Minimal setup to get scanning running in your project:

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
  # Your build/compile stages here
  - stage: Build
    jobs:
      - job: Compile
        steps:
          - script: echo "Building application..."

  # Add Veracode scanning
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyApplication'
```

That's it! The template automatically handles:
- ✅ SCA on all branches
- ✅ Pipeline Scan (no gate) on feature branches
- ✅ Pipeline Scan (blocking gate) on PRs to main
- ✅ Sandbox Scan on release branches
- ✅ Policy Scan on main post-merge

---

## Parameter Reference

All parameters are optional. Omit them to use defaults.

### `appName` (string)
**Default:** Auto-detected from org/project/repo

Override the Veracode application profile name. If omitted, the template constructs it as:
```
organization/project/repository
```

**Example:**
```yaml
parameters:
  appName: 'MyAwesomeApp'
```

**When to use:**
- Your repo name doesn't match your Veracode app name
- You want a simpler name than the full org/project/repo path
- Multiple repos feed into one Veracode profile

---

### `sandboxName` (string)
**Default:** `azure-release`

Sandbox identifier used by release branch scans. For pull requests, the template appends `-pr-{PR number}` automatically.

**Example:**
```yaml
parameters:
  sandboxName: 'pre-release-validation'
```

**When to use:**
- Your release process uses a specific naming convention
- You want to distinguish sandbox names from the default

---

### `credentialGroup` (string)
**Default:** `veracode-credentials`

Name of the Azure DevOps variable group containing Veracode API credentials. The group must contain:
- `VERACODE_API_ID` (Secret)
- `VERACODE_API_KEY` (Secret)
- `SRCCLR_API_TOKEN` (Secret, optional for SCA)

**Example:**
```yaml
parameters:
  credentialGroup: 'my-team-veracode-secrets'
```

**When to use:**
- Your team has a separate credential group
- You want to rotate credentials independently per team
- Multiple credential sets exist in your organization

**Setup (one-time):**
1. Go to **Pipelines → Library → Variable groups**
2. Create a new group with the name you specify
3. Add the three variables (mark as Secret)
4. Add your project pipeline permission to the group

---

### `pipelinePolicy` (string)
**Default:** `Veracode Recommended Very High`

Policy name for PR pipeline scan gate. The gate blocks PR merge if violations match this policy.

**Example:**
```yaml
parameters:
  pipelinePolicy: 'My Custom Security Policy'
```

**When to use:**
- Your organization has a custom policy
- You want different gates on different projects

---

### `allowedProjects` (array)
**Default:** Empty (all projects allowed)

Scoped rollout control. If provided, the template only executes for projects in this list. Useful during pilot phase.

**Example - Pilot phase:**
```yaml
parameters:
  allowedProjects:
    - 'ProjectA'
    - 'ProjectB'
```

**Example - Rollout complete (omit parameter):**
```yaml
# No allowedProjects parameter → runs org-wide
```

**Behavior:**
- If project not in list: Template skips all stages with info message (no failure)
- If omitted: Template runs for all projects

**When to use:**
- Rolling out to pilot teams first
- Testing template behavior safely with a subset
- Once stable, simply remove this parameter from all consuming projects

---

### `artifactPath` (string)
**Default:** Empty (use autopackager)

Path to pre-built artifacts (`.jar`, `.war`, `.zip` files). If provided, the template skips the Package stage and scans your pre-built artifacts directly.

**Example - Using build output:**
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
      appName: 'MyApp'
      artifactPath: '$(Build.ArtifactStagingDirectory)'
```

**When to use:**
- You already have a build pipeline that produces artifacts
- You want to reuse existing build outputs for scanning
- Faster iteration (no re-packaging in template)

---

## Consumption Patterns

### Pattern 1: Minimal (Autopackager)
Let the template compile and package everything:

```yaml
resources:
  repositories:
    - repository: veracode-templates
      type: git
      name: YourOrg/pipelines

stages:
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyApp'
```

**Best for:**
- Simple projects with one artifact
- Projects where compilation is straightforward
- First-time setup

---

### Pattern 2: Pre-Built Artifacts
Use your existing build pipeline's output:

```yaml
stages:
  - stage: Build
    jobs:
      - job: Compile
        steps:
          - checkout: self
          - script: |
              echo "Building..."
              mkdir -p build-output
              # Your build commands here
              cp target/app.jar build-output/
          - task: PublishPipelineArtifact@1
            inputs:
              targetPath: 'build-output'
              artifactName: 'my-app-build'

  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyApp'
      artifactPath: '$(Pipeline.Workspace)/my-app-build'
```

**Best for:**
- Projects with existing build pipelines
- Multi-artifact builds
- Custom build logic already optimized

---

### Pattern 3: Custom Credentials
Use your team's separate credential group:

```yaml
resources:
  repositories:
    - repository: veracode-templates
      type: git
      name: YourOrg/pipelines

stages:
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyApp'
      credentialGroup: 'my-team-veracode-creds'
```

**Prerequisites:**
1. Create variable group `my-team-veracode-creds` in your Azure DevOps project
2. Add `VERACODE_API_ID`, `VERACODE_API_KEY`, `SRCCLR_API_TOKEN` (optional)
3. Add your pipeline permission to the group

---

### Pattern 4: Scoped Rollout (Pilot Phase)
Restrict to specific projects during evaluation:

```yaml
stages:
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyApp'
      allowedProjects:
        - 'TeamA-Project'
        - 'TeamB-Project'
      # Once stable in pilot, remove allowedProjects
      # to enable org-wide
```

**Rollout progression:**
1. **Week 1:** Pilot teams use template with `allowedProjects`
2. **Week 2:** Add more projects to list as confident
3. **Week 3:** Remove `allowedProjects` parameter → all projects use it

---

### Pattern 5: Custom Policy + Sandbox
Advanced setup with custom policy and sandbox naming:

```yaml
stages:
  - template: templates/veracode-scan.yml@veracode-templates
    parameters:
      appName: 'MyApp'
      sandboxName: 'release-v2'
      credentialGroup: 'my-org-veracode'
      pipelinePolicy: 'My Company Security Standard'
```

---

## Branch Behavior

The template automatically adapts scanning to your branch context. No configuration needed.

| Branch | Trigger | SAST Scan | Gate? | Purpose |
|--------|---------|-----------|-------|---------|
| `feature/*` | Push | Pipeline (fast) | ❌ | Dev feedback during active work |
| PR to `main` | Pull Request | Pipeline (fast) | ✅ BLOCKING | Prevent vulnerable code merge |
| `release/*` | Push | Sandbox (thorough) | ❌ | Pre-production validation |
| `main` | Push after merge | Policy (thorough) | ❌ | Production certification |
| All | All | SCA | ❌ | Dependency analysis always runs |

### What Happens on a PR?

```
1. Developer pushes to feature/my-feature
   → Pipeline Scan (no gate) runs for quick feedback

2. Developer opens PR to main
   → Branch policy triggers Azure DevOps build
   → Pipeline Scan runs with policy gate (BLOCKING)
   → If violations found: Gate fails, PR blocked
   → Async Sandbox Scan starts in background (non-blocking)
   → Developer can approve/merge only after gate passes

3. PR merged to main
   → Policy Scan runs (official certification)
   → Results stored in Veracode Platform

4. Meanwhile, Sandbox Scan completes
   → Results available in Veracode Platform
   → No impact on merge (already done)
```

---

## Results & Reports

### Pipeline Scan Results
- **Format:** `results.json` (JSON per artifact)
- **Published as:** Azure Pipeline Artifact (`veracode-pipeline-results` or `veracode-pipeline-gate-results`)
- **Exit code:** 0 (pass) on feature branches; 0 or 1 on PRs (gate determines)
- **Download:** From pipeline run → Artifacts tab

### SCA Results
- **Format:** Vulnerability report with CVE scores
- **Published to:** Veracode Platform → Scans → SCA
- **Refresh:** Real-time in IDE plugins
- **Details:** Exact dependencies, update recommendations, license analysis

### Sandbox Scan Results
- **Published to:** Veracode Platform → Scans → Sandboxes
- **Available:** Within minutes of scan completion
- **Dashboard:** Trends, comparison with previous scans
- **PDF Report:** Downloadable for compliance

### Policy Scan Results
- **Published to:** Veracode Platform → Scans → Policy
- **Certification:** Official production approval
- **History:** All scans retained for audit trail
- **Compliance:** Exportable for SOC2, PCI-DSS, etc.

---

## Troubleshooting

### Q: Pipeline fails - "Veracode credentials not found"
**A:** Variable group not linked or secrets missing.
- Check variable group name matches `credentialGroup` parameter
- Verify group contains `VERACODE_API_ID` and `VERACODE_API_KEY`
- Ensure your pipeline has permission to access the group (Library → Security)

---

### Q: No artifacts found - "Autopackager failed"
**A:** Source code structure not recognized.
- Verify source code is checked out (default behavior)
- Try `artifactPath` parameter with pre-built artifacts instead
- Check Veracode CLI logs in pipeline output

---

### Q: PR gate passes locally but fails in pipeline
**A:** Policy name mismatch or different code version.
- Verify `pipelinePolicy` parameter matches your Veracode policy
- Ensure latest source code is in PR (no stale commits)
- Check if violations are actually present in Veracode Platform

---

### Q: Sandbox scan runs but doesn't block PR
**A:** By design - sandbox scans are non-blocking on PRs.
- Pipeline Scan gate (Stage 3b) blocks PRs if policy violations found
- Sandbox Scan (Stage 4b) runs async to provide deep analysis without blocking
- Merge only blocked if Pipeline Scan gate fails

---

### Q: Template skipped - "project not in allowed scope"
**A:** Expected when using `allowedProjects` during rollout.
- Template execution is scoped to listed projects
- Remove `allowedProjects` parameter to enable for all projects
- No pipeline failure; just skipped silently

---

### Q: Can I scan multiple artifacts in one go?
**A:** Yes - autopackager finds and scans all artifacts, or provide them via `artifactPath`.
- Each artifact scanned individually by Pipeline Scan (for detailed feedback)
- All artifacts bundled together for Sandbox/Policy scans
- Results published separately for each artifact

---

## Advanced Configuration

### Using with Pre-Existing Veracode App Profiles
If your app profile already exists in Veracode Platform:
- Omit `appName` or set it to exact profile name
- Template won't recreate it (`createProfile: true` idempotent)

### Scoping Credentials to Projects
Link variable group to specific project only:
1. **Pipelines → Library → Variable groups**
2. Select group → **Manage** → Set **Project permissions**
3. Choose which projects can access it

### Combining with Other Security Tools
Template works alongside:
- SonarQube (scan SonarQube results independently)
- Dependabot (SCA complements, doesn't replace)
- OWASP / Fortify (different scan engines)
- GitHub Advanced Security (SARIF export available)

---

## Next Steps

1. **Fork/clone this repo** to your Azure DevOps organization
2. **Create credentials variable group** with API keys
3. **Add template reference** to your project's `azure-pipelines.yml`
4. **Run a test build** on feature branch (should trigger Pipeline Scan)
5. **Create PR** to main (should trigger gated Pipeline Scan + async Sandbox)
6. **Monitor results** in Veracode Platform dashboard

---

## Support & Questions

- **Veracode Docs:** [docs.veracode.com](https://docs.veracode.com)
- **Pipeline Scan Reference:** [Pipeline Scan](https://docs.veracode.com/r/Pipeline_Scan)
- **SCA Reference:** [Agent-Based SCA](https://docs.veracode.com/r/Agent_Based_Scans)
- **Azure Pipelines:** [Microsoft Docs](https://docs.microsoft.com/azure/devops/pipelines)

---

## Template Architecture

For detailed design information, see:
- **Design Spec:** `docs/superpowers/specs/2026-06-18-veracode-reusable-template-design.md`
- **Reference Implementations:** `azure-devops/azure-pipelines/default/` and `workflowextension/`
