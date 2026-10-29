# UniFi Protect Local: find the settings page on your SmartThings hub and open it.
# Run in PowerShell:
#   irm https://raw.githubusercontent.com/Stoeckie/smartthings-unifi-protect-local/main/tools/find-settings-page.ps1 | iex
# Needs the SmartThings CLI: https://github.com/SmartThingsCommunity/smartthings-cli/releases

$ErrorActionPreference = "Continue"
$driver = "27595fa5-a979-491e-8c16-6cf5362cd859"   # UniFi Protect Local

$st = (Get-Command smartthings -ErrorAction SilentlyContinue).Source
if (-not $st) { $st = "C:\Program Files\SmartThings\smartthings.exe" }
if (-not (Test-Path $st)) {
  Write-Host "SmartThings CLI not found. Install it first: https://github.com/SmartThingsCommunity/smartthings-cli/releases" -ForegroundColor Red
  return
}

$hubIp = $env:ST_HUB_IP
if (-not $hubIp) { $hubIp = Read-Host "IP address of your SmartThings hub (not the UniFi console)" }
$hubIp = $hubIp.Trim()

Write-Host "Looking for the UniFi Protect device (the CLI may open a browser to log in)..."
$all = & $st devices --type LAN -j | Out-String | ConvertFrom-Json
$id = ($all | Where-Object { $_.lan.networkId -like "unifi-protect-local-*" -or $_.name -eq "UniFi Protect" } |
  Select-Object -First 1).deviceId
if ($id) { Write-Host "Found device $id" } else { Write-Host "No UniFi Protect device found yet; waiting for the driver to print the address (up to 90 s)." }

Write-Host "Reading the hub log at $hubIp ..."
$job = Start-Job { & $using:st edge:drivers:logcat $using:driver --hub-address $using:hubIp 2>&1 | ForEach-Object { "$_" } }
$start = Get-Date
$url = $null
$refreshed = $false
while (-not $url -and ((Get-Date) - $start).TotalSeconds -lt 90) {
  Start-Sleep -Seconds 2
  foreach ($line in @(Receive-Job $job)) {
    $line = "$line"
    if ($line -match '\[unifi\].*?(http://[\d\.]+:\d+/)') { $url = $Matches[1] }
    elseif ($line -match 'rror|refused|timed out|ENOTFOUND|EHOSTUNREACH') { Write-Host $line -ForegroundColor Yellow }
  }
  if ($id -and -not $refreshed -and ((Get-Date) - $start).TotalSeconds -ge 8) {
    & $st devices:commands $id refresh:refresh | Out-Null   # makes the driver print the address again
    $refreshed = $true
  }
  if ($job.State -ne "Running" -and -not $url) { Receive-Job $job | ForEach-Object { Write-Host "$_" -ForegroundColor Yellow }; break }
}
Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

if ($url) {
  Write-Host ""
  Write-Host "Settings page: $url" -ForegroundColor Green
  Write-Host "Enter the IP address of your UniFi console and your API key there."
  Start-Process $url
} else {
  Write-Host "No address found. Check the hub IP and that UniFi Protect Local is installed on that hub." -ForegroundColor Red
}
