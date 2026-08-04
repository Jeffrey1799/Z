# Z — 多子仓库工作区（一键同步远程最新）

本仓库只负责**关联**多个独立子仓库，不锁定子仓库的版本组合。各子仓库由不同负责人独立维护，负责人推送到自己的仓库后**无需再进入父仓库更新 Submodule 指针或提交父仓库**。使用者克隆父仓库后，运行一个脚本即可获得所有子仓库指定分支的**远程最新**版本。

## 目录结构

```text
Z/
├─ host-app/             # 独立子仓库（示例：上位机代码）
├─ firmware/             # 独立子仓库（示例：固件代码）
├─ algorithm/            # 独立子仓库（示例：算法代码）
├─ zgit.ps1       # 一键同步脚本
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
.\zgit.ps1
```

## 日常同步

```powershell
.\zgit.ps1
```

## 可选参数

```powershell
.\zgit.ps1 -SkipParentPull      # 不拉取父仓库，只同步子仓库
.\zgit.ps1 -Submodule firmware  # 只同步指定子仓库（名称或路径）
.\zgit.ps1 -Submodule host-app,firmware  # 同时同步多个
.\zgit.ps1 -DryRun              # 只显示将要执行的操作，不修改任何内容
.\zgit.ps1 -Add -AddPath C:\work\host-app   # 把本地子仓库注册进父仓库（见下）
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

## 如何添加一个新的子仓库

### 方式一：脚本自动添加（推荐）

把子仓库接入父仓库，不需要手动敲 `submodule add` 和配置命令，脚本会自动识别子仓库的远程 URL 与当前分支：

```powershell
# 在父仓库根目录执行，指定子仓库本地路径
.\zgit.ps1 -Add -AddPath C:\work\host-app
```

脚本会自动完成：读取子仓库 `origin` 的 URL 与当前分支 → `git submodule add` → 配置 `branch` / `ignore = all` → 提交 `chore: add submodule <name>` → 推送父仓库。

常用附加参数：

```powershell
.\zgit.ps1 -Add -AddPath C:\work\host-app -AddName host-app    # 指定子模块名称
.\zgit.ps1 -Add -AddPath C:\work\host-app -AddBranch dev       # 指定跟踪分支
.\zgit.ps1 -Add -AddPath C:\work\host-app -AddModulePath app   # 指定父仓库内路径
.\zgit.ps1 -Add -AddPath C:\work\host-app -NoPush              # 只提交不推送
.\zgit.ps1 -Add -AddPath C:\work\host-app -DryRun              # 只预览将执行的操作
```

前置条件：子仓库**已经推送到远程并配置好 `origin`**（`git remote add origin <URL>` + `git push -u origin <分支>`），否则脚本会明确报错。

### 方式二：把脚本分发给子仓库负责人（`-Add` 分发场景）

`zgit.ps1` 可以直接分发给单独维护子仓库的同事。分发给同事**之前**，请把脚本顶部的配置区改为父仓库地址：

```powershell
# ===================== 配置区（分发前请修改） =====================
$ParentRepoUrl = 'https://github.com/Jeffrey1799/Z.git'   # 改成你的父仓库地址
# =================================================================
```

同事在自己的子仓库目录里运行（无需本地克隆父仓库）：

```powershell
# 在子仓库目录中执行，脚本自动识别当前仓库的 URL 与分支
.\zgit.ps1 -Add
# 或指定父仓库地址（临时覆盖配置区）
.\zgit.ps1 -Add -ParentUrl https://github.com/Jeffrey1799/Z.git
```

脚本会自动：识别当前子仓库的 `origin` URL 与当前分支 → 克隆父仓库到临时目录 → `submodule add` → 配置 `branch` / `ignore = all` → 提交并推送到父仓库远程 → 清理临时目录。

注意事项：

- 提交后**默认推送**父仓库远程。若推送失败（最常见原因是**对父仓库没有 push 权限**），脚本会明确告诉你发生了什么（已注册提交但未发布到父仓库远程）、以及解决办法：让维护者把你加为协作者后重新运行；或联系维护者提供子仓库信息，由维护者用 `-Add -AddPath` 代为注册；或自行克隆父仓库注册后走 Pull Request。临时克隆的父仓库会被自动清理，父仓库远程不会残留任何变更。
- 同事只需在自己的仓库里执行这一次 `-Add`，之后的工作流仍然是：维护自己的仓库、`git push`，父仓库不再需要任何操作。
- 子模块名称默认取子仓库目录名，可用 `-AddName` / `-AddBranch` / `-AddModulePath` 覆盖。

### 方式三：手动命令（与方式一/二等效）

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
- 要获得各子仓库指定分支的远程最新版本，**必须**运行 `zgit.ps1`。
- 脚本更新前会检查每个子仓库：只要存在已修改/已暂存/未跟踪文件，或正在 merge/rebase/cherry-pick，就立即停止并明确指出是哪个子仓库，**不会** stash、提交或删除你的修改。
- 本地分支与远程已分叉时，脚本不自动 merge / rebase / 强制覆盖，会停止并输出人工处理命令。
- 父仓库不保证历史提交能够恢复当时精确的子仓库版本组合（子仓库指针不会随每次同步写入父仓库）。
- 如果未来需要正式发布和版本追溯，应另行处理：进入父仓库提交 Submodule 指针并打 Tag（例如 `git add .gitmodules <子仓库路径>`、`git commit`、`git tag vX.Y.Z`），再推送。
