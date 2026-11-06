# Windows test suite for this host. Mirrors scripts/test_cpu.sh, then scripts/test_gpu.sh.
#   powershell -ExecutionPolicy Bypass -File scripts\test_suite.ps1
#
# CPU defaults:  BENCH_SECS=5   SMOKE_MAX=200000
# GPU defaults:  BENCH_SECS=1   PROFILE_SECS=1   SMOKE_MAX=500000
#   $env:SKIP_BENCH=1; $env:SKIP_PROFILE=1   # GPU: gputest + smoke only
# Matching file cases (both modes):
#   examples\matching_888888.txt  and  examples\matching.txt
# Smoke results (may contain private keys) go to run\results\, which is gitignored.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "build\tron_vanity_generator.exe"
$outDir = Join-Path $root "run\results"

$cpuBenchSecs = if ($env:CPU_BENCH_SECS) { $env:CPU_BENCH_SECS } elseif ($env:BENCH_SECS) { $env:BENCH_SECS } else { "5" }
$gpuBenchSecs = if ($env:GPU_BENCH_SECS) { $env:GPU_BENCH_SECS } elseif ($env:BENCH_SECS) { $env:BENCH_SECS } else { "1" }
$profileSecs = if ($env:PROFILE_SECS) { $env:PROFILE_SECS } else { "1" }
$cpuSmoke = if ($env:SMOKE_MAX_CPU) { $env:SMOKE_MAX_CPU } elseif ($env:SMOKE_MAX) { $env:SMOKE_MAX } else { "200000" }
$gpuSmoke = if ($env:SMOKE_MAX_GPU) { $env:SMOKE_MAX_GPU } elseif ($env:SMOKE_MAX) { $env:SMOKE_MAX } else { "500000" }
$skipBench = ($env:SKIP_BENCH -eq "1")
$skipProfile = ($env:SKIP_PROFILE -eq "1")

$match888 = Join-Path $root "examples\matching_888888.txt"
$matchFile = Join-Path $root "examples\matching.txt"

if (-not (Test-Path $bin)) {
    Write-Host "Binary missing, running build.ps1 ..."
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root "build.ps1")
    if ($LASTEXITCODE) { throw "build.ps1 failed ($LASTEXITCODE)" }
}
foreach ($f in @($match888, $matchFile)) {
    if (-not (Test-Path $f)) { throw "Matching file not found: $f" }
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Section([string]$Name) {
    Write-Host ""
    Write-Host "======== $Name ========"
}

function Invoke-Bin {
    param(
        [Parameter(Mandatory = $true)][string[]]$BinArgs
    )
    # Native stderr must not become a terminating error under ErrorAction Stop.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $bin @BinArgs 2>&1 | ForEach-Object { Write-Host $_.ToString() }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) {
        throw "exit ${code}: $bin $($BinArgs -join ' ')"
    }
}

# parseArgs failure (bad --matching file) still exits 0, so matching runs must
# show the template banner. ASCII marker is ", OR)" on that line.
# GPU --list exits 0 with no device, so require a " CU" line from the OpenCL device.
function Invoke-BinChecked {
    param(
        [Parameter(Mandatory = $true)][string[]]$BinArgs,
        [string]$Expect,
        [string]$Reject,
        [string]$LogName
    )
    $log = Join-Path $outDir $LogName
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $bin @BinArgs 2>&1 | ForEach-Object {
        $line = $_.ToString()
        Write-Host $line
        Add-Content -Path $log -Value $line -Encoding utf8
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { throw "exit ${code}: $bin $($BinArgs -join ' ')" }
    $text = Get-Content -Path $log -Raw -Encoding utf8
    if ($Reject -and $text -match $Reject) { throw "rejected output matched /$Reject/ in $log" }
    if ($Expect -and $text -notmatch $Expect) { throw "missing /$Expect/ in $log" }
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

Write-Host "Suite root : $root"
Write-Host "Binary     : $bin"
Write-Host "Results    : $outDir"

# ---------------------------------------------------------------------------
# CPU  (scripts/test_cpu.sh)
# ---------------------------------------------------------------------------
Section "selftest (known privkey -> TRON address)"
Invoke-Bin -BinArgs @("--selftest")

Section "hashtest (SHA-256 / Keccak-256)"
Invoke-Bin -BinArgs @("--hashtest")

Section "matchtest (builtin tail rules)"
Invoke-Bin -BinArgs @("--matchtest")

Section "matchruletest (template prefix/suffix rules)"
Invoke-Bin -BinArgs @("--matchruletest")

Section "hardware (--list)"
Invoke-Bin -BinArgs @("--list")

Section "cpubench (${cpuBenchSecs}s, default threads)"
Invoke-Bin -BinArgs @("--cpubench", $cpuBenchSecs)

$threads = [Environment]::ProcessorCount
if ($threads -gt 4) {
    Section "cpubench (${cpuBenchSecs}s, --threads 4)"
    Invoke-Bin -BinArgs @("--cpubench", $cpuBenchSecs, "--threads", "4")
}

Section "smoke run (--backend cpu --max $cpuSmoke, --min 5)"
Invoke-Bin -BinArgs @(
    "--backend", "cpu", "--max", $cpuSmoke, "--min", "5",
    "--output", (Join-Path $outDir "cpu_smoke.txt")
)

Section "smoke matching file matching_888888.txt (--backend cpu --max $cpuSmoke)"
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $outDir "cpu_matching_888888.log")
Invoke-BinChecked -LogName "cpu_matching_888888.log" -Expect ', OR\)' -BinArgs @(
    "--backend", "cpu", "--max", $cpuSmoke,
    "--matching", $match888, "--suffix-count", "6",
    "--output", (Join-Path $outDir "cpu_smoke_matching_888888.txt")
)

Section "smoke matching file matching.txt (--backend cpu --max $cpuSmoke)"
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $outDir "cpu_matching.log")
Invoke-BinChecked -LogName "cpu_matching.log" -Expect ', OR\)' -BinArgs @(
    "--backend", "cpu", "--max", $cpuSmoke,
    "--matching", $matchFile, "--suffix-count", "6",
    "--output", (Join-Path $outDir "cpu_smoke_matching.txt")
)

Write-Host ""
Write-Host "CPU tests passed."

# ---------------------------------------------------------------------------
# GPU  (scripts/test_gpu.sh)
# ---------------------------------------------------------------------------
Section "OpenCL / GPU detect (--list)"
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $outDir "gpu_list.log")
Invoke-BinChecked -LogName "gpu_list.log" -Expect " CU" -BinArgs @("--list")

Section "matchruletest (template prefix/suffix rules)"
Invoke-Bin -BinArgs @("--matchruletest")

Section "gputest (GPU kernel vs CPU, Montgomery N=2..32)"
Invoke-Bin -BinArgs @("--gputest")

if (-not $skipBench) {
    Section "bench (${gpuBenchSecs}s each tier, ECW / MONT / KPI / tail rules)"
    Invoke-Bin -BinArgs @("--bench", $gpuBenchSecs)
}

if (-not $skipProfile) {
    Section "profile (${profileSecs}s, kernel stage share)"
    Invoke-Bin -BinArgs @("--profile", $profileSecs)
}

Section "smoke run (--backend gpu --max $gpuSmoke, --min 5)"
Invoke-Bin -BinArgs @(
    "--backend", "gpu", "--max", $gpuSmoke, "--min", "5",
    "--output", (Join-Path $outDir "gpu_smoke.txt")
)

Section "smoke matching file matching_888888.txt (--backend gpu --max $gpuSmoke)"
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $outDir "gpu_matching_888888.log")
Invoke-BinChecked -LogName "gpu_matching_888888.log" -Expect ', OR\)' -BinArgs @(
    "--backend", "gpu", "--max", $gpuSmoke,
    "--matching", $match888, "--suffix-count", "6",
    "--output", (Join-Path $outDir "gpu_smoke_matching_888888.txt")
)

Section "smoke matching file matching.txt (--backend gpu --max $gpuSmoke)"
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $outDir "gpu_matching.log")
Invoke-BinChecked -LogName "gpu_matching.log" -Expect ', OR\)' -BinArgs @(
    "--backend", "gpu", "--max", $gpuSmoke,
    "--matching", $matchFile, "--suffix-count", "6",
    "--output", (Join-Path $outDir "gpu_smoke_matching.txt")
)

Write-Host ""
Write-Host "GPU tests passed."
Write-Host "All tests passed."
