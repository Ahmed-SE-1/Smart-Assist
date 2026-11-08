$ErrorActionPreference = 'Stop'
$idfVersion = (& idf.py --version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $idfVersion -notmatch 'ESP-IDF v5\.1\.4') {
  throw "ESP-IDF v5.1.4 is required. Active idf.py reported: $idfVersion"
}

if (-not (Test-Path -LiteralPath 'sdkconfig')) {
  & idf.py set-target esp32
  if ($LASTEXITCODE -ne 0) { throw 'idf.py set-target esp32 failed.' }
}

& idf.py reconfigure
if ($LASTEXITCODE -ne 0) { throw 'idf.py reconfigure failed.' }
& idf.py build
if ($LASTEXITCODE -ne 0) { throw 'idf.py build failed.' }
