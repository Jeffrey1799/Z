#requires -Version 5.1
<#
.SYNOPSIS
    一键同步父仓库内所有子仓库到各自配置分支的远程最新版本。

.DESCRIPTION
    设计目标：父仓库只"关联"多个独立子仓库，不锁定子仓库版本组合。
    本脚本会把每个子仓库更新到 .gitmodules 中配置的 branch 的远程最新 commit，
    并让子仓库保持在正常的本地分支上（避免长期处于 detached HEAD）。

    安全约束：
    - 不使用 git reset --hard / git clean -fd / git checkout --force / git push --force。
    - 任何子仓库存在未提交修改、未跟踪文件，或正在进行 merge/rebase/cherry-pick 时，立即停止。
    - 不自动 stash、不自动提交、不删除用户的修改。
    - 本地分支与远程分叉时不自动 merge / rebase / 强制覆盖，停止并输出人工处理说明。

.PARAMETER SkipParentPull
    跳过父仓库的 git pull，只同步子仓库。

.PARAMETER Submodule
    只处理指定名称或路径的子模块。可传多个：-Submodule A,B 或 -Submodule A -Submodule B。

.PARAMETER DryRun
    只显示将要执行的操作，不修改工作区与任何 git 引用。

.PARAMETER Add
    添加子仓库模式（别名 -build）。把指定本地 Git 仓库接入父仓库成为子模块：
    自动读取其 origin 的 URL 与当前分支，执行 submodule add，配置 branch / ignore=all 并提交。
    父仓库来源：优先使用当前目录树内找到的父仓库；否则克隆脚本顶部 $ParentRepoUrl 配置的地址。
    提交后默认推送父仓库远程；加 -NoPush 跳过推送。

.PARAMETER AddPath
    与 -Add 配合：指定子仓库本地路径（绝对或相对路径）。
    省略时使用当前目录（分发场景：同事在自己的子仓库目录里运行）。

.PARAMETER AddName
    与 -Add 配合：指定子模块名称（默认取子仓库目录名）。

.PARAMETER AddBranch
    与 -Add 配合：指定跟踪分支（默认取子仓库当前分支）。

.PARAMETER AddModulePath
    与 -Add 配合：指定子模块在父仓库中的路径（默认与名称相同）。

.PARAMETER ParentUrl
    与 -Add 配合：指定父仓库地址（优先级高于脚本顶部的 $ParentRepoUrl 配置）。
    用于覆盖默认配置或测试。

.PARAMETER NoPush
    与 -Add 配合：提交后不推送父仓库远程。

.EXAMPLE
    .\sync-all.ps1
    .\sync-all.ps1 -SkipParentPull
    .\sync-all.ps1 -Submodule firmware
    .\sync-all.ps1 -Submodule host-app,firmware
    .\sync-all.ps1 -DryRun
    .\sync-all.ps1 -Add -AddPath C:\work\host-app
    .\sync-all.ps1 -Add -AddPath C:\work\host-app -NoPush
    .\sync-all.ps1 -build   # 同事在自己子仓库目录运行，自动注册进父仓库
#>
[CmdletBinding()]
param(
    [switch]$SkipParentPull,
    [string[]]$Submodule = @(),
    [switch]$DryRun,
    [Alias('build')]
    [switch]$Add,
    [string]$AddPath,
    [string]$AddName,
    [string]$AddBranch,
    [string]$AddModulePath,
    [string]$ParentUrl,
    [switch]$NoPush
)

# ===================== 配置区（分发前请修改） =====================
# 父仓库地址：同事在自己的子仓库里运行 -Add 时，脚本会克隆该地址的父仓库，
# 把子仓库注册进去（submodule add + branch/ignore 配置 + 提交 + 推送）。
# 留空：仅在脚本位于父仓库目录树内时可用（本地维护者场景）。
$ParentRepoUrl = 'https://github.com/Jeffrey1799/Z.git'
# =================================================================
if ($ParentUrl) { $ParentRepoUrl = $ParentUrl }

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Write-Step { param([string]$m) Write-Output "==> $m" }
function Write-Ok   { param([string]$m) Write-Output "    [OK]   $m" }
function Write-Warn { param([string]$m) Write-Output "    [WARN] $m" }
function Write-Err  { param([string]$m) Write-Output "    [ERROR] $m" }

function Invoke-Git {
    # 执行 git，失败即抛异常
    param([string[]]$ArgsList)
    & git @ArgsList
    if ($LASTEXITCODE -ne 0) {
        throw "git $($ArgsList -join ' ') 执行失败（退出码 $LASTEXITCODE）"
    }
}

function Test-InProgressOps {
    # 检测 merge / rebase / cherry-pick 等进行中的操作，返回 $null 表示没有
    param([string]$RepoDir)
    Push-Location $RepoDir
    try {
        $gitDir = & git rev-parse --git-dir
        foreach ($m in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD')) {
            $p = & git rev-parse --git-path $m
            if ($p -and (Test-Path $p)) {
                return "存在未完成的 $m 对应的操作（merge/cherry-pick/revert）"
            }
        }
        $r1 = & git rev-parse --git-path rebase-merge
        $r2 = & git rev-parse --git-path rebase-apply
        if (($r1 -and (Test-Path $r1)) -or ($r2 -and (Test-Path $r2))) {
            return '存在未完成的 rebase 操作'
        }
        return $null
    } finally {
        Pop-Location
    }
}

# ---------- 0. 定位父仓库根目录 ----------
$root = $null
$dir = (Get-Location).Path
while ($true) {
    if ((Test-Path (Join-Path $dir '.git')) -and (Test-Path (Join-Path $dir '.gitmodules'))) {
        $root = $dir
        break
    }
    $parentDir = Split-Path $dir -Parent
    if (-not $parentDir -or $parentDir -eq $dir) { break }
    $dir = $parentDir
}

# ---------- 0.5 添加子仓库模式（-Add / -build） ----------
if ($Add) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err '未检测到 Git。请先安装 Git for Windows：https://git-scm.com/download/win'
        exit 1
    }

    # 解析子仓库源路径（-AddPath 优先，否则当前目录）
    $src = $null
    if ($AddPath) {
        $resolved = Resolve-Path $AddPath -ErrorAction SilentlyContinue
        if ($resolved) { $src = $resolved.Path }
    } else {
        $src = (Get-Location).Path
    }
    if (-not $src -or -not (Test-Path $src)) {
        Write-Err "无法解析子仓库路径：'$AddPath'。请用 -AddPath 指定本地子仓库目录。"
        exit 1
    }
    $src = [System.IO.Path]::GetFullPath($src)

    # 确认是 Git 仓库
    & git -C $src rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "目标目录不是 Git 仓库：$src"
        exit 1
    }

    # 自动识别 origin URL（子仓库须已推到远程并配置 origin）
    $url = (& git -C $src remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $url) {
        Write-Err "子仓库 '$src' 未配置 origin 远程。请先在子仓库中执行："
        Write-Err '    git remote add origin <仓库URL>'
        Write-Err '    git push -u origin <分支>'
        exit 1
    }

    # 自动识别跟踪分支
    $branch = $AddBranch
    if (-not $branch) {
        $branch = (& git -C $src rev-parse --abbrev-ref HEAD)
        if ($branch -eq 'HEAD') {
            Write-Err '无法自动识别分支：源仓库处于 detached HEAD。请用 -AddBranch <分支> 指定。'
            exit 1
        }
    }

    # 名称与父仓库内路径
    $leaf  = Split-Path $src -Leaf
    $name  = if ($AddName)       { $AddName }       else { $leaf }
    $mpath = if ($AddModulePath) { $AddModulePath } else { $leaf }

    Write-Ok "子仓库源: $src"
    Write-Ok "URL     : $url"
    Write-Ok "分支    : $branch"
    Write-Ok "名称    : $name"
    Write-Ok "路径    : $mpath"

    # 确定父仓库：优先当前目录树内定位的；否则克隆配置的父仓库地址
    $parent = $null
    $tmpParent = $null
    if ($root) {
        $parent = $root
        if ($src -eq $parent) {
            Write-Err '不能把父仓库本身添加为子模块。请指定另一个独立仓库目录（-AddPath）。'
            exit 1
        }
        Write-Ok "父仓库（本地定位）: $parent"
    } elseif ($ParentRepoUrl) {
        $tmpParent = Join-Path $env:TEMP ("z-parent-" + [guid]::NewGuid().ToString('N'))
        Write-Step "克隆父仓库到临时目录（$ParentRepoUrl）..."
        try {
            Invoke-Git @('clone','--quiet',$ParentRepoUrl,$tmpParent)
        } catch {
            Write-Err "克隆父仓库失败：$($_.Exception.Message)"
            Write-Err '请检查脚本顶部 $ParentRepoUrl 配置，或确认网络与凭据可用。'
            exit 1
        }
        $parent = $tmpParent
        Write-Ok "父仓库（临时克隆）: $parent"
    } else {
        Write-Err '未找到父仓库（当前目录不在父仓库目录树内），且未配置脚本顶部的 $ParentRepoUrl。'
        Write-Err '两种方式任选其一：'
        Write-Err '    1) 维护者在脚本顶部把 $ParentRepoUrl 配置为父仓库地址，再把脚本分发给同事；'
        Write-Err '    2) 在父仓库根目录运行本脚本，用 -AddPath 指定子仓库目录。'
        exit 1
    }

    # 在父仓库中执行注册
    Push-Location $parent
    try {
        $dup = (& git config -f .gitmodules --get-regexp "^submodule\.$([regex]::Escape($name))\.path$" 2>$null)
        if ($dup) {
            Write-Err "子模块 '$name' 已存在于父仓库 .gitmodules。"
            exit 1
        }
        $tracked = (& git ls-files --stage -- $mpath)
        if ($tracked) {
            Write-Err "父仓库中路径 '$mpath' 已被跟踪，请改用 -AddModulePath 指定其他路径。"
            exit 1
        }
        $targetDir = Join-Path $parent $mpath
        if (Test-Path $targetDir) {
            $kids = @(Get-ChildItem $targetDir -Force | Where-Object { $_.Name -ne '.git' })
            if ($kids.Count -gt 0) {
                Write-Err "父仓库中已存在非空目录 '$mpath'。请先移除，或改用 -AddModulePath 指定其他路径。"
                exit 1
            }
        }

        if ($DryRun) {
            Write-Output ''
            Write-Output '========== Dry Run：将执行以下操作（未做任何修改） =========='
            Write-Output "  git submodule add --name $name $url $mpath"
            Write-Output "  git config -f .gitmodules submodule.$name.branch $branch"
            Write-Output "  git config -f .gitmodules submodule.$name.ignore all"
            Write-Output "  git add .gitmodules $mpath"
            Write-Output "  git commit -m \"chore: add submodule $name\""
            if (-not $NoPush) { Write-Output '  git push  （推送到父仓库远程）' }
            Write-Ok 'Dry Run 结束：未执行任何修改。'
            exit 0
        }

        Write-Step "执行 git submodule add（名称 $name，路径 $mpath）..."
        try {
            Invoke-Git @('submodule','add','--name',$name,$url,$mpath)
        } catch {
            Write-Err "git submodule add 失败：$($_.Exception.Message)"
            Write-Err '常见原因：URL 无法访问、目录非空、或 git 安全策略禁止该协议。'
            exit 1
        }
        Invoke-Git @('config','-f','.gitmodules',"submodule.$name.branch",$branch)
        Invoke-Git @('config','-f','.gitmodules',"submodule.$name.ignore",'all')
        git add .gitmodules $mpath
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'git add 失败。'
            exit 1
        }
        Write-Step '提交父仓库...'
        try {
            Invoke-Git @('commit','-m',"chore: add submodule $name")
        } catch {
            Write-Err "提交失败：$($_.Exception.Message)"
            Write-Err '请确认父仓库（或全局）已配置 user.name / user.email。'
            exit 1
        }
        Write-Ok "已提交：chore: add submodule $name"

        if ($NoPush) {
            Write-Warn '已指定 -NoPush，未推送父仓库。如需发布：git push'
            if ($tmpParent) {
                Write-Warn '注意：父仓库为临时克隆，脚本退出时将清理该目录，未推送的提交不会保留。'
                Write-Warn '如需手动推送，请勿使用 -NoPush（直接重新运行即可默认推送），或在本地父仓库中使用本命令。'
            }
        } else {
            Write-Step '推送父仓库...'
            try {
                Invoke-Git @('push')
                Write-Ok '已推送到父仓库远程。'
            } catch {
                Write-Err "推送父仓库失败：$($_.Exception.Message)"
                Write-Err ''
                Write-Err '【本次操作结果】子模块已在本地完成注册和提交，但【未能发布】到父仓库远程。'
                Write-Err '（临时克隆的父仓库目录将被清理，父仓库远程未发生任何变化。）'
                Write-Err ''
                Write-Err '【最常见原因】您对父仓库没有推送（push）权限。'
                Write-Err ''
                Write-Err '【解决办法，任选其一】'
                Write-Err "  1) 请父仓库维护者把您添加为协作者，获得推送权限后重新运行本脚本；"
                Write-Err '     （GitHub 仓库: Settings -> Collaborators -> Add people；组织仓库由管理员在仓库权限中授权）'
                Write-Err "  2) 联系父仓库维护者，提供本子仓库信息（URL: $url，分支: $branch），"
                Write-Err '     由维护者在本地父仓库中运行：.\sync-all.ps1 -Add -AddPath <子仓库本地路径> 完成注册；'
                Write-Err '  3) 自行克隆父仓库、手动执行 submodule 注册并提交，再通过 Pull Request 提交给维护者合并。'
                exit 1
            }
        }

        Write-Output ''
        Write-Output '========== 添加完成 =========='
        Write-Output "子模块 '$name' 已接入父仓库："
        Write-Output "  远程: $url"
        Write-Output "  分支: $branch"
        Write-Output '子仓库负责人后续只需维护自己的仓库并 push，父仓库无需再操作。'
        exit 0
    } finally {
        Pop-Location
        if ($tmpParent -and (Test-Path $tmpParent)) {
            Remove-Item -LiteralPath $tmpParent -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $tmpParent) { Write-Warn "临时父仓库目录 $tmpParent 未能删除，请稍后手动清理。" }
        }
    }
}

if (-not $root) {
    Write-Err '未找到父仓库：需要同时存在 .git 与 .gitmodules。'
    Write-Err '请在父仓库根目录（或其任意子目录）中运行本脚本。'
    exit 1
}
Write-Ok "父仓库根目录: $root"

# ---------- 1. 检查 Git ----------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err '未检测到 Git。请先安装 Git for Windows：https://git-scm.com/download/win'
    exit 1
}
Write-Ok (& git --version)

Push-Location $root
try {
    # ---------- 2. 父仓库干净性检查 ----------
    Write-Step '检查父仓库是否存在未提交修改...'
    $parentStatus = (& git status --porcelain)
    if ($parentStatus) {
        Write-Err '父仓库存在未提交的修改，请先处理后再运行（本脚本不会替你提交或还原）：'
        $parentStatus | ForEach-Object { Write-Err "    $_" }
        exit 1
    }
    $inProgress = Test-InProgressOps $root
    if ($inProgress) {
        Write-Err "父仓库$inProgress，请先手动处理。"
        exit 1
    }

    # ---------- 3. 拉取父仓库远程最新版本（不递归更新子模块） ----------
    if ($SkipParentPull -or $DryRun) {
        if ($SkipParentPull) { Write-Warn '已指定 -SkipParentPull，跳过父仓库拉取。' }
        else                 { Write-Warn 'Dry Run：跳过父仓库拉取。' }
    } else {
        & git rev-parse --verify --quiet HEAD
        if ($LASTEXITCODE -ne 0) {
            Write-Warn '父仓库还没有任何提交，跳过 git pull。'
        } else {
            $remotes = (& git remote)
            if (-not $remotes) {
                Write-Warn '父仓库未配置远程仓库，跳过 git pull。'
            } else {
                Write-Step '拉取父仓库远程最新版本（--ff-only，不递归更新子模块）...'
                try {
                    Invoke-Git @('pull','--ff-only','--no-recurse-submodules')
                } catch {
                    Write-Err "父仓库拉取失败：$($_.Exception.Message)"
                    Write-Err '如果本地存在未推送的提交且与远程已分叉，请先手动解决（如 git pull --rebase），再重新运行本脚本。'
                    exit 1
                }
            }
        }
    }

    # ---------- 4. submodule sync + init（DryRun 时跳过实际变更） ----------
    if ($DryRun) {
        Write-Warn 'Dry Run：跳过 submodule sync / init 等实际变更操作。'
    } else {
        Write-Step '同步子模块远程配置（git submodule sync --recursive）...'
        Invoke-Git @('submodule','sync','--recursive')

        Write-Step '初始化子模块（git submodule init）...'
        Invoke-Git @('submodule','init')
    }

    # ---------- 5. 读取 .gitmodules 中的子模块清单 ----------
    $submodules = @()
    $nameOut = (& git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$')
    foreach ($line in $nameOut) {
        if ($line -match '^submodule\.(.+)\.path$') {
            $n = $Matches[1]
            $p = (& git config -f .gitmodules --get "submodule.$n.path")
            $u = (& git config -f .gitmodules --get "submodule.$n.url")
            $b = (& git config -f .gitmodules --get "submodule.$n.branch")
            if (-not $b) {
                Write-Err "子模块 '$n' 未在 .gitmodules 中配置 branch（submodule.$n.branch），无法确定跟踪分支。请补充配置后再运行。"
                exit 1
            }
            $submodules += [PSCustomObject]@{ Name = $n; Path = $p; Url = $u; Branch = $b }
        }
    }
    if (-not $submodules) {
        Write-Warn '.gitmodules 中没有配置任何子模块，没有需要同步的内容。'
        exit 0
    }

    # ---------- 5.1 按 -Submodule 过滤（名称或路径） ----------
    if ($Submodule.Count -gt 0) {
        $filtered = @()
        foreach ($s in $submodules) {
            foreach ($f in $Submodule) {
                if ($s.Name -eq $f -or $s.Path -eq $f -or $s.Path.EndsWith('/' + $f)) {
                    $filtered += $s
                    break
                }
            }
        }
        if (-not $filtered) {
            Write-Err "未找到与 '-Submodule $($Submodule -join ', ')' 匹配的子模块。可用名称/路径：$($submodules.Name -join ', ')"
            exit 1
        }
        $submodules = $filtered
        Write-Ok "仅处理指定子模块：$($submodules.Name -join ', ')"
    }

    # ---------- 5.2 DryRun：只读预览 ----------
    if ($DryRun) {
        Write-Output ''
        Write-Output '========== Dry Run：以下为将要执行的操作（未做任何修改） =========='
        foreach ($s in $submodules) {
            $subDir = Join-Path $root $s.Path
            $state = '尚未克隆'
            if (Test-Path (Join-Path $subDir '.git')) {
                Push-Location $subDir
                try {
                    $cur   = & git rev-parse --abbrev-ref HEAD
                    $short = & git rev-parse --short HEAD
                    $state = "当前分支 $cur @ $short"
                } finally {
                    Pop-Location
                }
            }
            Write-Ok ("[{0}] 路径 {1,-14} 分支 {2,-10} | {3}  ->  将 fetch origin 并 fast-forward 到 origin/{2}" -f $s.Name, $s.Path, $s.Branch, $state)
        }
        Write-Ok 'Dry Run 结束：未执行任何修改。'
        exit 0
    }

    # ---------- 6. 初始化缺失的子模块 ----------
    foreach ($s in $submodules) {
        $subDir = Join-Path $root $s.Path
        $needInit = $false
        if (-not (Test-Path (Join-Path $subDir '.git'))) {
            if (Test-Path $subDir) {
                $children = @(Get-ChildItem $subDir -Force | Where-Object { $_.Name -ne '.git' })
                if ($children.Count -gt 0) {
                    Write-Err "子模块目录 '$($s.Path)' 存在但内容不是有效仓库（且非空）。请检查该目录后重试。"
                    exit 1
                }
            }
            $needInit = $true
        }
        if ($needInit) {
            Write-Step "初始化子模块 $($s.Name) ..."
            try {
                Invoke-Git @('submodule','update','--init','--',$s.Path)
            } catch {
                Write-Err "初始化子模块 $($s.Name) 失败：$($_.Exception.Message)"
                exit 1
            }
        }
    }

    # ---------- 7. 逐个子模块同步到远程最新分支 ----------
    $results = @()
    foreach ($s in $submodules) {
        $subDir = Join-Path $root $s.Path
        Write-Step "处理子模块 $($s.Name)（路径 $($s.Path)，跟踪分支 $($s.Branch)）"

        if (-not (Test-Path (Join-Path $subDir '.git'))) {
            Write-Err "子模块 $($s.Name) 目录不存在或未初始化。请先确认 .gitmodules 配置正确。"
            exit 1
        }

        Push-Location $subDir
        try {
            # 7.1 安全检查：工作区必须干净，且无进行中的操作
            $status = (& git status --porcelain)
            if ($status) {
                Write-Err "子模块 $($s.Name)（路径 $($s.Path)）存在未提交/未跟踪的修改，已停止整个同步流程，未做任何改动："
                $status | ForEach-Object { Write-Err "    $_" }
                Write-Err '请先在子仓库中提交、还原或妥善处理这些修改，再重新运行。本脚本不会自动 stash / 提交 / 删除你的修改。'
                exit 1
            }
            $inProgress = Test-InProgressOps $subDir
            if ($inProgress) {
                Write-Err "子模块 $($s.Name)（路径 $($s.Path)）$inProgress，请先手动处理后再运行。"
                exit 1
            }

            # 7.2 fetch 远程
            Write-Ok 'git fetch origin ...'
            try {
                Invoke-Git @('fetch','origin')
            } catch {
                Write-Err "获取子模块 $($s.Name) 远程失败：$($_.Exception.Message)"
                exit 1
            }

            # 7.3 确认远程跟踪分支存在
            $remoteRef = "refs/remotes/origin/$($s.Branch)"
            $targetSha = (& git rev-parse --verify --quiet $remoteRef)
            if ($LASTEXITCODE -ne 0 -or -not $targetSha) {
                Write-Err "子模块 $($s.Name)（路径 $($s.Path)）配置的跟踪分支 '$($s.Branch)' 在远程不存在（origin/$($s.Branch)）。"
                Write-Err '请检查 .gitmodules 中 submodule.<name>.branch 配置是否正确。'
                exit 1
            }

            # 7.4 保持在正常本地分支上，并 fast-forward 到远程最新
            & git show-ref --verify --quiet "refs/heads/$($s.Branch)"
            $localExists = ($LASTEXITCODE -eq 0)
            $curBranch = & git rev-parse --abbrev-ref HEAD

            if (-not $localExists) {
                Write-Ok "创建本地分支 $($s.Branch) 并跟踪 origin/$($s.Branch) ..."
                try {
                    Invoke-Git @('checkout','-b',$s.Branch,"origin/$($s.Branch)")
                } catch {
                    Write-Err "创建本地分支 $($s.Branch) 失败：$($_.Exception.Message)"
                    exit 1
                }
            } else {
                if ($curBranch -ne $s.Branch) {
                    Write-Ok "切换到本地分支 $($s.Branch) ..."
                    try {
                        Invoke-Git @('checkout',$s.Branch)
                    } catch {
                        Write-Err "切换到本地分支 $($s.Branch) 失败：$($_.Exception.Message)"
                        exit 1
                    }
                }
                Write-Ok "fast-forward 更新到 origin/$($s.Branch) ..."
                try {
                    Invoke-Git @('merge','--ff-only',"origin/$($s.Branch)")
                } catch {
                    Write-Err "子模块 $($s.Name)（路径 $($s.Path)）本地分支与 origin/$($s.Branch) 已分叉，无法 fast-forward。"
                    Write-Err '为避免覆盖你的提交，脚本已停止。请人工处理（任选其一）：'
                    Write-Err "    cd $($s.Path)"
                    Write-Err "    git fetch origin"
                    Write-Err "    git merge origin/$($s.Branch)     # 或 git rebase origin/$($s.Branch)"
                    Write-Err '解决冲突并提交后，再重新运行本脚本。'
                    exit 1
                }
            }

            # 7.5 记录结果
            $headSha    = & git rev-parse HEAD
            $shortSha   = & git rev-parse --short HEAD
            $headMsg    = & git log -1 --pretty=%s
            $branchName = & git rev-parse --abbrev-ref HEAD
            if ($branchName -eq 'HEAD') { $branchName = '(detached)' }
            $results += [PSCustomObject]@{ Name=$s.Name; Path=$s.Path; Branch=$branchName; Commit=$shortSha; Full=$headSha; Message=$headMsg }
            Write-Ok "当前: $branchName @ $shortSha — $headMsg"
        } finally {
            Pop-Location
        }
    }

    # ---------- 8. 汇总 ----------
    Write-Output ''
    Write-Output '========== 同步结果 =========='
    Write-Output ('{0,-12} {1,-16} {2,-12} {3,-10} {4}' -f '名称','路径','分支','Commit','最新提交')
    foreach ($r in $results) {
        Write-Output ('{0,-12} {1,-16} {2,-12} {3,-10} {4}' -f $r.Name, $r.Path, $r.Branch, $r.Commit, $r.Message)
    }
    Write-Ok "共处理 $($results.Count) 个子模块，全部完成。"
    exit 0
}
finally {
    Pop-Location
}
