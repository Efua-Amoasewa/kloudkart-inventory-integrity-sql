<#
.SYNOPSIS
    Time the report, rollup and write scenarios and save the figures as evidence.

.DESCRIPTION
    For each scenario: one warm-up run (discarded), then $Runs timed runs. Each run is
    EXPLAIN (ANALYZE) inside PostgreSQL, so the figure is the server's own "Execution Time":
    from the start to the end of executing the statement, excluding network transfer of
    the result rows to the client. Writes go inside a transaction that is rolled back.

    -Stage before  times the plain-view report (sql/05) and the index-free orders table.
    -Stage after   times the stored report (sql/07) and the indexed orders table.

    Output: evidence/performance_<stage>.txt (summary table, environment, one full plan
    per scenario).

.PARAMETER Stage
    'before' or 'after'.

.PARAMETER Runs
    Timed runs per scenario. 20 makes the 95th percentile the 19th-fastest run rather
    than simply the worst.

.PARAMETER Quiet
    Do not print the summary table (the evidence file is always written).
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('before', 'after')][string]$Stage,
    [int]$Runs = 20,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot      = Split-Path -Parent $PSScriptRoot
$ContainerName = 'kloudkart-db'
$EvidenceFile  = Join-Path $RepoRoot "evidence\performance_$Stage.txt"
# PowerShell variable names ignore case, so this must not be called $P95: the per-scenario
# result $p95 would overwrite it.
$Percentile95Fraction = 0.95

# The top-ranked person in the extract; any real customer id would do for the lookup.
$LookupCustomerId = 116661

# Scenario -> SQL per stage. The 'after' SQL reads what Adwoa reads once sql/07 is applied.
$Scenarios = [ordered]@{
    'Monday report: every customer summary' = @{
        before = 'SELECT * FROM report_customer_summary'
        after  = 'SELECT * FROM monday_customer_summary' }
    'Monday report: top 100' = @{
        before = 'SELECT * FROM report_top_100'
        after  = 'SELECT * FROM monday_top_100' }
    'Monday report: running total, every order' = @{
        before = 'SELECT * FROM report_order_running_total'
        after  = 'SELECT * FROM monday_order_running_total' }
    'Monday report: monthly spend, trailing 12' = @{
        before = 'SELECT * FROM report_monthly_spend'
        after  = 'SELECT * FROM monday_monthly_spend' }
    'Low-stock rollup (live view, unchanged)' = @{
        before = 'SELECT * FROM low_stock_by_category'
        after  = 'SELECT * FROM low_stock_by_category' }
    "One customer's orders (lookup)" = @{
        before = "SELECT order_id, order_date, total_amount FROM orders WHERE customer_id = $LookupCustomerId"
        after  = "SELECT order_id, order_date, total_amount FROM orders WHERE customer_id = $LookupCustomerId" }
    'Write cost: insert 1,000 orders (rolled back)' = @{
        # Negative ids keep the test rows clear of real and future order ids.
        before = "INSERT INTO orders (order_id, customer_id, order_date, status, total_amount) SELECT -g, $LookupCustomerId, now(), 'completed', 1 FROM generate_series(1, 1000) AS g"
        after  = "INSERT INTO orders (order_id, customer_id, order_date, status, total_amount) SELECT -g, $LookupCustomerId, now(), 'completed', 1 FROM generate_series(1, 1000) AS g" }
}

function Invoke-Psql([string]$Sql) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = $Sql | docker exec -i $ContainerName psql -U postgres -X -At -v ON_ERROR_STOP=1 2>&1 |
        ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "psql failed ($code): $($out -join ' ')" }
    return $out
}

function Get-ExecutionMs([string]$Sql, [string]$Options) {
    # Rolled back so write scenarios leave nothing behind; harmless for reads.
    $plan = Invoke-Psql "BEGIN; EXPLAIN ($Options) $Sql; ROLLBACK;"
    $line = $plan | Where-Object { $_ -match 'Execution Time: ([\d.]+) ms' } | Select-Object -First 1
    if (-not $line) { throw "No execution time in plan for: $Sql" }
    [void]($line -match 'Execution Time: ([\d.]+) ms')
    return @{ Ms = [double]$Matches[1]; Plan = $plan }
}

function Get-Percentile([double[]]$Sorted, [double]$Fraction) {
    # Nearest-rank method: the value at position ceil(Fraction * n).
    $rank = [math]::Ceiling($Fraction * $Sorted.Count)
    return $Sorted[$rank - 1]
}

function Get-EnvironmentLines {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)   # KB -> GB
    $pg = Invoke-Psql 'SHOW server_version;'
    $counts = Invoke-Psql "SELECT 'orders ' || count(*) FROM orders UNION ALL SELECT 'customers ' || count(*) FROM customers UNION ALL SELECT 'products ' || count(*) FROM products;"
    @(
        "Recorded:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "OS:         $($os.Caption) $($os.Version)"
        "CPU:        $($cpu.Name.Trim()) ($($cpu.NumberOfCores) cores, $($cpu.NumberOfLogicalProcessors) threads)"
        "RAM:        $ramGb GB"
        "Docker:     $(docker --version)"
        "PostgreSQL: $pg in container $ContainerName (default memory settings)"
        "Data:       $($counts -join ', ')"
        "Method:     1 warm-up run discarded, then $Runs runs; EXPLAIN (ANALYZE) Execution Time;"
        "            warm cache; median and nearest-rank p95 reported; writes rolled back."
        ""
    )
}

$summary = [System.Collections.Generic.List[string]]::new()
$plans   = [System.Collections.Generic.List[string]]::new()
$summary.Add('| Scenario | Runs | Median ms | p95 ms | Worst ms |')
$summary.Add('|---|---|---|---|---|')

foreach ($name in $Scenarios.Keys) {
    $sql = $Scenarios[$name][$Stage]
    try {
        [void](Get-ExecutionMs $sql 'ANALYZE')                         # warm-up, discarded
        $times = for ($i = 1; $i -le $Runs; $i++) { (Get-ExecutionMs $sql 'ANALYZE').Ms }
        $sorted = [double[]]($times | Sort-Object)
        $median = Get-Percentile $sorted 0.5
        $p95    = Get-Percentile $sorted $Percentile95Fraction
        $worst  = $sorted[-1]
        $summary.Add(("| {0} | {1} | {2:N2} | {3:N2} | {4:N2} |" -f $name, $Runs, $median, $p95, $worst))

        $full = Get-ExecutionMs $sql 'ANALYZE, BUFFERS'
        $plans.Add("===== $name")
        $plans.Add($sql)
        $plans.AddRange([string[]]$full.Plan)
        $plans.Add('')
    } catch {
        throw "Scenario '$name' failed: $($_.Exception.Message)"
    }
}

$fileLines = [System.Collections.Generic.List[string]]::new()
$fileLines.Add("Performance measurement - stage: $Stage")
$fileLines.AddRange([string[]](Get-EnvironmentLines))
$fileLines.AddRange($summary)
$fileLines.Add('')
$fileLines.Add('Plans (EXPLAIN ANALYZE, BUFFERS), one run per scenario:')
$fileLines.AddRange($plans)
Set-Content -Path $EvidenceFile -Value $fileLines -Encoding utf8

if (-not $Quiet) { $summary | ForEach-Object { Write-Host $_ } }
Write-Host "Saved -> $EvidenceFile"
