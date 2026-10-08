# Run both MD5 commands and save their output beside the target file.
# Usage: .\compare_md5.ps1 -FilePath "C:\Data\test.csv"
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
)

$target = (Resolve-Path -LiteralPath $FilePath -ErrorAction Stop).ProviderPath
$logPath = Join-Path (Split-Path -Parent $target) 'md5_comparison.log'

& {
    Write-Output '=== Get-FileHash ==='
    Get-FileHash -LiteralPath $target -Algorithm MD5 | Format-List *

    Write-Output '=== certutil ==='
    & certutil.exe -hashfile $target MD5 2>&1
} *> $logPath

Write-Output "Output saved to: $logPath"
