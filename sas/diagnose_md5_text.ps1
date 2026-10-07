param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath
)

$ErrorActionPreference = "Stop"

$b = [IO.File]::ReadAllBytes($FilePath)
$md5 = [Security.Cryptography.MD5]::Create()

"RAW       : " + ([BitConverter]::ToString($md5.ComputeHash($b)) -replace '-','')

$s = [Text.Encoding]::UTF8.GetString($b)
$lf = [Text.Encoding]::UTF8.GetBytes($s -replace "`r`n","`n")

"CRLF -> LF: " + ([BitConverter]::ToString($md5.ComputeHash($lf)) -replace '-','')
