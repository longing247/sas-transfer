param(
    [Parameter(Mandatory=$true)][string]$InputCsv,
    [Parameter(Mandatory=$true)][string]$OutputCsv
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$results = @()
foreach ($row in (Import-Csv -LiteralPath $InputCsv)) {
    $status = 'OK'; $message = ''; $hash = ''
    try {
        $path = [string]$row.transfer_path
        if ($row.source_type -eq 'ZIP' -and $row.whole_zip -eq '0') {
            $zip = [IO.Compression.ZipFile]::OpenRead([string]$row.directory_path)
            try {
                $matches = @($zip.Entries | Where-Object {
                    $_.Name -and $_.Name.Equals([string]$row.transfer_name, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($matches.Count -eq 0) { throw 'Requested file not found in ZIP.' }
                $first = $null
                foreach ($entry in $matches) {
                    $stream = $entry.Open()
                    try {
                        $algorithm = [Security.Cryptography.MD5]::Create()
                        try { $value = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','') }
                        finally { $algorithm.Dispose() }
                    }
                    finally { $stream.Dispose() }
                    if ($null -eq $first) { $first = $value }
                    elseif ($value -ne $first) { throw 'Duplicate ZIP members have different MD5 values.' }
                }
                $parent = [IO.Path]::GetDirectoryName($path)
                if (-not [IO.Directory]::Exists($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
                $inputStream = $matches[0].Open()
                try {
                    $outputStream = [IO.File]::Create($path)
                    try { $inputStream.CopyTo($outputStream) }
                    finally { $outputStream.Dispose() }
                }
                finally { $inputStream.Dispose() }
                $hash = (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash
                if ($hash -ne $first) { throw 'Extracted ZIP member MD5 mismatch.' }
            }
            finally { $zip.Dispose() }
        }
        else {
            $hash = (Get-FileHash -LiteralPath $path -Algorithm MD5).Hash
        }
    }
    catch { $status = 'ERROR'; $message = $_.Exception.Message }
    $results += [pscustomobject]@{row_id=$row.row_id; md5=$hash; status=$status; message=$message}
}
$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
if (@($results | Where-Object { $_.status -eq 'ERROR' }).Count -gt 0) { exit 1 }
