Ops Automation Repository

This repository is a mixed operations toolkit: PowerShell, shell, and Playwright automation for Datto RMM, Duo, Microsoft Entra ID, IT Glue, Datto EDR, and a few vendor-specific workflows.

## Layout
- Root `*.ps1` / `*.sh` / `*.js`: directly runnable operational entrypoints kept stable for Datto/manual invocation.
- [`docs/`](docs/): runbooks and testing notes.
- [`examples/`](examples/): example JSON inputs and starter config files.
- [`samples/`](samples/): committed reference outputs and historical captures.
- `artifacts/`: local run output and generated reports. This is gitignored.
- `certs/`: local certificate exports. This is gitignored.

## Notable Directories

- [`reports/`](reports/): daily API audit and CSV export scripts for Datto RMM, BCDR, EDR, and Duo — run all at once with `reports/morning-report.ps1`.
- [`duo-headless/`](duo-headless/): Playwright helpers for Duo admin scraping.
- [`datto-edr-headless/`](datto-edr-headless/): Playwright capture tooling for Datto EDR.
- [`it-glue-headless/`](it-glue-headless/): headless Network Glue automation.
- [`powertechnology-immybot/`](powertechnology-immybot/): ImmyBot packaging/install runbooks.
- [`PowerShell/`](PowerShell/): profile migration scripts.
- [`dfremote-azure/`](dfremote-azure/): DF remote tooling and support assets.
- [`HardMatch/`](HardMatch/) and [`ADto365-HardMatch/`](ADto365-HardMatch/): hard-match helpers and notes.

## Repo Conventions
- New generated output should go under `artifacts/<area>/...`, not the repo root.
- Reusable examples belong in `examples/`.
- Long-form notes and runbooks belong in `docs/`.
- Committed historical captures belong in `samples/` only when they add real reference value.

## Common Local Setup
- Install Node dependencies once for Playwright-based tooling: `npm install`
- Install Playwright browser once: `npm run setup`
- Keep secrets in local env/config files, not in committed docs or examples.

## Useful Docs
- [`docs/repository-layout.md`](docs/repository-layout.md)
- [`docs/testing-quick-reference.md`](docs/testing-quick-reference.md)
- [`docs/global-admin-audit-azure-automation-guide.md`](docs/global-admin-audit-azure-automation-guide.md)

## Notes
- Existing script filenames in the repo root were left in place on purpose to avoid breaking Datto components, bookmarks, and manual run habits.
- Several scripts now default to `artifacts/` for reports, while historical sample outputs were moved to `samples/`.
