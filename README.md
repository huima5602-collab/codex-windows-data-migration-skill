# Windows Data Migration Skill

[中文](#中文) | [English](#english)

## 中文

一个用于安全迁移 Windows 目录的 Codex Skill。它可以将项目、Git
仓库、Codex 成果目录和其他工作目录迁移到另一块磁盘，同时在原路径创建
NTFS 目录联接（Junction），使依赖旧绝对路径的应用仍可正常工作。

### 核心特性

- 迁移前检查源目录、目标空间、隐藏文件、重解析点和路径冲突。
- 使用 `robocopy` 保留文件属性，并包含隐藏文件和 `.git` 历史。
- 对比文件数量、总字节数和重解析点，校验通过后才切换路径。
- 先临时重命名源目录，再创建 Junction；失败时自动恢复原路径。
- 支持 `-WhatIf` 演练和 `-Resume` 安全续传。
- 针对持续占用的目录，可注册一次性 SYSTEM 开机迁移任务。
- 日志不记录文件内容、Token、Cookie 或其他凭据。

### 安装

将仓库克隆到 Codex Skill 目录：

```powershell
git clone https://github.com/huima5602-collab/codex-windows-data-migration-skill.git `
  "$env:USERPROFILE\.codex\skills\migrate-windows-data"
```

也可以将仓库保存在其他磁盘，然后在 Skill 目录创建 Junction：

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.codex\skills\migrate-windows-data" `
  -Target "E:\Path\To\codex-windows-data-migration-skill"
```

重启 Codex 后，可在对话中显式调用：

```text
$migrate-windows-data 请帮我将项目目录安全迁移到另一块磁盘。
```

### 配置

创建 UTF-8 编码的 `migration.json`：

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

源目录和目标目录必须位于对应的白名单根目录下。禁止将磁盘根目录、
用户目录根、Windows 或 Program Files 作为迁移端点。

### 使用流程

```powershell
# 1. 只检查迁移计划，不修改文件
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Test-MigrationPlan.ps1 `
  -ConfigPath .\migration.json

# 2. 演练完整迁移流程
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Invoke-DirectoryMigration.ps1 `
  -ConfigPath .\migration.json -WhatIf

# 3. 关闭占用源目录的应用后执行迁移
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Invoke-DirectoryMigration.ps1 `
  -ConfigPath .\migration.json
```

只有普通迁移反复因文件占用失败时，才使用开机迁移：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Register-StartupMigration.ps1 `
  -ConfigPath .\migration.json
```

### 安全原则

不要绕过预检或在校验前删除源目录。迁移后应确认：

- 原路径类型为 `Junction`，且指向正确目标。
- 文件数量和总字节数一致。
- Git HEAD、未提交修改和未跟踪文件保持不变。
- 不存在残留的 `.migration-old-*` 目录。
- 使用旧路径的应用仍能正常打开项目。

## English

A Codex Skill for safely migrating Windows directories to another drive. It
moves projects, Git repositories, Codex output folders, and other working
directories while creating an NTFS junction at the original path, preserving
compatibility with applications that depend on legacy absolute paths.

### Key Features

- Preflight checks for source directories, free space, hidden files, reparse
  points, Git state, and path conflicts.
- `robocopy`-based copying that preserves attributes, hidden files, and `.git`.
- Verification of file counts, total bytes, and reparse points before cutover.
- Automatic rollback if junction creation or post-cutover validation fails.
- `-WhatIf` dry runs and guarded `-Resume` support.
- Optional one-time SYSTEM startup migration for persistently locked folders.
- Sanitized audit logs that exclude file contents and credentials.

### Installation

Clone the repository into the Codex Skill directory:

```powershell
git clone https://github.com/huima5602-collab/codex-windows-data-migration-skill.git `
  "$env:USERPROFILE\.codex\skills\migrate-windows-data"
```

Alternatively, keep the repository on another drive and create a junction:

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.codex\skills\migrate-windows-data" `
  -Target "E:\Path\To\codex-windows-data-migration-skill"
```

Restart Codex, then invoke the Skill explicitly:

```text
$migrate-windows-data safely move my project directory to another drive.
```

### Configuration

Create a UTF-8 `migration.json` file:

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

Every endpoint must be below its corresponding allowlisted root. Drive roots,
profile roots, Windows, and Program Files directories are rejected.

### Usage

```powershell
# 1. Inspect the plan without changing files
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Test-MigrationPlan.ps1 `
  -ConfigPath .\migration.json

# 2. Dry-run the migration
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Invoke-DirectoryMigration.ps1 `
  -ConfigPath .\migration.json -WhatIf

# 3. Close applications using the source, then migrate
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Invoke-DirectoryMigration.ps1 `
  -ConfigPath .\migration.json
```

Use startup migration only when normal attempts repeatedly fail because the
source remains locked:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts\Register-StartupMigration.ps1 `
  -ConfigPath .\migration.json
```

### Safety Contract

Never skip preflight checks or delete the source before verification. After a
migration, confirm that:

- The original path is a `Junction` targeting the destination.
- File counts and total logical bytes match.
- Git HEAD, working-tree changes, and untracked files are unchanged.
- No `.migration-old-*` directory remains.
- Applications can still open the project through the original path.

## Repository Structure

| Path | Purpose |
|---|---|
| `SKILL.md` | Codex workflow, trigger conditions, and safety contract |
| `scripts/Test-MigrationPlan.ps1` | Read-only migration preflight |
| `scripts/Invoke-DirectoryMigration.ps1` | Copy, verify, cut over, and roll back |
| `scripts/Register-StartupMigration.ps1` | Register the last-resort startup task |
| `agents/openai.yaml` | Codex Skill display metadata |

## License

[MIT](LICENSE)
