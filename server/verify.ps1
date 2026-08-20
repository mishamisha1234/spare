<#
.SYNOPSIS
    Checks a deployed Spare proxy is working and enforcing its rules.

.DESCRIPTION
    Runs a series of real HTTP requests against the deployed Worker and reports
    PASS or FAIL for each.

    Most checks cost nothing, because the thing being tested is a refusal that
    happens before the proxy ever calls Anthropic. One check does make a real
    generation call, deliberately capped at 16 output tokens, so it costs a
    fraction of a penny — that is the only way to prove the API key is stored
    correctly and that metering actually counts a lesson.

    Uses curl.exe rather than Invoke-WebRequest throughout. Invoke-WebRequest
    treats any non-2xx status as a terminating error, and almost every check
    here expects a 4xx: the refusals are the product working. Fighting that with
    try/catch on every call obscures the thing being tested, and reading an error
    body differs between PowerShell 5.1 and 7. curl.exe behaves the same on both.

.PARAMETER BaseURL
    The Worker's URL. Defaults to the deployed one.

.PARAMETER NoSpend
    Skip the one check that makes a real generation call. Everything else still
    runs. Use this to re-check a deploy without spending anything at all.

.PARAMETER CeilingTest
    Expect the spend ceiling to be blocking free generation. Only meaningful
    after temporarily setting MONTHLY_SPEND_CEILING_USD to 0 and redeploying —
    see the notes printed at the end.

.EXAMPLE
    .\verify.ps1
    .\verify.ps1 -NoSpend
    .\verify.ps1 -CeilingTest
#>

param(
    [string]$BaseURL = "https://spare-proxy.mishabichashvili1998.workers.dev",
    [switch]$NoSpend,
    [switch]$CeilingTest
)

$ErrorActionPreference = "Stop"
$BaseURL = $BaseURL.TrimEnd("/")

$script:Passed = 0
$script:Failed = 0
$script:Notes  = @()

function Write-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail)
    if ($Ok) {
        Write-Host "  PASS  " -ForegroundColor Green -NoNewline
        Write-Host $Name
        $script:Passed++
    } else {
        Write-Host "  FAIL  " -ForegroundColor Red -NoNewline
        Write-Host $Name
        # Only on failure: on a pass the "expected" line is noise that makes a
        # clean run look like it has something to say.
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        $script:Failed++
    }
}

<#
    Sends one request and returns the status code and body.

    The JSON body goes via a temp file rather than inline. PowerShell, cmd, and
    curl each want to quote embedded double quotes differently, and a body
    mangled in transit produces a 400 that looks like a server fault.
#>
function Invoke-Proxy {
    param(
        [string]$Path,
        [string]$Method = "POST",
        [string]$Device,
        [hashtable]$Body
    )

    # Not $args: that is an automatic variable, and splatting it would pass
    # whatever PowerShell put there rather than what we built.
    $curlArgs = @("-s", "-S", "-w", "`n<<<%{http_code}>>>", "-X", $Method, "$BaseURL$Path")
    if ($Device) { $curlArgs += @("-H", "x-spare-device: $Device") }

    $tmp = $null
    if ($Body) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $json = $Body | ConvertTo-Json -Depth 12 -Compress
        # Written through .NET with an explicit BOM-less encoding. PowerShell's
        # Set-Content -Encoding utf8 prepends a byte order mark on 5.1, and a BOM
        # ahead of the opening brace makes the Worker's request.json() throw —
        # every request would come back 400 malformedRequest and look like a
        # server fault.
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
        $curlArgs += @("-H", "content-type: application/json", "-d", "@$tmp")
    }

    try {
        $raw = (& curl.exe @curlArgs) -join "`n"
    } finally {
        if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force }
    }

    $status = 0
    if ($raw -match "<<<(\d+)>>>") { $status = [int]$Matches[1] }
    # Not $body: PowerShell variable names are case-insensitive, so that would
    # assign a string to this function's [hashtable]$Body parameter and throw a
    # cast error that reads like the server sent something malformed.
    $responseBody = ($raw -replace "`n?<<<\d+>>>", "")

    return [pscustomobject]@{ Status = $status; Body = $responseBody }
}

function Get-ErrorCode {
    param([string]$Body)
    if ($Body -match '"code"\s*:\s*"([^"]+)"') { return $Matches[1] }
    return ""
}

function New-Device { "verify-" + [guid]::NewGuid().ToString("N") }

<# A minimal but genuine Anthropic request. #>
function New-ModelRequest {
    param([int]$MaxTokens = 16, [string]$Model = "claude-opus-5", [string]$Text = "Say the single word: ok.")
    @{
        model      = $Model
        max_tokens = $MaxTokens
        messages   = @(
            @{ role = "user"; content = @(@{ type = "text"; text = $Text }) }
        )
    }
}

function New-LessonBody {
    param(
        [string]$Topic,
        [string]$Window = "three",
        [string]$Format = "oneThing",
        [hashtable]$Request = $null
    )
    if (-not $Request) { $Request = New-ModelRequest }
    @{ window = $Window; format = $Format; topic = $Topic; request = $Request }
}

# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Spare proxy verification" -ForegroundColor White
Write-Host $BaseURL -ForegroundColor DarkGray
Write-Host ""

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "curl.exe not found. It ships with Windows 10 and later." -ForegroundColor Red
    exit 1
}

# --- 1. Reachable, and refusing an unidentified request ---------------------
Write-Host "Reachability" -ForegroundColor Cyan

$r = Invoke-Proxy -Path "/v1/lesson" -Body @{}
Write-Result ($r.Status -eq 400 -and (Get-ErrorCode $r.Body) -eq "missingDevice") `
    "Refuses a request with no device identifier" `
    "expected 400 missingDevice, got $($r.Status) $(Get-ErrorCode $r.Body)"

if ($r.Status -eq 0) {
    Write-Host ""
    Write-Host "  The Worker did not respond at all. Check the URL, and that" -ForegroundColor Red
    Write-Host "  'npx wrangler deploy' finished." -ForegroundColor Red
    Write-Host ""
    exit 1
}

$r = Invoke-Proxy -Path "/v1/lesson" -Method "GET" -Device (New-Device)
Write-Result ($r.Status -eq 405) "Refuses a GET" "expected 405, got $($r.Status)"

$r = Invoke-Proxy -Path "/v1/nonsense" -Device (New-Device) -Body (New-LessonBody -Topic "x")
Write-Result ($r.Status -eq 404) "Refuses an unknown endpoint" "expected 404, got $($r.Status)"

# --- 2. Spend guard on the request itself -----------------------------------
Write-Host ""
Write-Host "Request policy  (nothing reaches Anthropic, so nothing is billed)" -ForegroundColor Cyan

$r = Invoke-Proxy -Path "/v1/lesson" -Device (New-Device) `
    -Body (New-LessonBody -Topic "Model swap" -Request (New-ModelRequest -Model "some-other-model"))
Write-Result ($r.Status -eq 400 -and (Get-ErrorCode $r.Body) -eq "modelNotAllowed") `
    "Refuses a model the server will not pay for" `
    "expected 400 modelNotAllowed, got $($r.Status) $(Get-ErrorCode $r.Body)"

$big = New-ModelRequest -Text ("x" * 300000)
$r = Invoke-Proxy -Path "/v1/lesson" -Device (New-Device) -Body (New-LessonBody -Topic "Padding" -Request $big)
Write-Result ($r.Status -eq 400 -and (Get-ErrorCode $r.Body) -eq "requestTooLarge") `
    "Refuses an oversized request" `
    "expected 400 requestTooLarge, got $($r.Status) $(Get-ErrorCode $r.Body)"

# --- 3. Free tier, without spending -----------------------------------------
Write-Host ""
Write-Host "Free tier  (refused before any generation, so still free)" -ForegroundColor Cyan

$r = Invoke-Proxy -Path "/v1/lesson" -Device (New-Device) `
    -Body (New-LessonBody -Topic "A course" -Window "thirty" -Format "miniCourse")
Write-Result ($r.Status -eq 402 -and (Get-ErrorCode $r.Body) -eq "lockedWindow") `
    "Refuses a 30-minute course to a free device" `
    "expected 402 lockedWindow, got $($r.Status) $(Get-ErrorCode $r.Body)"

$r = Invoke-Proxy -Path "/v1/lesson" -Device (New-Device) `
    -Body (New-LessonBody -Topic "A 15 minute lesson" -Window "fifteen" -Format "lesson")
Write-Result ($r.Status -eq 402 -and (Get-ErrorCode $r.Body) -eq "lockedWindow") `
    "Refuses a 15-minute lesson to a free device" `
    "expected 402 lockedWindow, got $($r.Status) $(Get-ErrorCode $r.Body)"

$r = Invoke-Proxy -Path "/v1/go-deeper" -Device (New-Device) `
    -Body @{ request = (New-ModelRequest) }
Write-Result ($r.Status -eq 402 -and (Get-ErrorCode $r.Body) -eq "goDeeperLocked") `
    "Refuses go-deeper to a free device" `
    "expected 402 goDeeperLocked, got $($r.Status) $(Get-ErrorCode $r.Body)"

# --- 4. The spend ceiling ----------------------------------------------------
if ($CeilingTest) {
    Write-Host ""
    Write-Host "Spend ceiling" -ForegroundColor Cyan
    $r = Invoke-Proxy -Path "/v1/lesson" -Device (New-Device) -Body (New-LessonBody -Topic "Ceiling probe")
    Write-Result ($r.Status -eq 429 -and (Get-ErrorCode $r.Body) -eq "spendCeilingReached") `
        "Free generation stops at the ceiling" `
        "expected 429 spendCeilingReached, got $($r.Status) $(Get-ErrorCode $r.Body)"
    $script:Notes += "Ceiling test done: set MONTHLY_SPEND_CEILING_USD back to 50 and redeploy."
}

# --- 5. A real generation, and the daily limit -------------------------------
if ($NoSpend) {
    Write-Host ""
    Write-Host "Skipping the live generation check (-NoSpend)." -ForegroundColor DarkGray
    $script:Notes += "The API key itself was not exercised. Run without -NoSpend to confirm it works."
} elseif ($CeilingTest) {
    Write-Host ""
    Write-Host "Skipping the live generation check: the ceiling is blocking it by design." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "Live generation  (one real call, capped at 16 tokens, well under a penny)" -ForegroundColor Cyan

    $device = New-Device
    $r = Invoke-Proxy -Path "/v1/lesson" -Device $device -Body (New-LessonBody -Topic "Why bridges hum on a windy day")

    $streamed = $r.Status -eq 200 -and $r.Body -match "event:\s*message_start"
    Write-Result $streamed "Generates a lesson and streams it back" `
        "expected 200 with SSE events, got $($r.Status) $(Get-ErrorCode $r.Body)"

    if (-not $streamed) {
        switch (Get-ErrorCode $r.Body) {
            "upstreamRejected"   { $script:Notes += "Anthropic rejected the request. Most likely ANTHROPIC_API_KEY is wrong or has no credit." }
            "upstreamUnavailable"{ $script:Notes += "Anthropic returned a server error. Try again in a minute." }
            "rateLimited"        { $script:Notes += "Anthropic is throttling. Try again in a minute." }
            "spendCeilingReached"{ $script:Notes += "The spend ceiling is already blocking free generation. Check MONTHLY_SPEND_CEILING_USD." }
        }
    }

    Write-Result ($r.Body -notmatch "sk-ant-") "No API key appears in the response" ""

    # The same device, a different topic so the cache cannot be what answers.
    $r2 = Invoke-Proxy -Path "/v1/lesson" -Device $device -Body (New-LessonBody -Topic "Something else entirely today")
    Write-Result ($r2.Status -eq 402 -and (Get-ErrorCode $r2.Body) -eq "dailyLimitReached") `
        "Refuses a second lesson to the same device today" `
        "expected 402 dailyLimitReached, got $($r2.Status) $(Get-ErrorCode $r2.Body)"

    # A different device is unaffected: the limit is per device, not global.
    $r3 = Invoke-Proxy -Path "/v1/lesson" -Device (New-Device) `
        -Body (New-LessonBody -Topic "A course" -Window "thirty" -Format "miniCourse")
    Write-Result ($r3.Status -eq 402 -and (Get-ErrorCode $r3.Body) -eq "lockedWindow") `
        "A different device is not affected by the first one's limit" `
        "expected 402 lockedWindow (not dailyLimitReached), got $($r3.Status) $(Get-ErrorCode $r3.Body)"
}

# ---------------------------------------------------------------------------

Write-Host ""
Write-Host ("-" * 60) -ForegroundColor DarkGray
if ($script:Failed -eq 0) {
    Write-Host "$($script:Passed) passed, 0 failed." -ForegroundColor Green
} else {
    Write-Host "$($script:Passed) passed, $($script:Failed) FAILED." -ForegroundColor Red
}

foreach ($note in $script:Notes) {
    Write-Host ""
    Write-Host "  $note" -ForegroundColor Yellow
}

if (-not $CeilingTest) {
    Write-Host ""
    Write-Host "  To check the spend ceiling, which cannot be reached by testing:" -ForegroundColor DarkGray
    Write-Host "    1. notepad wrangler.toml   ->  MONTHLY_SPEND_CEILING_USD = `"0`"" -ForegroundColor DarkGray
    Write-Host "    2. npx wrangler deploy" -ForegroundColor DarkGray
    Write-Host "    3. .\verify.ps1 -CeilingTest" -ForegroundColor DarkGray
    Write-Host "    4. put it back to `"50`" and deploy again" -ForegroundColor DarkGray
}
Write-Host ""

if ($script:Failed -gt 0) { exit 1 }
