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
  if (
    $page.StatusCode -ne 200 -or
    $page.Content -notmatch 'assistant-config\.js' -or
    $page.Content -notmatch 'rel="icon" type="image/jpeg"' -or
    $page.Content -notmatch 'class="brand-logo" src="\./fomo-logo\.jpeg'
  ) {
    throw "The home page did not serve the expected shared configuration and FOMO logo references."
  }

  $logo = Invoke-WebRequest -Uri "$baseUrl/fomo-logo.jpeg" -TimeoutSec 5 -UseBasicParsing
  if ($logo.StatusCode -ne 200 -or $logo.Headers["Content-Type"] -ne "image/jpeg" -or $logo.RawContentLength -lt 1000) {
    throw "The FOMO logo image was not served as a JPEG."
  }

  $appStyles = Invoke-WebRequest -Uri "$baseUrl/styles.css?logo-smoke-test" -TimeoutSec 5 -UseBasicParsing
  if ($appStyles.StatusCode -ne 200 -or $appStyles.Content -notmatch '\.brand-logo') {
    throw "The FOMO logo styles were not served."
  }

  $assistantConfig = Invoke-WebRequest -Uri "$baseUrl/assistant-config.js" -TimeoutSec 5 -UseBasicParsing
  if ($assistantConfig.StatusCode -ne 200 -or $assistantConfig.Content -notmatch 'FOMO_API_BASE_URL') {
    throw "The assistant configuration file was not served."
  }

  $navigationCss = Invoke-WebRequest -Uri "$baseUrl/buttons-ui/buttons-ui.css" -TimeoutSec 5 -UseBasicParsing
  if ($navigationCss.StatusCode -ne 200 -or $navigationCss.Content -notmatch '\.bottom-navigation') {
    throw "The bottom navigation stylesheet was not served."
  }

  $navigationScript = Invoke-WebRequest -Uri "$baseUrl/buttons-ui/buttons-ui.js" -TimeoutSec 5 -UseBasicParsing
  if ($navigationScript.StatusCode -ne 200 -or $navigationScript.Content -notmatch 'setNavigationView') {
    throw "The bottom navigation script was not served."
  }

  Write-Output "Smoke test passed: health endpoint, app page, FOMO logo and favicon, assistant configuration and bottom navigation assets."
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
