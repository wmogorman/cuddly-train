IT Glue Automation Scripts for Datto RMM

**Repo Purpose**
- Toolkit of PowerShell runbooks that call the IT Glue REST API
- Tailored for MSPs deploying automation through Datto RMM or manual, no-profile PowerShell sessions
- Focused on flexible asset hygiene, password grooming, and bulk clean-up tasks

**Included Scripts**
- `delete-ad-computer.ps1` removes stale ?AD Computer? flexible assets in safe batches with optional run-until-empty support
- `flexible-asset-types.ps1` inventories every flexible asset type and reports asset counts, optionally scoped to specific org IDs
- `remove-description-passwords.ps1` scans IT Glue passwords for descriptions that look like they contain plaintext credentials
- `local-to-public.ps1` and `staff-to-public.ps1` are companion Windows profile migration helpers often paired with IT Glue cleanup jobs

**Prerequisites**
- IT Glue API key with access to the intended organizations
- IT Glue subdomain (used for the `x-account-subdomain` header)
- Datto RMM component with PowerShell (64-bit, no profile) execution rights
- Windows PowerShell 5.1+ on the target device; scripts are written for Windows endpoints

**Configuration**
- Store the IT Glue API key in the Datto RMM policy or site variable `ITGlueKey`; scripts default to `$env:ITGlueKey`
- Pass required parameters such as `-Subdomain` (and optional `-OrgId`, `-RunUntilEmpty`, etc.) through the component arguments
- Adjust throttling settings in delete-focused scripts if you have higher/lower rate-limit requirements

**Running Locally**
- Open an elevated PowerShell session in the repository root
- Use `.\<script>.ps1 -Subdomain 'example' -ApiKey 'xxxxxxxx'` while testing; real executions should rely on environment variables rather than hard-coding secrets
- Supply `-Verbose` during dry runs to review pagination, throttling, and decision logic before enabling destructive actions

**Deploying with Datto RMM**
- Upload the desired script as a component file or reference it from a package share
- Configure the component command: `-Command "& { . .\<script>.ps1 -Subdomain 'example' <additional switches> }"`
- Set `WhatIf:$false` or equivalent flags only after validating results in a staging site
- Review component output for objects emitted (counts/status) and capture logs using Datto RMM device variables if long-term tracking is needed

**Operational Tips**
- Schedule asset clean-up scripts during off-hours to avoid bumping into IT Glue write limits
- Combine reporting scripts (like `flexible-asset-types.ps1`) with follow-up automation to maintain data health
- Version control updates here before promoting to Datto so rollback is simple if API behavior changes

**Support & Troubleshooting**
- 401 responses usually signal a missing/invalid API key or subdomain; confirm the Datto variable value and script parameters
- 429 throttling errors mean IT Glue rate limits were hit; raise `RateLimitWindowSeconds` or lower per-run deletion counts
- Unexpected JSON structures: capture the raw response with `-Verbose` and adjust parsing logic as IT Glue introduces new fields
