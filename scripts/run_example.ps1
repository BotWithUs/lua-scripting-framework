# Run a lua-scripting-framework example under the native host (bwu_host).
#
#   scripts\run_example.ps1 examples\banker.lua
#
# bwu_host.exe (from native-scripting-host) must be on PATH, or point $env:BWU_HOST at it.
# It embeds Lua 5.4 and installs the global `bwu`, and needs a live game client to attach to.
# This script just puts the repo root on Lua's module path so `require("botwithus")` resolves.
param(
    [Parameter(Mandatory = $true)][string]$Example
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$hostExe = if ($env:BWU_HOST) { $env:BWU_HOST } else { "bwu_host.exe" }

# Lua reads LUA_PATH at startup; the trailing ";;" keeps the interpreter's own default.
$rp = $root -replace '\\', '/'
$env:LUA_PATH = "$rp/?.lua;$rp/?/init.lua;;"

$file = if (Test-Path $Example) { (Resolve-Path $Example).Path } else { Join-Path $root $Example }
Write-Host "running $file under $hostExe"
& $hostExe --lua $file
exit $LASTEXITCODE
