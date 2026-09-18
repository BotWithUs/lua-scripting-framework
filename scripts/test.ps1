# Run the Lua API unit suite. Requires a Lua 5.4 interpreter on PATH
# (lua, lua5.4, or luajit). No game client or native host needed -- the suite
# injects a fake `bwu` surface (spec/fake_bwu.lua).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$lua = $null
foreach ($cand in @("lua", "lua5.4", "lua54", "luajit")) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if ($c) { $lua = $c.Source; break }
}
if (-not $lua) { throw "No Lua interpreter found on PATH (install lua5.4)." }
Write-Host "using $lua"
& $lua (Join-Path $root "spec\run.lua")
exit $LASTEXITCODE
