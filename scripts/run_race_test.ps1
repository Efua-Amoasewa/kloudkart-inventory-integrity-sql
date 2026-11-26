<#
.SYNOPSIS
    Run bundle/race_test.py (unmodified) several times in a row and save the evidence.

.DESCRIPTION
    "Passes every time" is what is marked, so one green run proves little. This runs the
    test $Runs times, stops at the first failure, and writes every run's output plus the
    machine and environment it ran on to evidence/race_test_runs.txt.

    Needs KLOUDKART_DB_PASSWORD set in the terminal (the password the container was
    started with). The password is never stored in the repository.

.PARAMETER Runs
    How many consecutive runs. Default 6: one run plus five repeats.

.PARAMETER Quiet
    Do not echo each run to the console (the evidence file is always written).
#>
param(
    [int]$Runs = 6,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot      = Split-Path -Parent $PSScriptRoot
$EvidenceFile  = Join-Path $RepoRoot 'evidence\race_test_runs.txt'
$RaceTest      = Join-Path $RepoRoot 'bundle\race_test.py'
$ContainerName = 'kloudkart-db'

if (-not $env:KLOUDKART_DB_PASSWORD) {
    throw 'KLOUDKART_DB_PASSWORD is not set. Run: $env:KLOUDKART_DB_PASSWORD = "<container password>"'
}
# Built from the environment so no password is ever written into the repository.
$env:DATABASE_URL = "postgresql://postgres:$($env:KLOUDKART_DB_PASSWORD)@localhost:5432/postgres"

function Get-EnvironmentReport {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)   # KB -> GB
    $pgVersion = docker exec $ContainerName psql -U postgres -At -c 'SHOW server_version;'
    $maxConn   = docker exec $ContainerName psql -U postgres -At -c 'SHOW max_connections;'
    @(
        "Recorded:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "OS:              $($os.Caption) $($os.Version)"
        "CPU:             $($cpu.Name.Trim()) ($($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads)"
        "RAM:             $ramGb GB"
        "Python:          $(python --version 2>&1)"
        "psycopg2:        $(python -c 'import psycopg2; print(psycopg2.__version__)')"
        "Docker:          $(docker --version)"
        "PostgreSQL:      $pgVersion (container $ContainerName, max_connections=$maxConn)"
        ""
    )
}

$report = [System.Collections.Generic.List[string]]::new()
$report.AddRange([string[]](Get-EnvironmentReport))

$passed = 0
for ($run = 1; $run -le $Runs; $run++) {
    $report.Add("===== run $run of $Runs =====")
    $output = python $RaceTest 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
    $report.AddRange([string[]]$output)
    if (-not $Quiet) { $output | ForEach-Object { Write-Host $_ } }
    if ($exitCode -ne 0) {
        $report.Add("STOPPED: run $run failed (exit code $exitCode)")
        break
    }
    $passed++
}
$report.Add("SUMMARY: $passed of $Runs consecutive runs passed")

Set-Content -Path $EvidenceFile -Value $report -Encoding utf8
Write-Host "SUMMARY: $passed of $Runs consecutive runs passed -> $EvidenceFile"
if ($passed -ne $Runs) { exit 1 }
