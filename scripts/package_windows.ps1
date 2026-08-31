# 飞牛音乐 Windows 打包脚本（绿色版 zip）
#
# 用法：
#   .\scripts\package_windows.ps1            # 打包当前版本（自动读 pubspec 版本号）
#   .\scripts\package_windows.ps1 -Version 1.4.7
#   .\scripts\package_windows.ps1 -Build     # 先 flutter build windows --release 再打包
#
# 前置：默认要求已执行 flutter build windows --release（-Build 会自动构建）
# 产物：build\installer\FeiNiuMusic-v<版本>-Windows.zip
#
# 数据持久化说明：App 数据（账号、收藏、听歌统计、缓存）存放在
# %LOCALAPPDATA% 下，卸载/删除绿色版不会清掉，重装后数据仍在。

param(
  [string]$Version = "",
  [switch]$Build
)

$ErrorActionPreference = "Stop"

# 项目根目录（脚本位于 scripts/ 下）
$Root = Split-Path -Parent $PSScriptRoot
$ReleaseDir = Join-Path $Root "build\windows\x64\runner\Release"
$OutDir = Join-Path $Root "build\installer"

# 版本号未指定时从 pubspec.yaml 自动读取（去掉 +build 后缀，如 1.4.7+1 → 1.4.7）
if ([string]::IsNullOrEmpty($Version)) {
  $Pubspec = Join-Path $Root "pubspec.yaml"
  if (Test-Path $Pubspec) {
    $VerLine = Select-String -Path $Pubspec -Pattern '^version:\s*(.+)$' | Select-Object -First 1
    if ($VerLine -and $VerLine.Matches[0].Groups[1].Value) {
      $Full = $VerLine.Matches[0].Groups[1].Value.Trim()
      $Version = $Full.Split('+')[0]
    }
  }
  if ([string]::IsNullOrEmpty($Version)) {
    Write-Error "无法自动读取版本号，请用 -Version 参数指定"
    exit 1
  }
}

# 可选：先构建再打包（CI / 一键脚本用）
if ($Build) {
  Write-Host ">>> 开始 flutter build windows --release ..."
  Push-Location $Root
  try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) {
      Write-Error "flutter build 失败（exit=$LASTEXITCODE）"
      exit 1
    }
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path (Join-Path $ReleaseDir "飞牛音乐.exe"))) {
  Write-Error "未找到 飞牛音乐.exe，请先运行 flutter build windows --release 或用 -Build 参数"
  exit 1
}

New-Item -ItemType Directory -Force $OutDir | Out-Null

# 组装临时发布目录（Release 内容 + 使用说明 + 应用图标）
$BundleName = "FeiNiuMusic-v$Version-Windows"
$Stage = Join-Path $OutDir "_stage_$BundleName"
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force $Stage | Out-Null

# 1. Release 产物（exe + data/ + 各 DLL，含 libmpv-2.dll）
Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $Stage -Recurse -Force

# 2. 使用说明
$Readme = @"
飞牛音乐 Windows 版 v$Version（免安装绿色版）

使用方法：
  1. 把整个文件夹解压到任意位置（如 D:\FeiNiuMusic）。
  2. 双击 飞牛音乐.exe 即可运行。
  3. 可选：右键 飞牛音乐.exe → 发送到 → 桌面快捷方式。

数据说明：
  - 账号、收藏、听歌统计、歌词/封面缓存等数据存放在 exe 同级的
    feiniumusic_data/ 文件夹内，随绿色版一起移动。
  - 卸载只需删除整个文件夹，无残留注册表项。
  - 注意：把文件夹复制到其他电脑使用时会自动清除已保存的密码/token，
    需在新机器上重新登录（出于安全考虑）。
"@
$Readme | Out-File -FilePath (Join-Path $Stage "使用说明.txt") -Encoding utf8

# 3. 应用图标副本
Copy-Item -Path (Join-Path $Root "windows\runner\resources\app_icon.ico") `
  -Destination (Join-Path $Stage "app_icon.ico") -Force

# 4. 压缩为 zip
$ZipPath = Join-Path $OutDir "$BundleName.zip"
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath -CompressionLevel Optimal

# 5. 清理临时目录
Remove-Item -Recurse -Force $Stage

Write-Host "打包完成：$ZipPath"
Write-Host "大小：$((Get-Item $ZipPath).Length / 1MB) MB"
