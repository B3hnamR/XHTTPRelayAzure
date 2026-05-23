param(
  [string]$ResourceGroup = "",
  [string]$AppName = "",
  [string]$Location = "westeurope",
  [string]$PlanName = "",
  [string]$Sku = "B1",
  [string]$NodeRuntime = "NODE:22-lts",
  [string]$SubscriptionId = "",
  [string]$TargetDomain = "",
  [string]$RelayPath = "",
  [string]$PublicRelayPath = "",
  [string]$RelayKey = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:PYTHONWARNINGS = "ignore:You are using cryptography on a 32-bit Python.*:UserWarning"
$script:DebugLogPath = ""
$script:TranscriptLogPath = ""
$script:TranscriptStarted = $false
$script:AzureCliMsiFallbackSizeBytes = 65840087

trap {
  $message = [string]$_.Exception.Message
  try { Write-DebugLog ("FAILED: {0}`n{1}" -f $message, ($_ | Out-String)) } catch {}
  Write-Host ""
  Write-Host ("Action failed: {0}" -f $message) -ForegroundColor Red
  if ($message -match "(?i)Azure throttled|operation is throttled|too many requests") {
    Write-Host ""
    Write-Host "Azure throttling guidance" -ForegroundColor Yellow
    Write-Host "  Azure temporarily blocked this create/update request for your subscription." -ForegroundColor Cyan
    Write-Host "  This usually happens after several App Service Plan create attempts in a short time." -ForegroundColor Cyan
    Write-Host "  Microsoft guidance: wait for the Retry-After value when Azure returns one." -ForegroundColor Cyan
    Write-Host "  In this Azure CLI error, Retry-After was not exposed, so there is no exact official wait time in the output." -ForegroundColor Cyan
    Write-Host "  Practical next step: wait a few minutes, then rerun and reuse an existing App Service Plan instead of creating a new one." -ForegroundColor Cyan
    Write-Host "  Official doc: https://learn.microsoft.com/azure/azure-resource-manager/management/request-limits-and-throttling" -ForegroundColor DarkGray
  }
  if ($message -match "(?i)additional quota|Basic VMs|quota is 0|without additional quota") {
    Write-Host ""
    Write-Host "Azure quota guidance" -ForegroundColor Yellow
    Write-Host "  This subscription/region has no available quota for the selected App Service plan family." -ForegroundColor Cyan
    Write-Host "  Try another region first, for example westeurope, uksouth, or northeurope." -ForegroundColor Cyan
    Write-Host "  If every region fails, request quota increase for Basic VMs/App Service, upgrade the subscription, or reuse an existing App Service Plan." -ForegroundColor Cyan
  }
  if ($message -match "(?i)did not start|failed to start|worker.*start|ZIP deployment") {
    Write-Host ""
    Write-Host "App startup guidance" -ForegroundColor Yellow
    Write-Host "  Azure received the ZIP, but the Node app did not become healthy in time." -ForegroundColor Cyan
    Write-Host "  Check that TARGET_DOMAIN starts with https:// or http:// and includes the upstream port." -ForegroundColor Cyan
    Write-Host "  If NODE:22-lts is not available in the selected region, rerun Custom Build and try NODE:20-lts." -ForegroundColor Cyan
    Write-Host "  The debug log contains the Azure/Kudu log URL when Azure returns one." -ForegroundColor Cyan
  }
  if (-not [string]::IsNullOrWhiteSpace($script:DebugLogPath)) {
    Write-Host ("Debug log: {0}" -f $script:DebugLogPath) -ForegroundColor Yellow
  }
  if ($script:TranscriptStarted) {
    try { Stop-Transcript | Out-Null } catch {}
    $script:TranscriptStarted = $false
  }
  exit 1
}

function Write-DebugLog([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($script:DebugLogPath)) { return }
  $safeText = Redact-DebugText -Text $Text
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $safeText
  try {
    Add-Content -LiteralPath $script:DebugLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch {}
}

function Redact-DebugText([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
  $safe = [string]$Text
  $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b', '<email>')
  $safe = [regex]::Replace($safe, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<guid>')
  $safe = [regex]::Replace($safe, '(?i)(TARGET_DOMAIN=)(\S+)', '$1<redacted>')
  $safe = [regex]::Replace($safe, '(?i)(RELAY_KEY=)(\S*)', '$1<redacted>')
  $safe = [regex]::Replace($safe, '(?i)(enter the code\s+)[A-Z0-9]+', '$1<redacted>')
  $safe = [regex]::Replace($safe, 'C:\\Users\\[^\\\s]+', 'C:\Users\<user>')
  return $safe
}

function Read-Default([string]$Prompt, [string]$DefaultValue) {
  $raw = Read-Host "$Prompt [$DefaultValue]"
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  return $raw.Trim()
}

function Read-Required([string]$Prompt, [string]$CurrentValue = "") {
  $value = $CurrentValue
  while ([string]::IsNullOrWhiteSpace($value)) {
    $value = Read-Host $Prompt
    if ($null -ne $value) { $value = $value.Trim() }
  }
  return $value
}

function Read-OptionalInt([string]$Prompt, [int]$DefaultValue, [int]$MinValue) {
  while ($true) {
    $raw = Read-Host "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
    $n = 0
    if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge $MinValue) { return $n }
    Write-Host ("Enter a number greater than or equal to {0}." -f $MinValue) -ForegroundColor Red
  }
}

function Test-CommandAvailable([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Normalize-PathLike([string]$Value) {
  $v = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($v)) { return "/api" }
  if (-not $v.StartsWith("/")) { $v = "/$v" }
  if ($v.Length -gt 1 -and $v.EndsWith("/")) { $v = $v.TrimEnd("/") }
  return $v
}

function Normalize-TargetDomain([string]$Value) {
  $v = ([string]$Value).Trim().TrimEnd("/")
  if ([string]::IsNullOrWhiteSpace($v)) { throw "TARGET_DOMAIN is required." }
  if ($v -notmatch '^https?://') {
    throw "TARGET_DOMAIN must start with https:// or http:// and include the upstream inbound host/port. Example: https://your-domain.com:443"
  }
  try {
    $uri = [uri]$v
    if ([string]::IsNullOrWhiteSpace($uri.Host)) { throw "missing host" }
    if ($uri.IsDefaultPort) {
      Write-Host "Warning: TARGET_DOMAIN has no explicit port. If your inbound uses a custom port, include it like :2053." -ForegroundColor Yellow
    }
  } catch {
    throw "TARGET_DOMAIN is not a valid URL. Example: https://your-domain.com:443"
  }
  if ($v -match '^http://') {
    Write-Host "Warning: TARGET_DOMAIN uses http://. If your inbound uses TLS, use https:// to avoid SSL/client test failures." -ForegroundColor Yellow
  }
  return $v
}

function New-RandomName([string]$Prefix) {
  $chars = "abcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
  $suffix = ""
  for ($i = 0; $i -lt 8; $i++) { $suffix += $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] }
  return "$Prefix-$suffix"
}

function Start-DebugLogging([string]$ProjectRoot) {
  $script:DebugLogPath = Join-Path $ProjectRoot ("azure-deploy-debug-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
  $script:TranscriptLogPath = ""
  $script:TranscriptStarted = $false
  Write-DebugLog "Debug log started."
  Write-DebugLog ("PowerShell: {0}" -f $PSVersionTable.PSVersion)
  Write-DebugLog ("Windows: {0}" -f [System.Environment]::OSVersion.VersionString)
  Write-Host ("Debug log: {0}" -f $script:DebugLogPath) -ForegroundColor DarkGray
}

function Test-IsAdministrator {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Refresh-CurrentProcessPath {
  try {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    foreach ($p in @($machinePath, $userPath, $env:PATH)) {
      if (-not [string]::IsNullOrWhiteSpace($p)) { $parts += ($p -split ';') }
    }
    $unique = @($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $env:PATH = ($unique -join ';')
  } catch {}
  Add-AzureCliToCurrentPath
}

function Add-AzureCliToCurrentPath {
  $candidates = @(
    "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin",
    "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
  )
  foreach ($base in @("C:\Program Files\Microsoft SDKs\Azure\CLI2", "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2")) {
    try {
      $azCmd = Get-ChildItem -LiteralPath $base -Filter "az.cmd" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -ne $azCmd) { $candidates += [string]$azCmd.DirectoryName }
    } catch {}
  }
  foreach ($path in $candidates) {
    if ((Test-Path $path) -and (($env:PATH -split ';') -notcontains $path)) {
      $env:PATH = "$path;$env:PATH"
    }
  }
}

function Test-AzureCliAvailable {
  Refresh-CurrentProcessPath
  return [bool](Get-Command az -ErrorAction SilentlyContinue)
}

function Write-InPlace([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
  $width = 100
  try { $width = [Math]::Max(40, [Console]::WindowWidth - 1) } catch {}
  $out = $Text
  if ($out.Length -gt $width) { $out = $out.Substring(0, $width) }
  $out = $out.PadRight($width)
  Write-Host "`r$out" -NoNewline -ForegroundColor $Color
}

function Complete-InPlace([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
  Write-InPlace -Text $Text -Color $Color
  Write-Host ""
}

function Write-Section([string]$Text) {
  Write-Host ""
  Write-Host ("== {0}" -f $Text) -ForegroundColor Yellow
}

function Write-StepDone([string]$Label, [string]$Detail = "") {
  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host ("  OK  {0}" -f $Label) -ForegroundColor Green
  } else {
    Write-Host ("  OK  {0}: {1}" -f $Label, $Detail) -ForegroundColor Green
  }
}

function Write-SummaryRow([string]$Name, [string]$Value) {
  Write-Host ("  {0,-18} {1}" -f $Name, $Value)
}

function Format-Bytes([double]$Bytes) {
  if ($Bytes -ge 1GB) { return ("{0:0.00} GB" -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ("{0:0.00} MB" -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ("{0:0.00} KB" -f ($Bytes / 1KB)) }
  return ("{0:0} B" -f $Bytes)
}

function Get-AzureThrottleRetryDelaySeconds([string]$Text, [int]$Attempt) {
  if ($Text -match "(?i)retry-after[^0-9]*(\d+)") {
    $retryAfter = [int]$Matches[1]
    if ($retryAfter -gt 0) { return [Math]::Min($retryAfter, 300) }
  }

  $fallback = @(30, 60, 120)
  $index = [Math]::Min([Math]::Max($Attempt - 1, 0), $fallback.Count - 1)
  return $fallback[$index]
}

function Test-AzTransientNetworkError([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return ($Text -match "(?i)ConnectionResetError|WinError 10054|Connection aborted|ProtocolError|requests\.exceptions\.ConnectionError|RemoteDisconnected|Read timed out|temporarily unavailable|TLS/SSL connection has been closed")
}

function Get-MsiExitMessage([int]$Code) {
  switch ($Code) {
    0 { return "Success" }
    1602 { return "Installation was cancelled by the user." }
    1603 { return "Fatal MSI installation error. Try running the installer as Administrator, or install Azure CLI manually." }
    1618 { return "Another MSI installation is already running. Wait for it to finish, then retry." }
    1638 { return "Another version is already installed. Open a new terminal and run the deploy script again." }
    3010 { return "Installation succeeded, but Windows requests a restart." }
    default { return "MSI installer failed with exit code $Code." }
  }
}

function Resolve-RedirectUrl([string]$Url) {
  try {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "HEAD"
    $request.AllowAutoRedirect = $false
    $request.Timeout = 15000
    $response = $request.GetResponse()
    try {
      $location = [string]$response.Headers["Location"]
      if (-not [string]::IsNullOrWhiteSpace($location)) {
        if ($location.StartsWith("http", [System.StringComparison]::OrdinalIgnoreCase)) { return $location }
        $baseUri = [uri]$Url
        return ([uri]::new($baseUri, $location)).AbsoluteUri
      }
    } finally {
      $response.Dispose()
    }
  } catch {}
  return $Url
}

function Download-FileWithProgress([string]$Url, [string]$OutFile) {
  Add-Type -AssemblyName System.Net.Http
  $downloadUrl = Resolve-RedirectUrl -Url $Url
  Write-DebugLog ("Download URL: {0}" -f $downloadUrl)
  $expectedTotal = 0.0
  if ($downloadUrl -match 'azure-cli-(?<version>[0-9.]+)-x64\.msi') {
    try {
      $headReq = [System.Net.HttpWebRequest]::Create($downloadUrl)
      $headReq.Method = "HEAD"
      $headReq.AllowAutoRedirect = $true
      $headReq.Timeout = 15000
      $headResp = $headReq.GetResponse()
      try {
        if ($headResp.ContentLength -gt 0) { $expectedTotal = [double]$headResp.ContentLength }
      } finally {
        $headResp.Dispose()
      }
    } catch {}
  }
  $client = [System.Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromMinutes(10)
  $response = $null
  $inputStream = $null
  $outputStream = $null
  try {
    $response = $client.GetAsync($downloadUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    $total = 0.0
    if ($response.Content.Headers.ContentLength.HasValue) {
      $total = [double]$response.Content.Headers.ContentLength.Value
    } elseif ($expectedTotal -gt 0) {
      $total = $expectedTotal
    } elseif ($downloadUrl -match 'azure-cli-|installazurecliwindows') {
      $total = [double]$script:AzureCliMsiFallbackSizeBytes
      Write-DebugLog ("Using Azure CLI MSI fallback size: {0}" -f $total)
    }
    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $outputStream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $buffer = New-Object byte[] 1048576
    $readTotal = 0.0
    $lastPct = -1
    while ($true) {
      $read = $inputStream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      $outputStream.Write($buffer, 0, $read)
      $readTotal += $read
      if ($total -gt 0) {
        $pct = [int][Math]::Floor(($readTotal / $total) * 100)
        if ($pct -ne $lastPct) {
          $lastPct = $pct
          Write-InPlace -Text ("Downloading Azure CLI installer... {0}% ({1}/{2})" -f $pct, (Format-Bytes $readTotal), (Format-Bytes $total)) -Color DarkCyan
        }
      } else {
        Write-InPlace -Text ("Downloading Azure CLI installer... {0} downloaded (total size unknown)" -f (Format-Bytes $readTotal)) -Color DarkCyan
      }
    }
    if ($total -gt 0) {
      Complete-InPlace -Text ("Downloading Azure CLI installer... 100% ({0}/{1})" -f (Format-Bytes $readTotal), (Format-Bytes $total)) -Color Green
    } else {
      Complete-InPlace -Text ("Downloading Azure CLI installer... complete ({0})" -f (Format-Bytes $readTotal)) -Color Green
    }
  } finally {
    if ($null -ne $outputStream) { $outputStream.Dispose() }
    if ($null -ne $inputStream) { $inputStream.Dispose() }
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
  }
}

function Wait-ProcessWithSpinner([System.Diagnostics.Process]$Process, [string]$Label) {
  $frames = @("|", "/", "-", "\")
  $i = 0
  $started = Get-Date
  while (-not $Process.HasExited) {
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    $frame = $frames[$i % $frames.Count]
    Write-InPlace -Text ("{0} {1} elapsed {2}s" -f $frame, $Label, $elapsed) -Color DarkCyan
    Start-Sleep -Milliseconds 150
    $i++
    try { $Process.Refresh() } catch {}
  }
  Complete-InPlace -Text ("Done: {0}" -f $Label) -Color Green
}

function Install-AzureCliWithMsi {
  Write-Host ""
  Write-Host ">> Installing Azure CLI with official MSI..." -ForegroundColor Yellow
  $msiPath = Join-Path $env:TEMP "AzureCLI.msi"
  $logRoot = $env:TEMP
  if (-not [string]::IsNullOrWhiteSpace($script:DebugLogPath)) {
    $logRoot = Split-Path -Parent $script:DebugLogPath
  }
  $msiLogPath = Join-Path $logRoot ("azure-cli-msi-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
  try {
    Write-DebugLog "Azure CLI MSI install started."
    Download-FileWithProgress -Url "https://aka.ms/installazurecliwindows" -OutFile $msiPath
    Write-DebugLog ("MSI path: {0}" -f $msiPath)
    Write-DebugLog ("MSI log path: {0}" -f $msiLogPath)
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/I", $msiPath, "/quiet", "/norestart", "/L*v", $msiLogPath) -PassThru
    Wait-ProcessWithSpinner -Process $process -Label "Installing Azure CLI silently. This may take 1-3 minutes..."
    $exitCode = [int]$process.ExitCode
    Write-DebugLog ("msiexec non-elevated exit code: {0}" -f $exitCode)

    if (($exitCode -ne 0 -and $exitCode -ne 3010) -and (Test-AzureCliAvailable)) {
      Write-Host "Azure CLI is available despite MSI exit code. Continuing." -ForegroundColor Yellow
      Write-DebugLog "Azure CLI became available despite MSI non-zero exit."
      return
    }

    if ($exitCode -eq 1603 -and -not (Test-IsAdministrator)) {
      Write-Host ""
      Write-Host "The silent MSI install needs Administrator permission on this system." -ForegroundColor Yellow
      Write-Host "A Windows UAC prompt will open. Choose Yes, then this installer will continue here." -ForegroundColor Cyan
      $elevate = Read-Default "Run Azure CLI installer as Administrator now? (Y/n)" "y"
      if ($elevate.Trim().ToLowerInvariant() -ne "n") {
        Write-DebugLog "Retrying MSI install elevated through UAC."
        $elevatedProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/I", $msiPath, "/quiet", "/norestart", "/L*v", $msiLogPath) -Verb RunAs -Wait -PassThru
        $exitCode = [int]$elevatedProcess.ExitCode
        Write-DebugLog ("msiexec elevated exit code: {0}" -f $exitCode)
      }
    }

    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
      Write-DebugLog ("Azure CLI MSI failed. MSI log: {0}" -f $msiLogPath)
      throw (Get-MsiExitMessage -Code $exitCode)
    }
    if ($exitCode -eq 3010) {
      Write-Host "Azure CLI installed. Windows may require restart later." -ForegroundColor Yellow
      Write-DebugLog "Azure CLI MSI returned 3010."
    }
  } finally {
    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
  }

  if (Test-AzureCliAvailable) {
    Write-Host "Azure CLI installed." -ForegroundColor Green
    Write-DebugLog "Azure CLI available after install."
    return
  }

  Write-Host "Azure CLI install finished, but this terminal still cannot find az." -ForegroundColor Yellow
  Write-Host "The script refreshed PATH automatically. If this repeats, open a new terminal and run again." -ForegroundColor Yellow
  Write-DebugLog "Azure CLI not found after PATH refresh."
  throw "Azure CLI was installed but az.cmd was not found in PATH."
}

function Ensure-AzureCliInstalled {
  if (Test-AzureCliAvailable) { return }

  Write-Host "Azure CLI is not installed." -ForegroundColor Yellow
  Write-Host "This installer can install the official Microsoft Azure CLI silently." -ForegroundColor Cyan
  Write-Host ""

  $msiInstall = Read-Default "Install Azure CLI now? (Y/n)" "y"
  if ($msiInstall.Trim().ToLowerInvariant() -ne "n") {
    Install-AzureCliWithMsi
    return
  }

  Write-Host ""
  Write-Host "Manual install: https://aka.ms/installazurecliwindows" -ForegroundColor Yellow
  throw "Azure CLI is required before deploy."
}

function Ensure-NodeBuildRuntime {
  Refresh-CurrentProcessPath
  if (Test-CommandAvailable "node") { return }

  Write-Host ""
  Write-Host "Node.js LTS is required to generate the static frontend before deploy." -ForegroundColor Yellow
  Write-Host "This installer can try to install Node.js LTS with winget." -ForegroundColor Cyan

  if (Test-CommandAvailable "winget") {
    $installNode = Read-Default "Install Node.js LTS now? (Y/n)" "y"
    if ($installNode.Trim().ToLowerInvariant() -ne "n") {
      Write-Host ""
      Write-Host ">> Installing Node.js LTS with winget..." -ForegroundColor Yellow
      Write-DebugLog "Node.js LTS winget install started."
      $oldErrorActionPreference = $ErrorActionPreference
      $output = @()
      $exitCode = 1
      try {
        $ErrorActionPreference = "Continue"
        $output = & winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements 2>&1
        $exitCode = $LASTEXITCODE
      } finally {
        $ErrorActionPreference = $oldErrorActionPreference
      }
      if (-not [string]::IsNullOrWhiteSpace(($output -join "`n"))) {
        Write-DebugLog ("winget Node.js output: {0}" -f (($output | ForEach-Object { [string]$_ }) -join "`n").Trim())
      }
      if ($exitCode -ne 0) {
        throw "Node.js LTS install failed. Install it manually from https://nodejs.org/en/download and rerun this installer."
      }
      Refresh-CurrentProcessPath
      if (Test-CommandAvailable "node") {
        Write-Host "Node.js LTS installed." -ForegroundColor Green
        return
      }
      Write-Host "Node.js install finished, but this terminal still cannot find node.exe." -ForegroundColor Yellow
      Write-Host "Open a new terminal and run this installer again." -ForegroundColor Yellow
      throw "Node.js LTS was installed but node.exe was not found in PATH."
    }
  } else {
    Write-Host "winget was not found on this Windows system." -ForegroundColor Yellow
  }

  Write-Host ""
  Write-Host "Manual install: https://nodejs.org/en/download" -ForegroundColor Yellow
  throw "Node.js LTS is required before deploy. Install Node.js, open a new terminal, and run this installer again."
}

function Get-UpstreamHostFromDomain([string]$TargetDomain) {
  if ([string]::IsNullOrWhiteSpace($TargetDomain)) { return "" }
  $raw = $TargetDomain.Trim()
  try {
    $u = [uri]$raw
    if ($null -ne $u -and -not [string]::IsNullOrWhiteSpace($u.Host)) { return $u.Host }
  } catch {}
  try {
    if (-not ($raw -match '^[a-zA-Z][a-zA-Z0-9+\-.]*://')) {
      $u2 = [uri]("https://$raw")
      if ($null -ne $u2 -and -not [string]::IsNullOrWhiteSpace($u2.Host)) { return $u2.Host }
    }
  } catch {}
  return ""
}

function Add-UniqueString([System.Collections.Generic.List[string]]$List, [string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return }
  $v = $Value.Trim()
  if (-not $List.Contains($v)) { [void]$List.Add($v) }
}

function Get-UpstreamIpv4Candidates([string]$HostName) {
  $result = [ordered]@{
    Local = @()
    Public = @()
    All = @()
  }
  if ([string]::IsNullOrWhiteSpace($HostName)) { return $result }

  $local = New-Object System.Collections.Generic.List[string]
  $public = New-Object System.Collections.Generic.List[string]
  $all = New-Object System.Collections.Generic.List[string]

  try {
    $ips = [System.Net.Dns]::GetHostAddresses($HostName)
    foreach ($ip in $ips) {
      if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        Add-UniqueString -List $local -Value ([string]$ip.IPAddressToString)
        Add-UniqueString -List $all -Value ([string]$ip.IPAddressToString)
      }
    }
  } catch {}

  foreach ($dns in @("1.1.1.1", "8.8.8.8", "9.9.9.9")) {
    try {
      $records = Resolve-DnsName -Name $HostName -Type A -Server $dns -ErrorAction Stop
      foreach ($r in $records) {
        if ($null -ne $r.IPAddress -and -not [string]::IsNullOrWhiteSpace([string]$r.IPAddress)) {
          Add-UniqueString -List $public -Value ([string]$r.IPAddress)
          Add-UniqueString -List $all -Value ([string]$r.IPAddress)
        }
      }
    } catch {}
  }

  $result.Local = @($local.ToArray())
  $result.Public = @($public.ToArray())
  $result.All = @($all.ToArray())
  return $result
}

function Try-ResolveCountryFromIp([string]$IpAddress) {
  if ([string]::IsNullOrWhiteSpace($IpAddress)) { return "" }
  try {
    $resp = Invoke-RestMethod -Method Get -Uri "https://ipwho.is/$IpAddress" -TimeoutSec 7
    if ($null -ne $resp -and $resp.success -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$resp.country)) {
      return [string]$resp.country
    }
  } catch {}
  return ""
}

function Get-AzureRegionCatalog {
  return @(
    [pscustomobject]@{ Code = "westeurope"; Label = "West Europe - Netherlands"; Bias = "Best default for Iran + Europe upstream" },
    [pscustomobject]@{ Code = "germanywestcentral"; Label = "Germany West Central - Frankfurt area"; Bias = "Good for Germany/Central Europe upstream" },
    [pscustomobject]@{ Code = "francecentral"; Label = "France Central - Paris"; Bias = "Good for France/West Europe upstream" },
    [pscustomobject]@{ Code = "swedencentral"; Label = "Sweden Central"; Bias = "Good for North Europe/Sweden upstream" },
    [pscustomobject]@{ Code = "northeurope"; Label = "North Europe - Ireland"; Bias = "Good fallback for Europe" },
    [pscustomobject]@{ Code = "uksouth"; Label = "UK South - London"; Bias = "Good for UK upstream" },
    [pscustomobject]@{ Code = "switzerlandnorth"; Label = "Switzerland North"; Bias = "Good for Switzerland/Alps upstream" },
    [pscustomobject]@{ Code = "italynorth"; Label = "Italy North"; Bias = "Good for Italy/South Europe upstream" },
    [pscustomobject]@{ Code = "polandcentral"; Label = "Poland Central"; Bias = "Good for Eastern Europe upstream" },
    [pscustomobject]@{ Code = "uaenorth"; Label = "UAE North - Dubai"; Bias = "Good candidate for Persian Gulf routing" },
    [pscustomobject]@{ Code = "qatarcentral"; Label = "Qatar Central"; Bias = "Good candidate for Gulf/Qatar upstream" },
    [pscustomobject]@{ Code = "centralindia"; Label = "Central India"; Bias = "Good for India/Pakistan upstream" }
  )
}

function Get-RecommendedAzureRegions([string]$CountryName) {
  $c = ([string]$CountryName).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($c)) {
    return @("westeurope", "germanywestcentral", "uaenorth")
  }
  if ($c -match "germany|austria|czech|hungary|slovakia|slovenia") { return @("germanywestcentral", "westeurope", "francecentral") }
  if ($c -match "france|spain|portugal|belgium|netherlands|luxembourg") { return @("westeurope", "francecentral", "germanywestcentral") }
  if ($c -match "united kingdom|ireland") { return @("uksouth", "northeurope", "westeurope") }
  if ($c -match "sweden|norway|finland|denmark") { return @("swedencentral", "northeurope", "westeurope") }
  if ($c -match "switzerland") { return @("switzerlandnorth", "germanywestcentral", "westeurope") }
  if ($c -match "italy|greece|cyprus") { return @("italynorth", "westeurope", "germanywestcentral") }
  if ($c -match "poland|romania|bulgaria|ukraine|lithuania|latvia|estonia") { return @("polandcentral", "germanywestcentral", "westeurope") }
  if ($c -match "united arab emirates|uae|emirates|qatar|saudi|bahrain|kuwait|oman") { return @("uaenorth", "qatarcentral", "westeurope") }
  if ($c -match "india|pakistan|bangladesh|sri lanka") { return @("centralindia", "uaenorth", "westeurope") }
  if ($c -match "iran|turkey|iraq|armenia|azerbaijan|georgia") { return @("westeurope", "uaenorth", "germanywestcentral") }
  return @("westeurope", "germanywestcentral", "uaenorth")
}

function Choose-AzureLocation([string]$TargetDomain, [string]$CurrentDefault) {
  $catalog = @(Get-AzureRegionCatalog)
  $hostName = Get-UpstreamHostFromDomain -TargetDomain $TargetDomain
  $country = ""
  $hintIp = ""

  if (-not [string]::IsNullOrWhiteSpace($hostName)) {
    Write-Host ""
    Write-Host ("Auto region hint: resolving TARGET_DOMAIN host '{0}'..." -f $hostName) -ForegroundColor DarkCyan
    $resolved = Get-UpstreamIpv4Candidates -HostName $hostName
    $allIps = @($resolved.All)
    $publicIps = @($resolved.Public)
    if ($allIps.Count -gt 0) {
      Write-Host ("DNS A records: {0}" -f ($allIps -join ", ")) -ForegroundColor DarkGray
      if ($publicIps.Count -gt 0) { $hintIp = [string]$publicIps[0] } else { $hintIp = [string]$allIps[0] }
      $country = Try-ResolveCountryFromIp -IpAddress $hintIp
      if (-not [string]::IsNullOrWhiteSpace($country)) {
        Write-Host ("Upstream IP hint: {0} => {1}" -f $hintIp, $country) -ForegroundColor DarkCyan
      }
    } else {
      Write-Host "DNS hint failed. Falling back to Iran-friendly defaults." -ForegroundColor DarkYellow
    }
  }

  $recommended = @(Get-RecommendedAzureRegions -CountryName $country)
  if (-not [string]::IsNullOrWhiteSpace($CurrentDefault) -and $recommended -notcontains $CurrentDefault) {
    $recommended += $CurrentDefault
  }
  foreach ($r in @("westeurope", "germanywestcentral", "uaenorth")) {
    if ($recommended -notcontains $r) { $recommended += $r }
  }

  Write-Host ""
  Write-Host "Choose Azure region. For Iranian users, start with West Europe/Germany/UAE and benchmark after deploy." -ForegroundColor Cyan
  $menu = New-Object System.Collections.Generic.List[object]
  foreach ($code in $recommended) {
    $match = $catalog | Where-Object { $_.Code -eq $code } | Select-Object -First 1
    if ($null -ne $match) { $menu.Add($match) }
  }
  foreach ($item in $catalog) {
    if (-not ($menu | Where-Object { $_.Code -eq $item.Code })) { $menu.Add($item) }
  }

  for ($i = 0; $i -lt $menu.Count; $i++) {
    $item = $menu[$i]
    $tag = if ($i -lt 3) { " (recommended)" } else { "" }
    Write-Host ("[{0}] {1} - {2}{3}" -f ($i + 1), $item.Code, $item.Label, $tag)
    Write-Host ("    {0}" -f $item.Bias) -ForegroundColor DarkGray
  }
  Write-Host "[C] Custom Azure region code"

  while ($true) {
    $pick = Read-Default "Select Azure region" "1"
    if ($pick.Trim().ToLowerInvariant() -eq "c") {
      $custom = Read-Required "Custom region code, example: westeurope"
      return $custom.Trim().ToLowerInvariant()
    }
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $menu.Count) {
      return [string]$menu[$n - 1].Code
    }
    Write-Host "Invalid selection." -ForegroundColor Red
  }
}

function Invoke-AzureDeviceLogin {
  $maxAttempts = 2
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    if ($attempt -gt 1) {
      Write-Host ""
      Write-Host ("Azure login retry {0}/{1}" -f $attempt, $maxAttempts) -ForegroundColor Yellow
      Write-Host "If the previous code expired or was not completed, use the new code shown below." -ForegroundColor Cyan
    }

    Write-DebugLog ("Running az login --use-device-code attempt {0}/{1}." -f $attempt, $maxAttempts)
    $oldErrorActionPreference = $ErrorActionPreference
    $loginOutput = @()
    $loginExitCode = 1
    try {
      $ErrorActionPreference = "Continue"
      Remove-Variable -Name capturedLoginOutput -ErrorAction SilentlyContinue
      & az login --use-device-code --output none 2>&1 | Tee-Object -Variable capturedLoginOutput | Out-Host
      $loginExitCode = $LASTEXITCODE
      if ($null -ne $capturedLoginOutput) { $loginOutput = @($capturedLoginOutput) }
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }

    $loginText = (($loginOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($loginText)) {
      Write-DebugLog ("az login output attempt {0}: {1}" -f $attempt, $loginText)
    }

    if ($loginExitCode -eq 0) {
      Write-DebugLog "az login completed successfully."
      return
    }

    if ($loginText -match "(?i)No subscriptions found") {
      throw "Azure login succeeded, but this account has no active Azure subscription. Open https://portal.azure.com, activate Free Trial or Pay-As-You-Go, or sign in with an account that has an enabled subscription."
    }

    Write-DebugLog ("az login failed attempt {0}/{1} exit={2}" -f $attempt, $maxAttempts, $loginExitCode)
    if ($attempt -lt $maxAttempts) {
      Write-Host ""
      Write-Host "Azure login did not complete." -ForegroundColor Yellow
      Write-Host "Open the browser page, enter the code, finish Microsoft sign-in, then wait here until it returns." -ForegroundColor Cyan
      continue
    }

    $lastLine = @($loginText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
    $details = if ([string]::IsNullOrWhiteSpace($lastLine)) { "" } else { " Details: $lastLine" }
    throw "Azure login failed or timed out. Complete the device-code sign-in in the browser, then rerun this installer.$details"
  }
}

function Ensure-AzureCliLogin {
  Ensure-AzureCliInstalled

  $accountCheck = Invoke-AzQuiet -ArgsList @("account", "show", "--query", "id", "--output", "tsv")
  if ($accountCheck.ExitCode -ne 0) {
    Write-Host "Azure CLI is not logged in." -ForegroundColor Yellow
    Write-Host "Simple login mode: a code will be shown here; open https://aka.ms/devicelogin and enter it." -ForegroundColor Cyan
    Write-Host "No Service Principal, Client Secret, or manual token is needed." -ForegroundColor Cyan
    Write-Host ""
    Invoke-AzureDeviceLogin
  } else {
    $account = Invoke-AzQuiet -ArgsList @("account", "show", "--query", "{name:name,id:id,user:user.name}", "--output", "tsv")
    if ($account.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($account.Output)) {
      Write-Host "Azure CLI already logged in." -ForegroundColor Green
      $parts = @($account.Output -split "`t")
      $accountName = if ($parts.Count -ge 1) { $parts[0] } else { "" }
      $accountId = if ($parts.Count -ge 2) { $parts[1] } else { "" }
      $accountUser = if ($parts.Count -ge 3) { $parts[2] } else { "" }
      if (-not [string]::IsNullOrWhiteSpace($accountUser)) {
        Write-Host ("  Account: {0}" -f $accountUser) -ForegroundColor Cyan
      }
      if (-not [string]::IsNullOrWhiteSpace($accountName)) {
        Write-Host ("  Subscription: {0} ({1})" -f $accountName, $accountId) -ForegroundColor Cyan
      }

      $useCurrentAccount = Read-Default "Use this Azure account? (Y/n)" "y"
      if ($useCurrentAccount.Trim().ToLowerInvariant() -eq "n") {
        Write-Host ""
        Write-Host "Signing out from the current Azure CLI account..." -ForegroundColor Yellow
        Invoke-Az -ArgsList @("logout") -Label "Azure logout"
        $null = Invoke-AzQuiet -ArgsList @("account", "clear")
        Write-Host ""
        Write-Host "Sign in with the Azure account you want to use." -ForegroundColor Cyan
        Invoke-AzureDeviceLogin
      }
    }
  }
}

function Invoke-AzQuiet([string[]]$ArgsList) {
  $oldErrorActionPreference = $ErrorActionPreference
  $output = @()
  $exitCode = 1
  $azArgs = @($ArgsList)
  if ($azArgs -notcontains "--only-show-errors") { $azArgs += "--only-show-errors" }
  if (($azArgs -notcontains "--output") -and ($azArgs -notcontains "-o")) { $azArgs += @("--output", "none") }
  try {
    $ErrorActionPreference = "Continue"
    $output = & az @azArgs 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  Write-DebugLog ("AZ QUIET exit={0}: az {1}" -f $exitCode, ($azArgs -join " "))
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    Write-DebugLog ("AZ QUIET output: {0}" -f $text)
  }
  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    Output = $text
  }
}

function Get-AzJson([string[]]$ArgsList) {
  Write-DebugLog ("RUN JSON: az {0} --output json" -f ($ArgsList -join " "))
  $output = & az @ArgsList --only-show-errors --output json 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw ("az command failed: az {0}" -f ($ArgsList -join " "))
  }
  $text = ($output -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return ($text | ConvertFrom-Json)
}

function Invoke-Az([string[]]$ArgsList, [string]$Label = "") {
  $azArgs = @($ArgsList)
  if ($azArgs -notcontains "--only-show-errors") { $azArgs += "--only-show-errors" }
  if (($azArgs -notcontains "--output") -and ($azArgs -notcontains "-o")) { $azArgs += @("--output", "none") }
  $operationText = $azArgs -join " "
  $isZipDeploy = ($operationText -match "(?i)\bwebapp deploy\b")

  $maxAttempts = 4
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-DebugLog ("RUN attempt {0}/{1}: az {2}" -f $attempt, $maxAttempts, $operationText)
    if (-not [string]::IsNullOrWhiteSpace($Label)) {
      if ($attempt -eq 1) {
        Write-Host ("  ..  {0}" -f $Label) -ForegroundColor DarkCyan
      } else {
        Write-Host ("  ..  {0} retry {1}/{2}" -f $Label, $attempt, $maxAttempts) -ForegroundColor DarkCyan
      }
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $output = @()
    $exitCode = 1
    try {
      $ErrorActionPreference = "Continue"
      $output = & az @azArgs 2>&1
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }

    $text = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
      Write-DebugLog ("AZ output attempt {0}: {1}" -f $attempt, $text)
    }

    if ($exitCode -eq 0) {
      Write-DebugLog ("AZ OK: az {0}" -f $operationText)
      if (-not [string]::IsNullOrWhiteSpace($Label)) {
        Write-StepDone -Label $Label
      }
      return
    }

    Write-DebugLog ("AZ FAILED attempt {0}/{1} exit={2}: az {3}" -f $attempt, $maxAttempts, $exitCode, $operationText)
    if ($text -match "(?i)throttled|too many requests" -and $attempt -lt $maxAttempts) {
      $delaySeconds = Get-AzureThrottleRetryDelaySeconds -Text $text -Attempt $attempt
      Write-DebugLog ("Azure throttled operation. Waiting {0}s before retry." -f $delaySeconds)
      Write-Host ("  !!  Azure throttled this step. Waiting {0}s before retry {1}/{2}..." -f $delaySeconds, ($attempt + 1), $maxAttempts) -ForegroundColor Yellow
      Start-Sleep -Seconds $delaySeconds
      continue
    }
    if ($isZipDeploy -and (Test-AzTransientNetworkError -Text $text) -and $attempt -lt $maxAttempts) {
      $delaySeconds = @(20, 45, 90)[$attempt - 1]
      Write-DebugLog ("Azure CLI/Kudu connection was reset. Waiting {0}s before retry." -f $delaySeconds)
      Write-Host ("  !!  Azure deployment connection reset. Waiting {0}s before retry {1}/{2}..." -f $delaySeconds, ($attempt + 1), $maxAttempts) -ForegroundColor Yellow
      Start-Sleep -Seconds $delaySeconds
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace($text)) {
      $lastLine = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
      $errorLine = @($text -split "`r?`n" | Where-Object { $_ -match "^\s*ERROR:" }) | Select-Object -First 1
      if ($text -match "(?i)throttled|too many requests") {
        $retryAfter = ""
        if ($text -match "(?i)retry-after[^0-9]*(\d+)") {
          $retryAfter = $Matches[1]
        }
        $waitText = if ($retryAfter) {
          "wait at least $retryAfter seconds before retrying"
        } else {
          "Azure CLI did not expose a Retry-After value"
        }
        throw ("{0}: Azure throttled this create/update operation. {1}. See the guidance below." -f $(if ($Label) { $Label } else { "Azure operation" }), $waitText)
      }
      if ($text -match "(?i)without additional quota|additional quota|Current Limit.*Basic VMs|Amount required.*Basic VMs") {
        throw ("{0}: Azure quota is 0 or insufficient for this App Service plan family in the selected region/subscription. Try another region first; if it still fails, request quota increase for Basic VMs/App Service, upgrade the subscription, or reuse an existing App Service Plan." -f $(if ($Label) { $Label } else { "App Service plan" }))
      }
      if ($text -match "not allowed to create or update the serverfarm") {
        throw ("{0}: Azure rejected this App Service plan SKU for the current subscription/region. For Free Trial credit, use B1, B2, or B3; if it still fails, try another region such as westeurope, uksouth, or northeurope." -f $(if ($Label) { $Label } else { "App Service plan" }))
      }
      if ($text -match "(?i)failed to start within 10 mins|worker proccess failed to start|worker process failed to start|site failed to start") {
        throw ("{0}: Azure deployed the ZIP, but the Node app did not start in time. Check that TARGET_DOMAIN includes https:// or http:// plus the port, inspect the Azure/Kudu log URL in the debug log, and try NODE:20-lts if NODE:22-lts is unsupported in that region." -f $(if ($Label) { $Label } else { "ZIP deployment" }))
      }
      if ($isZipDeploy -and (Test-AzTransientNetworkError -Text $text)) {
        throw ("{0}: Azure CLI lost the deployment connection after several retries. This is usually a temporary Kudu/OneDeploy network reset. Rerun the installer; existing resources will be reused." -f $(if ($Label) { $Label } else { "ZIP deployment" }))
      }
      if (-not [string]::IsNullOrWhiteSpace($errorLine)) { throw ("{0}: {1}" -f $(if ($Label) { $Label } else { "az command failed" }), $errorLine.Trim()) }
      if (-not [string]::IsNullOrWhiteSpace($lastLine)) { throw ("{0}: {1}" -f $(if ($Label) { $Label } else { "az command failed" }), $lastLine) }
    }
    throw ("az command failed: az {0}" -f ($ArgsList -join " "))
  }
}

function Test-AzCommand([string[]]$ArgsList) {
  $result = Invoke-AzQuiet -ArgsList $ArgsList
  Write-DebugLog ("TEST AZ exit={0}: az {1}" -f $result.ExitCode, ($ArgsList -join " "))
  return ($result.ExitCode -eq 0)
}

function Test-DeployedHealth([string]$BaseUrl) {
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return }
  Write-Host ("  ..  Health check") -ForegroundColor DarkCyan
  $healthUrl = $BaseUrl.TrimEnd("/") + "/health"
  for ($i = 1; $i -le 12; $i++) {
    try {
      $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 10
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
        Write-StepDone -Label "Health check" -Detail $healthUrl
        Write-DebugLog ("Health check OK: {0}" -f $healthUrl)
        return
      }
    } catch {
      Write-DebugLog ("Health check attempt {0} failed: {1}" -f $i, $_.Exception.Message)
    }
    Start-Sleep -Seconds 5
  }
  Write-Host ("  !!  Health check did not return 2xx yet: {0}" -f $healthUrl) -ForegroundColor Yellow
  Write-Host "      The deploy can still be warming up. If client tests fail with HTTP 000, check Azure app logs." -ForegroundColor Yellow
}

function Select-AzureSubscription([string]$PreferredSubscriptionId) {
  $accounts = @(Get-AzJson -ArgsList @(
    "account", "list", "--all",
    "--query", "[?state=='Enabled'].{name:name,id:id,isDefault:isDefault,tenantId:tenantId}"
  ))
  if ($accounts.Count -eq 0) {
    throw "No enabled Azure subscription was found for this account. Open portal.azure.com and activate/upgrade a subscription first."
  }

  if (-not [string]::IsNullOrWhiteSpace($PreferredSubscriptionId)) {
    Invoke-Az -ArgsList @("account", "set", "--subscription", $PreferredSubscriptionId) -Label "Selecting subscription"
    $selected = Get-AzJson -ArgsList @("account", "show", "--query", "{name:name,id:id,tenantId:tenantId}")
    Write-StepDone -Label "Subscription" -Detail ("{0} ({1})" -f $selected.name, $selected.id)
    return $selected
  }

  if ($accounts.Count -eq 1) {
    $selected = $accounts[0]
    Invoke-Az -ArgsList @("account", "set", "--subscription", ([string]$selected.id)) -Label "Selecting subscription"
    Write-StepDone -Label "Subscription" -Detail ("{0} ({1})" -f $selected.name, $selected.id)
    return $selected
  }

  Write-Host ""
  Write-Host "Choose Azure subscription:" -ForegroundColor Cyan
  $defaultIndex = 1
  for ($i = 0; $i -lt $accounts.Count; $i++) {
    $item = $accounts[$i]
    $mark = if ($item.isDefault) { " (current)" } else { "" }
    if ($item.isDefault) { $defaultIndex = $i + 1 }
    Write-Host ("[{0}] {1} - {2}{3}" -f ($i + 1), $item.name, $item.id, $mark)
  }

  while ($true) {
    $pick = Read-Default "Select subscription" ([string]$defaultIndex)
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $accounts.Count) {
      $selected = $accounts[$n - 1]
      Invoke-Az -ArgsList @("account", "set", "--subscription", ([string]$selected.id)) -Label "Selecting subscription"
      Write-StepDone -Label "Subscription" -Detail ("{0} ({1})" -f $selected.name, $selected.id)
      return $selected
    }
    Write-Host "Invalid selection." -ForegroundColor Red
  }
}

function Get-BuildProfiles {
  return @(
    [pscustomobject]@{
      Id = "1"
      Name = "Trial Balanced"
      Recommended = $true
      Sku = "B2"
      NodeRuntime = "NODE:22-lts"
      MaxInflight = 256
      MaxUpBps = 0
      MaxDownBps = 0
      UpstreamTimeoutMs = 0
      AlwaysOn = $true
      Http20 = $true
      WebSockets = $true
      Use32BitWorker = $false
      Notes = "Best default for Azure Free Trial credit: stronger than B1, safer than premium tiers."
    },
    [pscustomobject]@{
      Id = "2"
      Name = "Trial Economy"
      Recommended = $false
      Sku = "B1"
      NodeRuntime = "NODE:22-lts"
      MaxInflight = 128
      MaxUpBps = 0
      MaxDownBps = 0
      UpstreamTimeoutMs = 0
      AlwaysOn = $true
      Http20 = $true
      WebSockets = $true
      Use32BitWorker = $false
      Notes = "Lowest dedicated App Service option for light testing."
    },
    [pscustomobject]@{
      Id = "3"
      Name = "Trial High Throughput"
      Recommended = $false
      Sku = "B3"
      NodeRuntime = "NODE:22-lts"
      MaxInflight = 512
      MaxUpBps = 0
      MaxDownBps = 0
      UpstreamTimeoutMs = 0
      AlwaysOn = $true
      Http20 = $true
      WebSockets = $true
      Use32BitWorker = $false
      Notes = "Highest Basic preset that worked on this trial subscription; use for more relay traffic."
    }
  )
}

function Show-AvailableSkus {
  Write-Host "Available SKUs for this Azure Free Trial-friendly installer:" -ForegroundColor Cyan
  Write-Host "  B1  Basic Small  - lowest dedicated option"
  Write-Host "  B2  Basic Medium - balanced trial option"
  Write-Host "  B3  Basic Large  - strongest Basic option"
  Write-Host "  Premium/Standard SKUs are intentionally hidden because this trial subscription rejected P1V3 serverfarm creation." -ForegroundColor Yellow
}

function Select-TrialSku([string]$DefaultSku) {
  $allowed = @("B1", "B2", "B3")
  Show-AvailableSkus
  while ($true) {
    $sku = (Read-Default "App Service SKU" $(if ($DefaultSku -and $allowed -contains $DefaultSku.ToUpperInvariant()) { $DefaultSku.ToUpperInvariant() } else { "B2" })).Trim().ToUpperInvariant()
    if ($allowed -contains $sku) { return $sku }
    Write-Host "For this trial-safe build, choose only B1, B2, or B3." -ForegroundColor Red
  }
}

function Select-BuildProfile([string]$DefaultSku, [string]$DefaultNodeRuntime) {
  $profiles = @(Get-BuildProfiles)
  Write-Host ""
  Write-Host "Choose deployment profile" -ForegroundColor Cyan
  Write-Host "These profiles are tuned for streaming relay usage. They disable app-level hard timeout and speed throttling." -ForegroundColor DarkGray
  Write-Host ""
  foreach ($profile in $profiles) {
    $tag = if ($profile.Recommended) { " (recommended)" } else { "" }
    Write-Host ("[{0}] {1}{2}" -f $profile.Id, $profile.Name, $tag)
    Write-Host ("    SKU={0}, MaxInflight={1}, Timeout=disabled, SpeedLimit=disabled" -f $profile.Sku, $profile.MaxInflight) -ForegroundColor DarkGray
    Write-Host ("    {0}" -f $profile.Notes) -ForegroundColor DarkGray
  }
  Write-Host "[C] Custom Build"
  Write-Host ""

  while ($true) {
    $pick = Read-Default "Select deployment profile" "1"
    if ($pick.Trim().ToLowerInvariant() -eq "c") {
      return New-CustomBuildProfile -DefaultSku $DefaultSku -DefaultNodeRuntime $DefaultNodeRuntime
    }
    $selected = $profiles | Where-Object { $_.Id -eq $pick.Trim() } | Select-Object -First 1
    if ($null -ne $selected) { return $selected }
    Write-Host "Invalid selection." -ForegroundColor Red
  }
}

function New-CustomBuildProfile([string]$DefaultSku, [string]$DefaultNodeRuntime) {
  Write-Host ""
  Write-Host "Custom Build" -ForegroundColor Cyan
  Show-AvailableSkus
  Write-Host ""
  Write-Host "For streaming relay, keep timeout and speed limits at 0 unless you intentionally want limits." -ForegroundColor Yellow
  $customSku = Select-TrialSku -DefaultSku $(if ($DefaultSku) { $DefaultSku } else { "B2" })
  $customRuntime = Select-NodeRuntime -CurrentDefault $(if ($DefaultNodeRuntime) { $DefaultNodeRuntime } else { "NODE:22-lts" })
  $customInflight = Read-OptionalInt "MAX_INFLIGHT concurrent relay requests" 256 1
  $customTimeout = Read-OptionalInt "UPSTREAM_TIMEOUT_MS hard timeout, 0 = disabled/recommended" 0 0
  $customUp = Read-OptionalInt "MAX_UP_BPS upload speed limit, 0 = disabled/recommended" 0 0
  $customDown = Read-OptionalInt "MAX_DOWN_BPS download speed limit, 0 = disabled/recommended" 0 0
  return [pscustomobject]@{
    Id = "C"
    Name = "Custom Build"
    Recommended = $false
    Sku = $customSku.Trim()
    NodeRuntime = $customRuntime.Trim()
    MaxInflight = $customInflight
    MaxUpBps = $customUp
    MaxDownBps = $customDown
    UpstreamTimeoutMs = $customTimeout
    AlwaysOn = $true
    Http20 = $true
    WebSockets = $true
    Use32BitWorker = $false
    Notes = "User-defined build profile."
  }
}

function Select-NodeRuntime([string]$CurrentDefault) {
  Write-Host ""
  Write-Host "Available Node runtimes:" -ForegroundColor Cyan
  Write-Host "  NODE:22-lts  Recommended"
  Write-Host "  NODE:20-lts  Older LTS fallback"
  return (Read-Default "Node runtime" $(if ($CurrentDefault) { $CurrentDefault } else { "NODE:22-lts" }))
}

Write-Host "=============================================="
Write-Host " XHTTPRelayAzure Deploy"
Write-Host " Azure App Service Node runtime"
Write-Host "=============================================="
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
Start-DebugLogging -ProjectRoot $scriptDir

if (-not (Test-Path (Join-Path $scriptDir "index.js"))) { throw "index.js not found. Run from project root." }
if (-not (Test-Path (Join-Path $scriptDir "package.json"))) { throw "package.json not found. Run from project root." }

Ensure-AzureCliLogin
$selectedSubscription = Select-AzureSubscription -PreferredSubscriptionId $SubscriptionId

$ResourceGroup = Read-Default "Resource group" $(if ($ResourceGroup) { $ResourceGroup } else { New-RandomName "rg-xhttprelay" })
$AppName = Read-Default "App Service name" $(if ($AppName) { $AppName } else { New-RandomName "xhttprelayaz" })
if ([string]::IsNullOrWhiteSpace($PlanName)) { $PlanName = "$AppName-plan" }
$PlanName = Read-Default "App Service plan name" $PlanName
$buildProfile = Select-BuildProfile -DefaultSku $Sku -DefaultNodeRuntime $NodeRuntime
$Sku = [string]$buildProfile.Sku
$NodeRuntime = [string]$buildProfile.NodeRuntime

Write-Host ""
Write-Host "TARGET_DOMAIN" -ForegroundColor Cyan
Write-Host "  Enter the upstream inbound address, including protocol, domain/IP, and port." -ForegroundColor DarkGray
Write-Host "  This is the address of the server/inbound you want Azure to relay to." -ForegroundColor DarkGray
Write-Host "  Examples: https://your-domain.com:443  or  https://dedf.example.site:2053" -ForegroundColor DarkGray
$TargetDomain = Normalize-TargetDomain (Read-Required "TARGET_DOMAIN upstream inbound URL" $TargetDomain)
$Location = Choose-AzureLocation -TargetDomain $TargetDomain -CurrentDefault $Location

Write-Host ""
Write-Host "RELAY_PATH" -ForegroundColor Cyan
Write-Host "  Enter the path configured in your upstream inbound." -ForegroundColor DarkGray
Write-Host "  If your inbound path is /api, enter /api. This will also be used as the public client path." -ForegroundColor DarkGray
if ([string]::IsNullOrWhiteSpace($RelayPath)) {
  $RelayPath = Normalize-PathLike (Read-Required "RELAY_PATH upstream inbound path, example: /api")
} else {
  $RelayPath = Normalize-PathLike (Read-Default "RELAY_PATH upstream inbound path" $RelayPath)
}
$PublicRelayPath = $RelayPath
Write-StepDone -Label "PUBLIC_RELAY_PATH" -Detail $PublicRelayPath

Write-Host ""
Write-Host "RELAY_KEY is optional. You usually do not need it; press Enter to leave it disabled." -ForegroundColor Cyan
$RelayKey = Read-Default "RELAY_KEY optional" $RelayKey

Write-Host ""
Write-Host "Deploy summary" -ForegroundColor Cyan
Write-Host "----------------------------------------------" -ForegroundColor DarkGray
Write-SummaryRow -Name "Subscription" -Value ("{0} / {1}" -f $selectedSubscription.name, $selectedSubscription.id)
Write-SummaryRow -Name "Build profile" -Value $buildProfile.Name
Write-SummaryRow -Name "Resource group" -Value $ResourceGroup
Write-SummaryRow -Name "App Service" -Value $AppName
Write-SummaryRow -Name "Region" -Value $Location
Write-SummaryRow -Name "Plan SKU" -Value $Sku
Write-SummaryRow -Name "Node runtime" -Value $NodeRuntime
Write-SummaryRow -Name "Target domain" -Value $TargetDomain
Write-SummaryRow -Name "Client path" -Value $PublicRelayPath
Write-SummaryRow -Name "Upstream path" -Value $RelayPath
Write-SummaryRow -Name "Hard timeout" -Value $(if ([int]$buildProfile.UpstreamTimeoutMs -eq 0) { "disabled" } else { ("{0} ms" -f $buildProfile.UpstreamTimeoutMs) })
Write-SummaryRow -Name "Speed limit" -Value $(if ([int]$buildProfile.MaxUpBps -eq 0 -and [int]$buildProfile.MaxDownBps -eq 0) { "disabled" } else { ("up={0} B/s, down={1} B/s" -f $buildProfile.MaxUpBps, $buildProfile.MaxDownBps) })
Write-SummaryRow -Name "Max inflight" -Value ([string]$buildProfile.MaxInflight)
if ([string]::IsNullOrWhiteSpace($RelayKey)) {
  Write-SummaryRow -Name "Relay key" -Value "disabled"
} else {
  Write-SummaryRow -Name "Relay key" -Value "enabled"
}
Write-Host "----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-Default "Continue deploy? (Y/n)" "y"
if ($confirm.Trim().ToLowerInvariant() -eq "n") { exit 0 }

Write-Host ""
Write-Section "Building static frontend"
Ensure-NodeBuildRuntime
$env:TARGET_DOMAIN = $TargetDomain.TrimEnd("/")
$env:RELAY_PATH = $RelayPath
$env:PUBLIC_RELAY_PATH = $PublicRelayPath
$buildScript = Join-Path $scriptDir "scripts\prepare-build.mjs"
$oldErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = "Continue"
  $buildOutput = & node $buildScript 2>&1
  $buildExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $oldErrorActionPreference
}
if (-not [string]::IsNullOrWhiteSpace(($buildOutput -join "`n"))) {
  Write-DebugLog ("frontend build output: {0}" -f (($buildOutput | ForEach-Object { [string]$_ }) -join "`n").Trim())
}
if ($buildExitCode -ne 0) { throw "Static frontend build failed. Make sure Node.js LTS is installed and rerun this installer." }
Write-StepDone -Label "Static frontend" -Detail "public/ generated"

Write-Host ""
Write-Section "Creating Azure resources"
Invoke-Az -ArgsList @("group", "create", "--name", $ResourceGroup, "--location", $Location) -Label "Resource group"
if (Test-AzCommand -ArgsList @("appservice", "plan", "show", "--resource-group", $ResourceGroup, "--name", $PlanName)) {
  Write-StepDone -Label "App Service plan" -Detail "already exists"
} else {
  Invoke-Az -ArgsList @("appservice", "plan", "create", "--resource-group", $ResourceGroup, "--name", $PlanName, "--is-linux", "--sku", $Sku) -Label "App Service plan"
}
if (Test-AzCommand -ArgsList @("webapp", "show", "--resource-group", $ResourceGroup, "--name", $AppName)) {
  Write-StepDone -Label "Web App" -Detail "already exists"
} else {
  Invoke-Az -ArgsList @("webapp", "create", "--resource-group", $ResourceGroup, "--plan", $PlanName, "--name", $AppName, "--runtime", $NodeRuntime) -Label "Web App"
}
$alwaysOnValue = if ($buildProfile.AlwaysOn) { "true" } else { "false" }
$http20Value = if ($buildProfile.Http20) { "true" } else { "false" }
$webSocketsValue = if ($buildProfile.WebSockets) { "true" } else { "false" }
$use32BitValue = if ($buildProfile.Use32BitWorker) { "true" } else { "false" }
Invoke-Az -ArgsList @(
  "webapp", "config", "set",
  "--resource-group", $ResourceGroup,
  "--name", $AppName,
  "--startup-file", "node index.js",
  "--always-on", $alwaysOnValue,
  "--http20-enabled", $http20Value,
  "--web-sockets-enabled", $webSocketsValue,
  "--use-32bit-worker-process", $use32BitValue
) -Label "Runtime config"
Invoke-Az -ArgsList @(
  "webapp", "config", "appsettings", "set",
  "--resource-group", $ResourceGroup,
  "--name", $AppName,
  "--settings",
  "TARGET_DOMAIN=$($TargetDomain.TrimEnd('/'))",
  "RELAY_PATH=$RelayPath",
  "PUBLIC_RELAY_PATH=$PublicRelayPath",
  "RELAY_KEY=$RelayKey",
  "UPSTREAM_TIMEOUT_MS=$($buildProfile.UpstreamTimeoutMs)",
  "MAX_INFLIGHT=$($buildProfile.MaxInflight)",
  "MAX_UP_BPS=$($buildProfile.MaxUpBps)",
  "MAX_DOWN_BPS=$($buildProfile.MaxDownBps)",
  "SCM_DO_BUILD_DURING_DEPLOYMENT=false",
  "ENABLE_ORYX_BUILD=false",
  "WEBSITE_RUN_FROM_PACKAGE=1"
) -Label "Application settings"

Write-Host ""
Write-Section "Packaging project"
$zipPath = Join-Path $env:TEMP ("xhttprelayazure-{0}.zip" -f ([guid]::NewGuid().ToString("N")))
$excludeNames = @(".git", ".qodo", "node_modules", "azure-xhttp-relay")
$items = Get-ChildItem -LiteralPath $scriptDir -Force | Where-Object {
  $excludeNames -notcontains $_.Name -and
  $_.Name -notlike "*.zip" -and
  $_.Name -notlike "*.log" -and
  $_.Name -notlike "*.dpapi"
}
Compress-Archive -LiteralPath @($items.FullName) -DestinationPath $zipPath -Force
Write-StepDone -Label "ZIP package" -Detail (Split-Path -Leaf $zipPath)

Write-Host ""
Write-Section "Deploying to Azure"
Write-Host "  This can take 1-2 minutes while Azure starts the site." -ForegroundColor DarkGray
Invoke-Az -ArgsList @("webapp", "deploy", "--resource-group", $ResourceGroup, "--name", $AppName, "--src-path", $zipPath, "--type", "zip", "--restart", "true") -Label "ZIP deployment"
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

$url = "https://$AppName.azurewebsites.net"
Test-DeployedHealth -BaseUrl $url
Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "Azure deployment complete." -ForegroundColor Green
Write-Host "URL:  $url" -ForegroundColor Green
Write-Host "Host: $AppName.azurewebsites.net" -ForegroundColor Cyan
Write-Host "Path: $PublicRelayPath" -ForegroundColor Cyan
if (-not [string]::IsNullOrWhiteSpace($RelayKey)) {
  Write-Host ""
  Write-Host "XHTTP Extra header:" -ForegroundColor Yellow
  Write-Host "{"
  Write-Host '  "headers": {'
  Write-Host ('    "x-relay-key": "{0}"' -f $RelayKey)
  Write-Host "  }"
  Write-Host "}"
}
Write-Host "==============================================" -ForegroundColor Green
Write-DebugLog "Deployment flow completed successfully."
if ($script:TranscriptStarted) {
  try { Stop-Transcript | Out-Null } catch {}
  $script:TranscriptStarted = $false
}
