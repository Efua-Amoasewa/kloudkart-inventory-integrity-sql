<#
.SYNOPSIS
    Fresh load: rebuild the Kloud Kart database from the bundle and run every SQL file in order.

.DESCRIPTION
    1. Removes the kloudkart-db container if it exists (all data in it is lost - on purpose).
    2. Starts PostgreSQL 18 with the connection headroom race_test.py needs.
    3. Waits until the server accepts TCP connections.
    4. Loads bundle/schema.sql and bundle/load.sql exactly as shipped.
    5. Runs sql/00 ... sql/08 in order, stopping at the first error.

    The repository root is mounted at /lab inside the container. Run it from anywhere;
    paths are resolved from this script's location.

    Needs KLOUDKART_DB_PASSWORD set in the terminal. The password is never stored in the
    repository.

.PARAMETER Quiet
    Hide each file's psql output; stage headings and errors are always shown.
#>
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$ContainerName = 'kloudkart-db'
$ImageName     = 'postgres:18'      # the module is written and graded against PostgreSQL 18
$HostPort      = 5432
# race_test.py test 2 opens 400 connections at once and the server default is 100.
# 500 leaves headroom for the test's own setup connections and a psql session.
$MaxConnections      = 500
$ReadyTimeoutSeconds = 60           # first start initialises the data directory, ~5-10 s

# The solution, in the order it must run. Each file depends on the ones before it.
$SolutionFiles = @(
    'sql/00_check_setup.sql'
    'sql/01_integrity_checks.sql'
    'sql/02_schema_fixes.sql'
    'sql/03_audit_trail.sql'
    'sql/04_place_order.sql'
    'sql/05_monday_report.sql'
    'sql/06_category_rollup.sql'
    'sql/07_performance.sql'
    'sql/08_improvement.sql'
)

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What exited with code $LASTEXITCODE" }
}

function Invoke-Stage([string]$StageName, [scriptblock]$Body) {
    Write-Host "==> $StageName"
    try {
        & $Body
    } catch {
        throw "Stage '$StageName' failed: $($_.Exception.Message)"
    }
}

function Get-DbPassword {
    if (-not $env:KLOUDKART_DB_PASSWORD) {
        throw 'KLOUDKART_DB_PASSWORD is not set. Run: $env:KLOUDKART_DB_PASSWORD = "<choose one>"'
    }
    return $env:KLOUDKART_DB_PASSWORD
}

function Invoke-PsqlFile([string]$WorkingDir, [string]$FileName) {
    # psql writes NOTICEs to stderr; Windows PowerShell 5.1 turns redirected stderr into
    # error records, so success is judged by psql's exit code (ON_ERROR_STOP=1), not stderr.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = docker exec -w $WorkingDir $ContainerName `
            psql -U postgres -v ON_ERROR_STOP=1 -f $FileName 2>&1 | ForEach-Object { "$_" }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        $output | ForEach-Object { Write-Host $_ }       # always show the output of a failure
        throw "psql -f $FileName exited with code $exitCode"
    }
    if (-not $Quiet) { $output | ForEach-Object { Write-Host $_ } }
}

function Remove-OldContainer {
    $existing = docker ps -a --filter "name=^$ContainerName$" --format '{{.Names}}'
    Assert-LastExit 'docker ps'
    if ($existing) {
        docker rm -f $ContainerName | Out-Null
        Assert-LastExit 'docker rm'
    }
}

function Start-Container {
    $dbPassword = Get-DbPassword
    docker run -d --name $ContainerName `
        -e "POSTGRES_PASSWORD=$dbPassword" `
        -p "${HostPort}:5432" `
        -v "${RepoRoot}:/lab" `
        $ImageName -c "max_connections=$MaxConnections" | Out-Null
    Assert-LastExit 'docker run'
}

function Wait-ForServer {
    # Checking over TCP (-h 127.0.0.1) skips the temporary socket-only server the image
    # runs during first-time initialisation, so "ready" means the real server is up.
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        docker exec $ContainerName pg_isready -h 127.0.0.1 -U postgres -q 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 1
    }
    throw "PostgreSQL did not accept connections within $ReadyTimeoutSeconds s"
}

$started = Get-Date
Invoke-Stage 'Check password is set'         { Get-DbPassword | Out-Null }
Invoke-Stage 'Remove old container'          { Remove-OldContainer }
Invoke-Stage 'Start PostgreSQL 18 container' { Start-Container }
Invoke-Stage 'Wait for server'               { Wait-ForServer }
Invoke-Stage 'Load bundle/schema.sql'        { Invoke-PsqlFile '/lab/bundle' 'schema.sql' }
Invoke-Stage 'Load bundle/load.sql'          { Invoke-PsqlFile '/lab/bundle' 'load.sql' }
foreach ($file in $SolutionFiles) {
    Invoke-Stage "Run $file" { Invoke-PsqlFile '/lab' $file }
}
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds)
Write-Host "==> Fresh load complete: schema, data and all $($SolutionFiles.Count) solution files in $elapsed s"
