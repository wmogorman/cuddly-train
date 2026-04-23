# Repository Layout

The repository is organized around one rule: keep runnable entrypoints stable, move everything else out of the root.

## Root

- Root PowerShell and shell scripts remain at the top level so existing Datto RMM components, manual commands, and saved references do not break.
- Multi-file projects stay in their own directories when they already have supporting assets or separate tooling.

## Working Areas

- `docs/`: runbooks, test notes, and operator-facing guidance.
- `examples/`: example JSON/config inputs that are safe to copy and adapt.
- `samples/`: committed historical output, reference CSVs, and example result sets.
- `artifacts/`: local generated output from day-to-day runs. This directory is ignored by git.
- `certs/`: local certificate exports used during operator workflows. This directory is ignored by git.

## Project Directories

- `reports/`: daily API audit and CSV export scripts for Datto RMM, Datto BCDR, Datto EDR, and Duo. Credentials (`.env` files) and `.env.example` templates live here alongside the scripts. Run `morning-report.ps1` to execute all of them in sequence.
- `duo-headless/`: Playwright support for Duo admin UI scraping.
- `datto-edr-headless/`: browser automation helpers for Datto EDR state capture.
- `it-glue-headless/`: Playwright automation for IT Glue / Network Glue tasks.
- `powertechnology-immybot/`: ImmyBot packaging and wrapper scripts.
- `PowerShell/`: profile migration utilities.
- `dfremote-azure/`: DF automation assets.
- `HardMatch/` and `ADto365-HardMatch/`: hard-match utilities with their own notes.

## Output Conventions

- Datto RMM report output: `artifacts/datto-rmm/`
- Datto BCDR audit output: `artifacts/datto-bcdr/`
- Datto EDR audit output: `artifacts/datto-edr/`
- Duo audit and scrape output: `artifacts/duo/`
- Entra audit output: `artifacts/entra/`
- Enterprise app onboarding waves: `artifacts/enterprise-app-onboard/`

## Committed Reference Material

- Historical or illustrative output that is worth keeping in version control belongs under `samples/`.
- Sample configs belong under `examples/`.
- If an output is purely transient, keep it in `artifacts/` only.
