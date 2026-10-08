# Renders the same view in the web version (headless Chrome on this PC's GPU) and in the Godot port, for side-by-side checks.
#   tools/compare.ps1 -Name v1 -Pos "26700,80000,30000" -Face "26700,0,0" [-Tele 1] [-Expo 2.2] [-Out dir]
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Pos,
  [Parameter(Mandatory)][string]$Face,
  [double]$Tele = 1,
  [double]$Expo = 2.2,
  [string]$Out = "$env:TEMP\universe-compare",
  [string]$Godot = "$PSScriptRoot\..\..\..\tools\godot\Godot_v4.7.2-stable_win64_console.exe",
  [string]$GodotArgs = ""
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$root = Resolve-Path "$PSScriptRoot\.."
$port = 18765
$env:SNAP_DIR = $Out
$server = $null
try { Invoke-WebRequest "http://127.0.0.1:$port/export.html" -UseBasicParsing -TimeoutSec 3 | Out-Null }
catch { $server = Start-Process python -ArgumentList "`"$PSScriptRoot\export_web_data.py`" $port" -PassThru -WindowStyle Hidden; Start-Sleep 2 }

$web = Join-Path $Out "$Name-web.png"
Remove-Item $web -ErrorAction SilentlyContinue
$chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$view = "$Pos,$Face,$Tele,$Expo"
$url = "http://127.0.0.1:$port/export.html?view=$view&snap=$Name-web.png&n=40"
$profile = Join-Path $Out "chrome-profile"
$c = Start-Process $chrome -ArgumentList @('--headless=new', '--enable-gpu', '--use-angle=d3d11', '--in-process-gpu', '--ignore-gpu-blocklist', '--window-size=1376,1032',
  "--user-data-dir=$profile", '--no-first-run', '--hide-scrollbars', $url) -PassThru
for ($i = 0; $i -lt 240 -and -not (Test-Path $web); $i++) { Start-Sleep -Milliseconds 500 }
Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue
Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $chrome -and $_.StartTime -ge $c.StartTime } | Stop-Process -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $web)) { Write-Warning "web picture not made" }

$gd = Join-Path $Out "$Name-godot.png"
$res = '1376x1032'
if (Test-Path $web) { Add-Type -AssemblyName System.Drawing; $im = [System.Drawing.Image]::FromFile($web); $res = "$($im.Width)x$($im.Height)"; $im.Dispose() }
& $Godot --path $root --resolution $res -- --hdr=off --pos=$Pos --face=$Face --tele=$Tele --expo=$Expo --noui --shot=$gd --frames=90 $GodotArgs.Split(' ') 2>&1 |
  Where-Object { $_ -notmatch 'create_frustum_points|rendering_light_culler' } | Select-Object -Last 8
if ($server) { Stop-Process -Id $server.Id -Force }
Write-Output "web: $web"
Write-Output "godot: $gd"
