param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile
)

$ErrorActionPreference = 'Stop'
$failed = $false

try {
    $rows = Import-Csv -LiteralPath $InputFile

    foreach ($row in $rows) {
        $path = $row.transfer_path
        $sasMd5 = $row.md5

        if ([string]::IsNullOrWhiteSpace($path) -or
            [string]::IsNullOrWhiteSpace($sasMd5)) {
            Write-Error "Missing transfer_path or SAS MD5 in verification input."
            $failed = $true
            continue
        }

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Error "Verification file does not exist: $path"
            $failed = $true
            continue
        }

        $powerShellMd5 = (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash

        if ($powerShellMd5 -ine $sasMd5) {
            Write-Error "MD5 mismatch: $path SAS=$sasMd5 PowerShell=$powerShellMd5"
            $failed = $true
        }
        else {
            Write-Host "MATCH: $path"
        }
    }
}
catch {
    Write-Error $_
    exit 2
}

if ($failed) {
    exit 1
}

exit 0
