$ErrorActionPreference = 'Stop'

$python = Get-Command python -ErrorAction Stop
$watcher = Join-Path $PSScriptRoot 'watcher.py'
& $python.Source $watcher check
exit $LASTEXITCODE
