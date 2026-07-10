# PromptParle bootstrap — always works with irm|iex
# Downloads install script to a temp FILE then executes it (param-safe).
$ErrorActionPreference = 'Stop'
$uri = 'https://promptparle.com/install.ps1'
$dest = Join-Path $env:TEMP ('PromptParle-install-' + [guid]::NewGuid().ToString('n') + '.ps1')
Write-Host "Downloading $uri ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $uri -OutFile $dest -UseBasicParsing
Write-Host "Running $dest" -ForegroundColor DarkGray
try {
  & $dest
} finally {
  Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
}
