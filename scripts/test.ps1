# Run the Lua API unit suite. Requires a Lua 5.4 interpreter on PATH (lua5.4, lua54
# or lua; a `lua` that is not 5.4 is refused). LuaJIT and Lua 5.1-5.3 are not supported:
# the library uses 5.4 integer and bitwise operators. No game client or native host
# needed -- the suite injects a fake `bwu` surface (spec/fake_bwu.lua).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$lua = $null
foreach ($cand in @("lua5.4", "lua54", "lua")) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if (-not $c) { continue }
    $version = & $c.Source -e "io.write(_VERSION)"
    if ($version -eq "Lua 5.4") { $lua = $c.Source; break }
    Write-Host "skipping $($c.Source): $version, not Lua 5.4"
}
if (-not $lua) { throw "No Lua 5.4 interpreter found on PATH (install lua5.4)." }
Write-Host "using $lua"
& $lua (Join-Path $root "spec\run.lua")
exit $LASTEXITCODE
