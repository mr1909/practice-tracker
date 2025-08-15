param(
  [Parameter(Mandatory=$true)][string]$ArtifactDir,
  [string]$SiteName   = "PracticeAppDev",
  [string]$TargetDir  = "C:\sites\PracticeAppDev\api",
  [string]$BackupDir  = "C:\sites\PracticeAppDev\api_prev",
  [string]$HealthUrl  = "http://localhost:8080/health",
  [string]$AppPoolName = $null
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

# Pre-flight: artifact present?
if (-not (Test-Path $ArtifactDir) -or ((Get-ChildItem $ArtifactDir -Recurse -File | Measure).Count -eq 0)) {
  throw "ArtifactDir '$ArtifactDir' is missing or empty. Did the build upload the publish output as 'api-publish'?"
}

# Discover App Pool from Site if not provided
if (-not $AppPoolName) {
  $AppPoolName = (Get-Item "IIS:\Sites\$SiteName").applicationPool
  if (-not $AppPoolName) { throw "Could not resolve AppPool for site '$SiteName'." }
}

Write-Host "Stopping site '$SiteName' and app pool '$AppPoolName'..."
Stop-Website   -Name $SiteName   -ErrorAction SilentlyContinue
Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue

# Wait until the app pool is fully stopped (releases file locks)
$retries = 30
while ($retries-- -gt 0) {
  $state = (Get-WebAppPoolState $AppPoolName).Value
  if ($state -eq 'Stopped') { break }
  Start-Sleep -Seconds 1
}
if ((Get-WebAppPoolState $AppPoolName).Value -ne 'Stopped') {
  throw "AppPool '$AppPoolName' did not stop; cannot proceed with swap."
}

# Backup current, deploy new
Write-Host "Swapping '$TargetDir' -> '$BackupDir' and copying new files..."
if (Test-Path $BackupDir) { Remove-Item $BackupDir -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $TargetDir) { Rename-Item $TargetDir $BackupDir -Force }
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
Copy-Item -Path (Join-Path $ArtifactDir '*') -Destination $TargetDir -Recurse

# Start and verify
Write-Host "Starting app pool and site, then health check..."
Start-WebAppPool -Name $AppPoolName
Start-Website    -Name $SiteName

$ok = $false
for ($i=0; $i -lt 10; $i++) {
  try {
    $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 10
    if ($resp.StatusCode -eq 200) { $ok = $true; break }
  } catch { }
  Start-Sleep -Seconds 2
}

if ($ok) {
  Write-Host "Health OK. Cleaning backup."
  if (Test-Path $BackupDir) { Remove-Item $BackupDir -Recurse -Force }
} else {
  Write-Warning "Health check failed. Rolling back..."
  Stop-Website   -Name $SiteName   -ErrorAction SilentlyContinue
  Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue

  if (Test-Path $TargetDir) { Remove-Item $TargetDir -Recurse -Force }
  if (Test-Path $BackupDir) { Rename-Item $BackupDir $TargetDir -Force }

  Start-WebAppPool -Name $AppPoolName
  Start-Website    -Name $SiteName
  throw "Rollback complete due to failed health check."
}
