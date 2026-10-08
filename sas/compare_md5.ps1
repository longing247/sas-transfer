# Compare MD5 hashes from Get-FileHash and certutil.
# Usage: .\compare-md5.ps1 -FilePath "C:\Data\test.csv"
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
)

$ErrorActionPreference = 'Stop'
$target = (Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).ProviderPath
$directory = Split-Path -Parent $target
$logPath = Join-Path $directory 'md5_comparison.log'

# Capture both standard output and errors in a log next to the input file.
& {
    Write-Output "File: $target"
    Write-Output "Timestamp: $(Get-Date -Format o)"
    Write-Output ''
    Write-Output '=== Get-FileHash (MD5) ==='
    $psHash = (Get-FileHash -LiteralPath $target -Algorithm MD5).Hash
    Write-Output $psHash

    Write-Output ''
    Write-Output '=== certutil (MD5) ==='
    $certOutput = & certutil.exe -hashfile $target MD5 2>&1
    $certExitCode = $LASTEXITCODE
    $certOutput | ForEach-Object { Write-Output $_ }
    if ($certExitCode -ne 0) {
        throw "certutil failed with exit code $certExitCode"
    }

    $certHashes = @($certOutput | ForEach-Object {
        $line = ([string]$_).Trim() -replace '\\s', ''
        if ($line -match '^[0-9a-fA-F]{32}$') { $line.ToUpperInvariant() }
    })
    if ($certHashes.Count -ne 1) {
        throw "Expected one MD5 from certutil; found $($certHashes.Count)"
    }

    Write-Output ''
    if ($psHash -ieq $certHashes[0]) {
        Write-Output 'RESULT: MATCH'
    } else {
        Write-Output 'RESULT: MISMATCH'
        throw 'MD5 values differ'
    }
} *> $logPath

Write-Output "Log: $logPath"
if (Select-String -LiteralPath $logPath -Pattern '^RESULT: MATCH$' -Quiet) {
    exit 0
}
exit 1
