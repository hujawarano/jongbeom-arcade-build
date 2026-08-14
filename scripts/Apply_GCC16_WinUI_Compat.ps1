param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

$properties = Join-Path $SourceRoot 'src\osd\winui\properties.cpp'
if (-not (Test-Path -LiteralPath $properties)) {
    Fail ("properties.cpp not found: " + $properties)
    exit 20
}

$text = [IO.File]::ReadAllText($properties)

# Normalize the cheatname declaration to EXACTLY one 'const'.
# This intentionally repairs all of these states:
#   char *cheatname ...
#   const char *cheatname ...
#   const const char *cheatname ...
$cheatPattern = '(?m)^(\s*)(?:const\s+)*char\s*\*\s*cheatname\s*=\s*strrchr\s*\(\s*cheatfile\s*,\s*''\\\\''\s*\)\s*;'
$cheatMatches = [regex]::Matches($text, $cheatPattern)
if ($cheatMatches.Count -ne 1) {
    Fail ("Expected exactly one cheatname declaration, found " + $cheatMatches.Count + ".")
    exit 21
}
$text = [regex]::Replace(
    $text,
    $cheatPattern,
    '$1const char *cheatname = strrchr(cheatfile, ''\\'');',
    1
)

# The controller filename buffer is intentionally modified later with *ext = 0,
# so normalize it to mutable char*.
$rootPattern = '(?m)^(\s*)(?:const\s+)*char\s*\*\s*root\s*=\s*win_utf8_from_wstring\s*\(\s*FindFileData\.cFileName\s*\)\s*;'
$rootMatches = [regex]::Matches($text, $rootPattern)
if ($rootMatches.Count -ne 1) {
    Fail ("Expected exactly one controller root declaration, found " + $rootMatches.Count + ".")
    exit 22
}
$text = [regex]::Replace(
    $text,
    $rootPattern,
    '$1char *root = win_utf8_from_wstring(FindFileData.cFileName);',
    1
)

$backup = $properties + '.before_jongbeom_gcc16_normalize'
if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $properties -Destination $backup -Force
}

[IO.File]::WriteAllText(
    $properties,
    $text,
    (New-Object Text.UTF8Encoding($false))
)

$verify = [IO.File]::ReadAllText($properties)
$goodCheat = ([regex]::Matches($verify, '(?m)^\s*const\s+char\s*\*\s*cheatname\s*=\s*strrchr\s*\(\s*cheatfile')).Count
$doubleConst = ([regex]::Matches($verify, '(?m)^\s*const\s+const\s+char\s*\*\s*cheatname')).Count
$goodRoot = ([regex]::Matches($verify, '(?m)^\s*char\s*\*\s*root\s*=\s*win_utf8_from_wstring\s*\(\s*FindFileData\.cFileName')).Count
$constRoot = ([regex]::Matches($verify, '(?m)^\s*const\s+char\s*\*\s*root\s*=\s*win_utf8_from_wstring\s*\(\s*FindFileData\.cFileName')).Count

Write-Host ("  cheatname exact const count : " + $goodCheat) -ForegroundColor White
Write-Host ("  cheatname double-const count: " + $doubleConst) -ForegroundColor White
Write-Host ("  mutable controller root     : " + $goodRoot) -ForegroundColor White
Write-Host ("  const controller root       : " + $constRoot) -ForegroundColor White

if ($goodCheat -ne 1 -or $doubleConst -ne 0 -or $goodRoot -ne 1 -or $constRoot -ne 0) {
    Fail "GCC16 properties.cpp normalization verification failed."
    exit 23
}

Ok "GCC16 properties.cpp normalized and verified."
exit 0
