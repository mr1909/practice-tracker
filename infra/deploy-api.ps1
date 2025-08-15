param(
  [Parameter(Mandatory=$true)][string]$ArtifactDir = "C:\actions\api-publish",
  [string]$SiteName = "PracticeAppDev",
  [string]$TargetDir = "C:\sites\PracticeAppDev\api",
  [string]$BackupDir = "C:\sites\PracticeAppDev\api_prev",
  [string]$HealthUrl = "http://localhost:8080/health"
)

if (-not (Test-Path $ArtifactDir) -or ((Get-ChildItem $ArtifactDir -Recurse -File | Measure).Count -eq 0)) {
  throw "ArtifactDir '$ArtifactDir' is missing or empty. Did the build upload 'api-publish'?"
}

Write-Host "Stopping site $SiteName..."
Import-Module WebAdministration
Stop-Website -Name $SiteName -ErrorAction SilentlyContinue

if (Test-Path $BackupDir) { Remove-Item $BackupDir -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $TargetDir) { Rename-Item $TargetDir $BackupDir }

New-Item -ItemType Directory -Path $TargetDir | Out-Null
Copy-Item -Path (Join-Path $ArtifactDir "*") -Destination $TargetDir -Recurse

Start-Website -Name $SiteName

Start-Sleep -Seconds 3
try {
  $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 10
  if ($resp.StatusCode -ne 200) { throw "Health returned $($resp.StatusCode)" }
  Write-Host "Health OK."
  if (Test-Path $BackupDir) { Remove-Item $BackupDir -Recurse -Force }
}
catch {
  Write-Warning "Health check failed: $($_.Exception.Message). Rolling back..."
  Stop-Website -Name $SiteName
  if (Test-Path $TargetDir) { Remove-Item $TargetDir -Recurse -Force }
  Rename-Item $BackupDir $TargetDir
  Start-Website -Name $SiteName
  throw "Rollback complete due to failed health check."
}
