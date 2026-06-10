# Project Instructions

## Goal

Maintain a reusable Codex Skill for safely migrating Windows directories across drives while preserving legacy paths with NTFS junctions.

## Technology

- Markdown Skill instructions
- PowerShell 5.1-compatible scripts
- JSON migration configuration
- Git and GitHub

## Structure

- `SKILL.md`: agent workflow and safety contract
- `README.md`: bilingual user guide and installation instructions
- `agents/openai.yaml`: Codex UI metadata
- `scripts/`: preflight, migration, and startup-task automation
- `scripts/Install-CodexProjectlessStorage.ps1`: projectless root compatibility repair
- `scripts/Ensure-CodexProjectlessDateJunction.ps1`: daily date junction maintenance
- `LICENSE`: MIT license

## Commands

```powershell
python "$env:CODEX_HOME\skills\.system\skill-creator\scripts\quick_validate.py" .

powershell -NoProfile -Command "$errors=$null; [System.Management.Automation.Language.Parser]::ParseFile('scripts\Invoke-DirectoryMigration.ps1',[ref]$null,[ref]$errors)"
```

## Git Rules

- Do not commit migration configs containing personal paths unless they are sanitized examples.
- Do not commit logs, credentials, tokens, cookies, or generated test data.
- Do not push without explicit user approval.

## Notes

- Keep scripts compatible with Windows PowerShell 5.1.
- Preserve rollback behavior and path-safety validation when changing migration logic.
- Treat SYSTEM startup migration as a last resort.
- Keep `Documents\Codex` as a real directory; only its date children may be junctions.
