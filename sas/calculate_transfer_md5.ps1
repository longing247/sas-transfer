param(
    [Parameter(Mandatory=$true)][string]$InputCsv,
    [Parameter(Mandatory=$true)][string]$OutputCsv
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$results = @()
if (-not (Test-Path -LiteralPath $InputCsv)) { throw 'Input manifest CSV is missing.' }
foreach ($row in (Import-Csv -LiteralPath $InputCsv)) {
    $status = 'OK'; $message = ''; $hash = ''
    try {
        $path = [string]$row.transfer_path
        # SAS already extracted the selected ZIP member to transfer_path.
        # Hash that physical file; verify every same-named ZIP member independently.
        $hash = (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash
        if ($row.source_type -eq 'ZIP' -and
            -not [string]::Equals($path, [string]$row.directory_path, [StringComparison]::OrdinalIgnoreCase)) {
            $zip = [IO.Compression.ZipFile]::OpenRead([string]$row.directory_path)
            try {
                $matches = @($zip.Entries | Where-Object {
                    $_.Name -and $_.Name.Equals([string]$row.transfer_name, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($matches.Count -eq 0) { throw 'Requested file not found in ZIP.' }
                foreach ($entry in $matches) {
                    $temp = [IO.Path]::GetTempFileName()
                    try {
                        $source = $entry.Open()
                        try {
                            $dest = [IO.File]::Create($temp)
                            try { $source.CopyTo($dest) }
                            finally { $dest.Dispose() }
                        }
                        finally { $source.Dispose() }
                        $memberHash = (Get-FileHash -LiteralPath $temp -Algorithm MD5).Hash
                        if ($memberHash -ne $hash) {
                            throw 'Extracted ZIP member differs from another same-named ZIP member.'
                        }
                    }
                    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
                }
            }
            finally { $zip.Dispose() }
        }
    }
    catch { $status = 'ERROR'; $message = $_.Exception.Message }
    $results += [pscustomobject]@{row_id=$row.row_id; md5=$hash; status=$status; message=$message}
}
$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
if (@($results | Where-Object { $_.status -eq 'ERROR' }).Count -gt 0) { exit 1 }
