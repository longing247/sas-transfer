param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

$ErrorActionPreference = "Stop"

$b = [IO.File]::ReadAllBytes($FilePath)
$md5 = [Security.Cryptography.MD5]::Create()

"RAW       : " + ([BitConverter]::ToString($md5.ComputeHash($b)) -replace '-','')

# Replace CRLF bytes (0D 0A) with LF (0A) directly.
# This avoids text-encoding conversion and works in Windows PowerShell.
$ms = New-Object IO.MemoryStream

for ($i = 0; $i -lt $b.Length; $i++) {
    if ($i -lt ($b.Length - 1) -and $b[$i] -eq 13 -and $b[$i + 1] -eq 10) {
        $ms.WriteByte(10)
        $i++
    }
    else {
        $ms.WriteByte($b[$i])
    }
}

$lf = $ms.ToArray()
$ms.Dispose()

"CRLF -> LF: " + ([BitConverter]::ToString($md5.ComputeHash($lf)) -replace '-','')
$md5.Dispose()
