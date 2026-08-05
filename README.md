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
.\zgit.ps1 -pull
```

## 如何拉取父仓库

```powershell
.\zgit.ps1 -pull
```

> **注意（分发场景 / 仅子仓库环境）**：`.\zgit.ps1 -pull` 依赖父仓库及其 `.gitmodules` 配置文件。若电脑上只有单个子仓库（没有克隆父仓库），运行 `-pull` 会报错提示找不到父仓库。单子仓库开发者日常同步直接使用标准 Git 命令即可：`git pull --ff-only`。

## 可选参数

```powershell
.\zgit.ps1 -pull -SkipParentPull      # 不拉取父仓库，只同步子仓库
.\zgit.ps1 -pull -Submodule firmware  # 只同步指定子仓库（名称或路径）
.\zgit.ps1 -pull -Submodule host-app,firmware  # 同时同步多个
.\zgit.ps1 -pull -DryRun              # 只显示将要执行的操作，不修改任何内容
.\zgit.ps1 -add C:\work\host-app         # 把本地子仓库注册进父仓库（直接指定路径）
.\zgit.ps1 -rm                       # 解绑当前目录对应的子仓库指针（在子仓库目录执行）
.\zgit.ps1 -rm -Submodule algorithm   # 仅从父仓库解绑指定子仓库指针（保留本地磁盘文件）
.\zgit.ps1 -help                      # 打印完整命令行帮助菜单（别名: -h, -?）
```

## 子仓库负责人工作流

子仓库负责人仍然可以直接克隆和维护自己的仓库，不需要操作父仓库
**不需要**进入父仓库做任何操作，父仓库不会因子仓库更新而出现待提交状态。

## 如何添加一个新的子仓库

使用 `-add`（或别名 `-build`）可自动把一个独立子仓库接入父仓库。

> **前置条件**：子仓库必须**已推送到远程并配置好 `origin`**（即已执行 `git remote add origin <URL>` 及 `git push -u origin <分支>`），脚本会自动读取其远程 URL 与当前分支。

### 场景一：在拥有父仓库目录的环境下添加

在父仓库根目录（或其子目录）中运行脚本，直接传入本地子仓库路径：

```powershell
# 在父仓库根目录执行，接入外部子仓库目录
.\zgit.ps1 -add C:\work\host-app

# 或直接指定父仓库内部已有的子仓库目录（原地一键注册并推送远程父仓库）
.\zgit.ps1 -add host-app
```

- **常用扩展参数**：
  ```powershell
  .\zgit.ps1 -add C:\work\host-app -Name host-app       # 指定子模块名称（别名: -Name / -n）
  .\zgit.ps1 -add C:\work\host-app -Branch dev          # 指定跟踪分支为 dev（别名: -Branch 或 -b）
  .\zgit.ps1 -add C:\work\host-app -AddModulePath app   # 指定保存在父仓库中的相对路径
  .\zgit.ps1 -add C:\work\host-app -NoPush              # 只提交不推送父仓库远程
  .\zgit.ps1 -add C:\work\host-app -DryRun              # 只预览将要执行的操作
  ```

### 场景二：在只有子仓库目录的环境下添加（分发场景）

同事在独立的子仓库目录中（本地无父仓库）运行，脚本会自动识别当前仓库的 `origin` URL 与当前分支，并连接远程父仓库自动注册：

1. **分发前配置**（维护者在脚本顶部配置默认父仓库地址）：
   ```powershell
   # ===================== 配置区（分发前请修改） =====================
   $ParentRepoUrl = 'https://github.com/Jeffrey1799/Z.git'   # 改成你的默认父仓库地址
   # =================================================================
   ```

2. **在子仓库目录中运行**：
   ```powershell
   # 在子仓库目录中执行，自动识别当前仓库 URL/分支，并注册进默认父仓库
   .\zgit.ps1 -add

   # 或通过 -ParentUrl 指定/覆盖目标父仓库地址（例如接入其他父仓库）
   .\zgit.ps1 -add -ParentUrl https://github.com/YourOrg/OtherParentRepo.git
   ```

- **运作机制**：识别当前仓库 `origin` URL 与分支 → 克隆父仓库到临时目录 → `submodule add` → 配置 `branch` / `ignore = all` → 提交并推送到父仓库远程 → 自动安全清理临时目录。
- **权限说明**：提交后默认推送父仓库远程。若推送失败（通常为缺乏父仓库 push 权限），需联系管理员添加协作者权限或代为注册。

### 补充：手动 Git 命令添加（等效原理）

在父仓库根目录下手动执行以下命令，效果与脚本相同：

```powershell
# 1. 添加子模块
git submodule add <repository-url> <path>

# 2. 配置跟踪分支与忽略指针变化
git config -f .gitmodules submodule.<name>.branch <branch>
git config -f .gitmodules submodule.<name>.ignore all

# 3. 提交并推送
git commit -m "chore: add submodule <name>"
git push
```


## 如何解绑/移除子仓库指针

使用 `-rm`（或别名 `-Remove`, `-Unbind`）可自动移除父仓库对子仓库的 Git 跟踪指针。

> **安全说明**：解绑操作通过 `git rm --cached` 仅删除 Git 索引与父仓库中的子模块引用，**绝对不会删除本地磁盘上的任何实际文件或代码**。解绑后，该目录在本地完全保留为独立目录。

### 场景一：在拥有父仓库目录的环境下解绑

在父仓库根目录（或其子目录）中运行脚本：

```powershell
# 显式指定要解绑的子仓库（支持传子模块名称或路径）
.\zgit.ps1 -rm -Submodule algorithm

# 在父仓库的某个子仓库目录内直接运行（自动识别当前目录名作为解绑目标）
cd algorithm
..\zgit.ps1 -rm

# 同时解绑多个子仓库，且暂不推送父仓库远程
.\zgit.ps1 -rm -Submodule host-app,firmware -NoPush

# 仅预览将要执行的解绑命令（不修改工作区）
.\zgit.ps1 -rm -Submodule algorithm -DryRun
```

### 场景二：在只有子仓库目录的环境下解绑（分发场景）

同事在独立的子仓库目录中（本地无父仓库）运行，脚本会自动识别当前目录名为子模块名称，并连接远程父仓库解绑指针：

```powershell
# 在子仓库目录中直接执行（自动识别当前目录名，并从默认父仓库解绑）
.\zgit.ps1 -rm

# 或通过 -ParentUrl 指定/覆盖目标父仓库地址（例如从其他父仓库中解绑）
.\zgit.ps1 -rm -ParentUrl https://github.com/YourOrg/OtherParentRepo.git
```

- **运作机制**：脚本会自动克隆父仓库到临时目录 → 从父仓库索引中移除该子模块指针 → 提交并推送到父仓库远程 → 自动安全清理临时目录。

### 补充：手动 Git 命令解绑（等效原理）

在父仓库根目录下手动执行以下命令，效果与脚本相同：

```powershell
# 1. 仅从父仓库 Git 索引中移除指针（保留本地磁盘物理文件）
git rm --cached algorithm

# 2. 从 .gitmodules 中移除该子模块配置段
git config -f .gitmodules --remove-section submodule.algorithm

# 3. 暂存 .gitmodules 并提交/推送
git add .gitmodules
git commit -m "chore: unbind submodule algorithm pointer"
git push
```

## 重要说明

- 普通 `git pull` 只更新父仓库本身，**不会**更新子仓库。
- `git submodule update --init --recursive` 默认按父仓库记录的**旧指针**更新，不是远程最新版本。
- 要获得各子仓库指定分支的远程最新版本，在父仓库环境下**必须**运行 `.\zgit.ps1 -pull`。
- **分发场景与 `-pull` 限制**：`.\zgit.ps1 -pull` 须在包含 `.git` 与 `.gitmodules` 的父仓库目录下运行。若电脑上只有单个子仓库，`-pull` 无法运行，单子仓库开发者日常拉取更新只需直接执行 `git pull --ff-only`；若需拉取整个项目的多子仓库组合，则须先克隆父仓库。
- **分发场景与 `-add`/`-rm` 支持**：`-add` 与 `-rm` 模式均原生支持在独立子仓库目录中运行。脚本会自动通过 `-ParentUrl` 参数或脚本头部的 `$ParentRepoUrl` 配置临时克隆远程父仓库完成指针注册/解绑并推送。
- 脚本更新前会检查每个子仓库：只要存在已修改/已暂存/未跟踪文件，或正在 merge/rebase/cherry-pick，就立即停止并明确指出是哪个子仓库，**不会** stash、提交或删除你的修改。
- 本地分支与远程已分叉时，脚本不自动 merge / rebase / 强制覆盖，会停止并输出人工处理命令。
- 父仓库不保证历史提交能够恢复当时精确的子仓库版本组合（子仓库指针不会随每次同步写入父仓库）。
- 如果未来需要正式发布和版本追溯，应另行处理：进入父仓库提交 Submodule 指针并打 Tag（例如 `git add .gitmodules <子仓库路径>`、`git commit`、`git tag vX.Y.Z`），再推送。
