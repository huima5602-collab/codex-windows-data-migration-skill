---
name: migrate-windows-data
description: Safely migrate Windows project folders, Git repositories, Codex output directories, or other working directories to another drive while preserving their original paths with NTFS junctions. Use when moving data across Windows volumes, freeing system-drive space, retaining legacy absolute paths, handling hidden files and Git metadata, recovering from locked-directory failures, or escalating a migration to a one-time SYSTEM startup task.
---

# Migrate Windows Data

Use a copy-verify-switch workflow. Never delete a source directory until the copied data and replacement junction have both been verified.

## Workflow

1. Classify the data before moving it.
   - Project source and generated artifacts can usually move.
   - Chat/session records, application databases, credentials, plugin caches, and runtime installations require separate product-specific review.
   - Do not move secrets or authentication files merely to save disk space.
2. Create a JSON migration map. Use absolute local paths and explicit allowed roots.
3. Run `scripts/Test-MigrationPlan.ps1` and review every warning.
4. Record Git status and commit IDs for repositories with uncommitted work.
5. Run `scripts/Invoke-DirectoryMigration.ps1 -WhatIf`.
6. Close applications that use the source directories.
7. Run the migration without `-WhatIf`.
8. Verify junction targets, file counts, total bytes, Git status, and application behavior.
9. Use `scripts/Register-StartupMigration.ps1` only after ordinary migration repeatedly fails because a directory remains locked.

## Configuration

Create a UTF-8 JSON file:

```json
{
  "allowedSourceRoots": ["C:\\Users\\Example\\Documents"],
  "allowedDestinationRoots": ["E:\\Data"],
  "logPath": "E:\\Data\\migration.log",
  "migrations": [
    {
      "source": "C:\\Users\\Example\\Documents\\Project",
      "destination": "E:\\Data\\Projects\\Project"
    }
  ]
}
```

Each source and destination must be below its corresponding allowed root. Do not use a drive root, user-profile root, Windows directory, Program Files directory, or filesystem root as a migration endpoint.

## Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-MigrationPlan.ps1 `
  -ConfigPath .\migration.json

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-DirectoryMigration.ps1 `
  -ConfigPath .\migration.json -WhatIf

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-DirectoryMigration.ps1 `
  -ConfigPath .\migration.json
```

If a previous copy reached the destination but switching the source failed, inspect both trees and use `-Resume`. Resume mode mirrors the source into the declared destination, so use it only for a destination dedicated to that source.

## Locked Directories

Escalate in this order:

1. Stop the specific development server or process that references the source path.
2. Close editors, terminals, file explorers, and the owning application.
3. Retry after confirming no process has the source as its working directory.
4. Register a one-time startup migration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Register-StartupMigration.ps1 `
  -ConfigPath .\migration.json
```

The registration script requests UAC elevation, copies sanitized task materials into `ProgramData`, and registers a SYSTEM task for the next boot. Reboot only after the task reports that registration succeeded. The migration task deletes itself after a successful run.

## Safety Rules

- Include hidden files and `.git` when measuring and validating.
- Treat `robocopy` exit codes `0` through `7` as success and codes above `7` as failure.
- Reject non-empty destinations unless `-Resume` is explicitly supplied.
- Require enough free destination space before copying.
- Rename the source to a temporary sibling before creating the junction.
- Compare file count and total logical bytes before and after switching.
- Restore the original source path if junction creation or post-switch validation fails.
- Never use broad deletion commands, drive roots, wildcard endpoints, or dynamically constructed unverified paths.
- Do not terminate unrelated processes. Prefer startup migration over indiscriminate process killing.
- Keep logs free of file contents, credentials, tokens, cookies, and environment-variable values.

## Acceptance Checks

- Every original path is an accessible `Junction` targeting the declared destination.
- No `.migration-old-*` directory remains.
- Destination file count and total logical bytes match the verified source snapshot.
- Git HEAD, working-tree modifications, and untracked files remain unchanged.
- Applications can still open the legacy path.
- Any one-time scheduled task is absent after success.

