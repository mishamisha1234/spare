<#
.SYNOPSIS
    Generates 20 lessons through the live proxy and saves them as markdown.

.DESCRIPTION
    Five lessons at each length (3, 10, 15, 30 minutes), every topic unique so
    nothing is answered from cache. Each is written to its own .md file, and the
    run ends with a table of word count against budget and real cost per lesson.

    This spends real money — roughly $3 for the full set, most of it in the
    30-minute courses. The running total is printed after every lesson so it can
    be stopped with Ctrl+C at any point.

    One caveat on what the word counts mean. This script sends its own short
    prompt, not the app's editorial prompts from Prompts.swift, because those
    are Swift and copying them here would give the text that most needs one
    source of truth two. So the budget column measures how the model responds to
    a plain request for a given length. It is a useful read on cost, speed,
    truncation and the shape of the output; it is not a measurement of the app's
    prompts.

    Needs the operator token, which is the same ADMIN_TOKEN the status endpoint
    uses. The bypass skips the daily limit and the cache so all 20 actually
    generate; it does not skip the spend ceiling, so this run cannot exceed
    MONTHLY_SPEND_CEILING_USD however wrong it goes.

.PARAMETER Token
    The ADMIN_TOKEN set with `npx wrangler secret put ADMIN_TOKEN`.

.PARAMETER OutDir
    Where to write the markdown. Defaults to a timestamped folder on the Desktop.

.PARAMETER BaseURL
    The Worker's URL.

.PARAMETER Only
    Run just one length: three, ten, fifteen, or thirty. For a cheap trial run.

.EXAMPLE
    .\batch-lessons.ps1 -Token "your-admin-token"
    .\batch-lessons.ps1 -Token "your-admin-token" -Only three
#>

param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$OutDir = (Join-Path ([Environment]::GetFolderPath("Desktop")) ("spare-lessons-" + (Get-Date -Format "yyyy-MM-dd-HHmm"))),
    [string]$BaseURL = "https://spare-proxy.mishabichashvili1998.workers.dev",
    [ValidateSet("three", "ten", "fifteen", "thirty")][string]$Only
)

$ErrorActionPreference = "Stop"
$BaseURL = $BaseURL.TrimEnd("/")

# Mirrors TimeWindow.swift. Kept here rather than fetched so the report says
# what the app promises, not what the server happened to allow.
# MaxTokens mirrors AnthropicAPI.maxTokens rather than being sized from the word
# budget. Output tokens on this model include its thinking, not just the prose:
# a trial run capped at 2,000 produced 415 words cut off mid-word, because most
# of that budget went on thinking. Sizing these from word counts produces lessons
# that look short when they were actually truncated, which would make every
# number in the table below a lie about the model.
#
# thirty is 24,000, the policy ceiling for /v1/lesson, because this script writes
# a course in one call where the app generates it a chapter at a time.
$Windows = [ordered]@{
    three   = @{ Label = "3 min";  Format = "oneThing";   Min = 500;  Max = 650;  MaxTokens = 8000;  Chapters = 1 }
    ten     = @{ Label = "10 min"; Format = "explainer";  Min = 1600; Max = 2000; MaxTokens = 16000; Chapters = 1 }
    fifteen = @{ Label = "15 min"; Format = "lesson";     Min = 2400; Max = 3000; MaxTokens = 24000; Chapters = 1 }
    thirty  = @{ Label = "30 min"; Format = "miniCourse"; Min = 6000; Max = 6400; MaxTokens = 24000; Chapters = 4 }
}

# Anthropic list pricing, mirroring CostEstimator in SpareCore.
$PricePerMTokIn  = 5
$PricePerMTokOut = 25

# Twenty distinct subjects, five per length, chosen to spread across domains so
# the batch shows what the model does with different kinds of material rather
# than five variations on one.
$Topics = [ordered]@{
    three = @(
        "Why cast iron pans season",
        "How noise-cancelling headphones invert sound",
        "Why onions make you cry",
        "How a thermos keeps things hot and cold",
        "Why bread goes stale faster in the fridge"
    )
    ten = @(
        "How the Venetian arsenal invented the assembly line",
        "Why antibiotics stopped working on some infections",
        "How insurance priced risk before statistics existed",
        "Why the Dutch built polders instead of dams",
        "How sourdough starters stay alive for centuries"
    )
    fifteen = @(
        "How lighthouses solved the problem of being seen",
        "Why the metric system needed a revolution to adopt",
        "How refrigeration rewrote what people eat",
        "Why medieval cathedrals kept falling down",
        "How the telegraph changed what news meant"
    )
    thirty = @(
        "How aviation safety was written after each crash",
        "Why cities keep rebuilding in the same floodplains",
        "How vaccines went from inoculation to mRNA",
        "Why the shipping container reshaped world trade",
        "How clocks made industrial work possible"
    )
}

# ---------------------------------------------------------------------------

function Invoke-Lesson {
    param([string]$Window, [string]$Format, [string]$Topic, [int]$MaxTokens, [int]$Chapters)

    $structure = if ($Chapters -gt 1) {
        "Write it as $Chapters chapters, each with a '## Chapter N: <heading>' line before its prose."
    } else {
        "Write it as continuous prose with no headings."
    }

    $body = @{
        window  = $Window
        format  = $Format
        topic   = $Topic
        request = @{
            model      = "claude-opus-5"
            max_tokens = $MaxTokens
            system     = "You write micro-lessons for adults who are curious and short of time. Concrete, factual, specific. Open with something particular rather than a definition. No preamble, no summary, no bullet lists, no exclamation marks."
            messages   = @(
                @{ role = "user"; content = @(@{ type = "text"; text = "Write a lesson on: $Topic`n`n$structure`nAim for $($Windows[$Window].Min) to $($Windows[$Window].Max) words." }) }
            )
        }
    }

    $bodyFile = [System.IO.Path]::GetTempFileName()
    $hdrFile  = [System.IO.Path]::GetTempFileName()
    # BOM-less, via .NET: Set-Content -Encoding utf8 prepends a byte order mark
    # on PowerShell 5.1, and a BOM before the opening brace makes the Worker's
    # request.json() throw.
    [System.IO.File]::WriteAllText($bodyFile, ($body | ConvertTo-Json -Depth 12 -Compress), (New-Object System.Text.UTF8Encoding $false))

    try {
        $raw = (& curl.exe -s -S --max-time 600 -D $hdrFile -X POST "$BaseURL/v1/lesson" `
            -H "content-type: application/json" `
            -H "x-spare-device: batch-run" `
            -H "x-spare-admin: $Token" `
            -d "@$bodyFile") -join "`n"
        $headers = Get-Content $hdrFile -Raw
    } finally {
        Remove-Item $bodyFile, $hdrFile -Force -ErrorAction SilentlyContinue
    }

    $status = if ($headers -match "HTTP/[\d.]+\s+(\d+)") { [int]$Matches[1] } else { 0 }
    $cached = $headers -match "(?im)^x-spare-cache:\s*hit"

    # Reassemble the prose and read usage out of the same stream, so the cost
    # reported is the one Anthropic actually billed rather than an estimate from
    # the word count.
    $sb = New-Object System.Text.StringBuilder
    $inTok = 0; $outTok = 0; $complete = $false; $stopReason = ""
    foreach ($line in ($raw -split "`n")) {
        if (-not $line.StartsWith("data: ")) { continue }
        $payload = $line.Substring(6).Trim()
        if (-not $payload) { continue }
        try { $event = $payload | ConvertFrom-Json } catch { continue }
        switch ($event.type) {
            "content_block_delta" { if ($event.delta.text) { [void]$sb.Append($event.delta.text) } }
            "message_start" {
                if ($event.message.usage.input_tokens)  { $inTok  = [int]$event.message.usage.input_tokens }
                if ($event.message.usage.output_tokens) { $outTok = [int]$event.message.usage.output_tokens }
            }
            "message_delta" {
                if ($event.usage.output_tokens) { $outTok = [int]$event.usage.output_tokens }
                if ($event.delta.stop_reason)   { $stopReason = [string]$event.delta.stop_reason }
            }
            # message_stop arrives even when the model was cut off at the cap,
            # so stop_reason is what says whether the lesson actually ended.
            "message_stop" { $complete = $true }
        }
    }

    $errorCode = if ($raw -match '"code"\s*:\s*"([^"]+)"') { $Matches[1] } else { "" }

    [pscustomobject]@{
        Status     = $status
        Cached     = $cached
        Text       = $sb.ToString()
        InTokens   = $inTok
        OutTokens  = $outTok
        Complete   = ($complete -and $stopReason -ne "max_tokens")
        StopReason = $stopReason
        ErrorCode  = $errorCode
        CostUSD    = ($inTok / 1000000.0) * $PricePerMTokIn + ($outTok / 1000000.0) * $PricePerMTokOut
    }
}

function Get-WordCount {
    param([string]$Text)
    # Strips markdown headings before counting, so a chapter heading is not
    # scored as part of the prose budget.
    $prose = ($Text -split "`n" | Where-Object { -not $_.TrimStart().StartsWith("#") }) -join " "
    ($prose -split '\s+' | Where-Object { $_ -match '\w' }).Count
}

function Get-Verdict {
    param([int]$Words, [int]$Min, [int]$Max)
    if ($Words -lt $Min) { return "under" }
    if ($Words -gt $Max) { return "over" }
    return "in budget"
}

# ---------------------------------------------------------------------------

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "curl.exe not found. It ships with Windows 10 and later." -ForegroundColor Red
    exit 1
}

$plan = if ($Only) { @($Only) } else { @($Windows.Keys) }
$total = ($plan | ForEach-Object { $Topics[$_].Count } | Measure-Object -Sum).Sum

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Host ""
Write-Host "Spare lesson batch" -ForegroundColor White
Write-Host "$total lessons -> $OutDir" -ForegroundColor DarkGray
Write-Host "Ctrl+C stops after the lesson in flight; everything saved so far is kept." -ForegroundColor DarkGray
Write-Host ""

$results = @()
$runningCost = 0.0
$index = 0
$abort = $false

foreach ($window in $plan) {
    if ($abort) { break }
    $spec = $Windows[$window]
    foreach ($topic in $Topics[$window]) {
        $index++
        Write-Host ("[{0,2}/{1}] {2,-7} {3}" -f $index, $total, $spec.Label, $topic) -NoNewline

        $started = Get-Date
        $r = Invoke-Lesson -Window $window -Format $spec.Format -Topic $topic `
                           -MaxTokens $spec.MaxTokens -Chapters $spec.Chapters
        $seconds = [math]::Round(((Get-Date) - $started).TotalSeconds)

        if ($r.Status -ne 200 -or -not $r.Text) {
            Write-Host ("  FAILED  HTTP {0} {1}" -f $r.Status, $r.ErrorCode) -ForegroundColor Red
            if ($r.ErrorCode -eq "dailyLimitReached" -or $r.ErrorCode -eq "lockedWindow") {
                Write-Host "        The operator token was not accepted, so this ran as an ordinary free device." -ForegroundColor Yellow
                Write-Host "        Check ADMIN_TOKEN is set on the Worker and matches -Token, then redeploy." -ForegroundColor Yellow
                $abort = $true
                break
            }
            if ($r.ErrorCode -eq "spendCeilingReached") {
                Write-Host "        The monthly spend ceiling stopped the run. Nothing further will generate." -ForegroundColor Yellow
                $abort = $true
                break
            }
            $results += [pscustomobject]@{
                Window = $spec.Label; Topic = $topic; Words = 0; Min = $spec.Min; Max = $spec.Max
                Verdict = "failed"; CostUSD = 0.0; Seconds = $seconds; File = ""
            }
            continue
        }

        $words = Get-WordCount -Text $r.Text
        $verdict = Get-Verdict -Words $words -Min $spec.Min -Max $spec.Max
        $runningCost += $r.CostUSD

        $slug = ($topic.ToLower() -replace "[^a-z0-9]+", "-").Trim("-")
        $file = Join-Path $OutDir ("{0:d2}-{1}-{2}.md" -f $index, $window, $slug)

        $frontMatter = @(
            "# $topic",
            "",
            "- **Length:** $($spec.Label) ($($spec.Format))",
            "- **Words:** $words  (budget $($spec.Min)-$($spec.Max), $verdict)",
            "- **Tokens:** $($r.InTokens) in / $($r.OutTokens) out  (output includes thinking, so it exceeds the prose)",
            ("- **Cost:** `${0:N4}" -f $r.CostUSD),
            "- **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm') in ${seconds}s",
            ""
        )
        if (-not $r.Complete) {
            $frontMatter += "> **Truncated** at the token cap (stop_reason: $($r.StopReason)). The word count above is where it was cut off, not what the model would have written."
            $frontMatter += ""
        }
        if ($r.Cached) {
            $frontMatter += "> **Served from cache** — the operator bypass should have prevented this."
            $frontMatter += ""
        }
        $frontMatter += "---"
        $frontMatter += ""

        [System.IO.File]::WriteAllText($file, (($frontMatter -join "`r`n") + $r.Text), (New-Object System.Text.UTF8Encoding $false))

        $colour = switch ($verdict) { "in budget" { "Green" } "under" { "Yellow" } default { "Yellow" } }
        Write-Host ("  {0,5} words  {1,-9}  `${2:N4}  {3}s" -f $words, $verdict, $r.CostUSD, $seconds) -ForegroundColor $colour
        if (-not $r.Complete) {
            Write-Host "        truncated at max_tokens - the lesson is cut short" -ForegroundColor Red
        }

        $results += [pscustomobject]@{
            Window = $spec.Label; Topic = $topic; Words = $words; Min = $spec.Min; Max = $spec.Max
            Verdict = $verdict; CostUSD = $r.CostUSD; Seconds = $seconds; File = (Split-Path $file -Leaf)
        }
    }
}

# ---------------------------------------------------------------------------

Write-Host ""
Write-Host ("=" * 92) -ForegroundColor DarkGray
Write-Host "Per lesson" -ForegroundColor White
Write-Host ""
Write-Host ("{0,-7} {1,-52} {2,6} {3,-12} {4,9} {5,5}" -f "Length", "Topic", "Words", "Budget", "Cost", "Secs")
Write-Host ("{0,-7} {1,-52} {2,6} {3,-12} {4,9} {5,5}" -f "------", "-----", "-----", "------", "----", "----")
foreach ($row in $results) {
    $topicCell = if ($row.Topic.Length -gt 50) { $row.Topic.Substring(0, 49) + [char]0x2026 } else { $row.Topic }
    Write-Host ("{0,-7} {1,-52} {2,6} {3,-12} {4,9} {5,5}" -f `
        $row.Window, $topicCell, $row.Words, $row.Verdict, ("`${0:N4}" -f $row.CostUSD), $row.Seconds)
}

Write-Host ""
Write-Host "By length" -ForegroundColor White
Write-Host ""
Write-Host ("{0,-7} {1,3} {2,10} {3,14} {4,11} {5,10}" -f "Length", "N", "Avg words", "Budget", "In budget", "Avg cost")
Write-Host ("{0,-7} {1,3} {2,10} {3,14} {4,11} {5,10}" -f "------", "--", "---------", "------", "---------", "--------")
foreach ($window in $plan) {
    $spec = $Windows[$window]
    $rows = @($results | Where-Object { $_.Window -eq $spec.Label -and $_.Verdict -ne "failed" })
    if ($rows.Count -eq 0) { continue }
    $avgWords = [math]::Round(($rows | Measure-Object -Property Words -Average).Average)
    $avgCost  = ($rows | Measure-Object -Property CostUSD -Average).Average
    $inBudget = @($rows | Where-Object { $_.Verdict -eq "in budget" }).Count
    Write-Host ("{0,-7} {1,3} {2,10} {3,14} {4,11} {5,10}" -f `
        $spec.Label, $rows.Count, $avgWords, "$($spec.Min)-$($spec.Max)", "$inBudget/$($rows.Count)", ("`${0:N4}" -f $avgCost))
}

$ok = @($results | Where-Object { $_.Verdict -ne "failed" })
$hit = @($results | Where-Object { $_.Verdict -eq "in budget" }).Count
Write-Host ""
Write-Host ("{0} lessons, {1} in budget, total `${2:N2}" -f $ok.Count, $hit, $runningCost) -ForegroundColor White
Write-Host "Saved to $OutDir" -ForegroundColor DarkGray

$csv = Join-Path $OutDir "summary.csv"
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "Table also written to summary.csv" -ForegroundColor DarkGray
Write-Host ""
