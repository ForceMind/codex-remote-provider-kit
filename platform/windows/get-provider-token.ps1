param(
    [Parameter(Mandatory = $true)]
    [string] $SecretFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not (Test-Path -LiteralPath $SecretFile -PathType Leaf)) {
    throw "Provider credential file is missing."
}

$encrypted = [System.IO.File]::ReadAllText($SecretFile).Trim()
if ([string]::IsNullOrWhiteSpace($encrypted)) {
    throw "Provider credential file is empty."
}

$secure = ConvertTo-SecureString $encrypted
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    [Console]::Out.Write($token)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
}
