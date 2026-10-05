$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $projectRoot "server.ps1"
$portListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$portListener.Start()
$port = $portListener.LocalEndpoint.Port
$portListener.Stop()

$logId = [Guid]::NewGuid().ToString("N")
$stdoutPath = Join-Path $env:TEMP "v2-smoke-$logId.out.log"
$stderrPath = Join-Path $env:TEMP "v2-smoke-$logId.err.log"
$serverProcess = $null

try {
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`" -Port $port"
  $serverProcess = Start-Process `
    -FilePath (Get-Process -Id $PID).Path `
    -ArgumentList $arguments `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath

  $baseUrl = "http://localhost:$port"
  $health = $null
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    if ($serverProcess.HasExited) {
      $serverError = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
      throw "Server exited before becoming healthy. $serverError"
    }
    try {
      $health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 1
      break
    }
    catch {
      Start-Sleep -Milliseconds 300
    }
  }

  if ($null -eq $health -or $health.status -ne "ok") {
    throw "Health check failed at $baseUrl/health."
  }

  $page = Invoke-WebRequest -Uri "$baseUrl/" -TimeoutSec 5 -UseBasicParsing
  if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'assistant-config\.js') {
    throw "The home page did not serve the shared assistant configuration."
  }

  $assistantConfig = Invoke-WebRequest -Uri "$baseUrl/assistant-config.js" -TimeoutSec 5 -UseBasicParsing
  if ($assistantConfig.StatusCode -ne 200 -or $assistantConfig.Content -notmatch 'FOMO_API_BASE_URL') {
    throw "The assistant configuration file was not served."
  }

  Write-Output "Smoke test passed: health endpoint, application page and shared assistant configuration."
}
finally {
  if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
    Stop-Process -Id $serverProcess.Id
    $serverProcess.WaitForExit()
  }
  if ($null -ne $serverProcess) {
    $serverProcess.Dispose()
  }
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
}
