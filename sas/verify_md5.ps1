param([string]$InputFile)

$ErrorActionPreference = "Stop"

try {
    Import-Csv $InputFile | ForEach-Object {

        $actual = (Get-FileHash $_.transfer_path -Algorithm MD5).Hash

        if ($actual -ne $_.md5) {
            Write-Host "MISMATCH: $($_.transfer_path)"
            exit 1
        }
    }
}
catch {
    Write-Host "ERROR: $_"
    exit 1
}

exit 0
