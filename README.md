# Z — 多子仓库工作区（一键同步远程最新）

本仓库只负责**关联**多个独立子仓库，不锁定子仓库的版本组合。各子仓库由不同负责人独立维护，负责人推送到自己的仓库后**无需再进入父仓库更新 Submodule 指针或提交父仓库**。使用者克隆父仓库后，运行一个脚本即可获得所有子仓库指定分支的**远程最新**版本。

## 目录结构

```text
Z/
├─ host-app/             # 独立子仓库（示例：上位机代码）
├─ firmware/             # 独立子仓库（示例：固件代码）
├─ algorithm/            # 独立子仓库（示例：算法代码）
├─ sync-latest.ps1       # 一键同步脚本
├─ README.md
└─ .gitmodules
```

每个子模块在 `.gitmodules` 中配置：

```ini
[submodule "<name>"]
    path = <path>
    url = <repository-url>
    branch = <tracked-branch>
    ignore = all
```

- `branch` 必须明确指定，不依赖远程默认 HEAD。
- `ignore = all` 用于避免父仓库因子仓库指针变化而持续显示修改，父仓库只保存初始关联关系。

## 第一次下载

```powershell
git clone https://github.com/Jeffrey1799/Z.git
cd Z
.\sync-latest.ps1
```

## 日常同步

```powershell
.\sync-latest.ps1
```

## 可选参数

```powershell
.\sync-latest.ps1 -SkipParentPull      # 不拉取父仓库，只同步子仓库
.\sync-latest.ps1 -Submodule firmware  # 只同步指定子仓库（名称或路径）
.\sync-latest.ps1 -Submodule host-app,firmware  # 同时同步多个
.\sync-latest.ps1 -DryRun              # 只显示将要执行的操作，不修改任何内容
```

## 子仓库负责人工作流

子仓库负责人可以直接克隆和维护自己的仓库，不需要操作父仓库：

```powershell
git pull --ff-only
git add .
git commit -m "Update component"
git push
```

完成后**不需要**进入父仓库做任何操作，父仓库不会因子仓库更新而出现待提交状态。

## 如何添加一个新的子仓库（父仓库维护者）

```powershell
# 在父仓库根目录执行
git submodule add <repository-url> <path>
git config -f .gitmodules submodule.<name>.branch <branch>
git config -f .gitmodules submodule.<name>.ignore all
git commit -m "chore: add submodule <name>"
git push
```

## 重要说明

- 普通 `git pull` 只更新父仓库本身，**不会**更新子仓库。
- `git submodule update --init --recursive` 默认按父仓库记录的**旧指针**更新，不是远程最新版本。
- 要获得各子仓库指定分支的远程最新版本，**必须**运行 `sync-latest.ps1`。
- 脚本更新前会检查每个子仓库：只要存在已修改/已暂存/未跟踪文件，或正在 merge/rebase/cherry-pick，就立即停止并明确指出是哪个子仓库，**不会** stash、提交或删除你的修改。
- 本地分支与远程已分叉时，脚本不自动 merge / rebase / 强制覆盖，会停止并输出人工处理命令。
- 父仓库不保证历史提交能够恢复当时精确的子仓库版本组合（子仓库指针不会随每次同步写入父仓库）。
- 如果未来需要正式发布和版本追溯，应另行处理：进入父仓库提交 Submodule 指针并打 Tag（例如 `git add .gitmodules <子仓库路径>`、`git commit`、`git tag vX.Y.Z`），再推送。
