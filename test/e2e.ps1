$ErrorActionPreference = "Stop"

$ClumiesRaw = if ($env:CLUMSIES) { $env:CLUMSIES } else { ".\zig-out\bin\clumsies.exe" }
$Clumsies = (Resolve-Path $ClumiesRaw).Path

$TmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("clumsies-e2e-" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $TmpBase -Force | Out-Null
$HomeDir = Join-Path $TmpBase "home"
New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null
$env:HOME = $HomeDir
$env:USERPROFILE = $HomeDir

$Pass = 0
$Fail = 0

function Step($msg) { Write-Host "`n=== $msg ===" }

function Assert-Output($desc, $expected, $actual) {
    if ($actual -match [regex]::Escape($expected)) {
        Write-Host "  OK: $desc"
        $script:Pass++
    } else {
        Write-Host "  FAIL: $desc"
        Write-Host "  Expected to contain: $expected"
        Write-Host "  Actual: $actual"
        $script:Fail++
        throw "Assertion failed: $desc"
    }
}

try {
    # 1. Bare invocation
    Step "1. bare invocation"
    $output = & $Clumsies 2>&1 | Out-String
    Assert-Output "shows TUI placeholder" "TUI Dashboard" $output
    Assert-Output "shows help" "clumsies login" $output

    # 2. Help
    Step "2. help"
    $output = & $Clumsies help 2>&1 | Out-String
    Assert-Output "help lists login" "login" $output
    Assert-Output "help lists init" "init" $output
    Assert-Output "help lists sync" "sync" $output
    Assert-Output "help lists mcp" "mcp" $output

    # 3. Version
    Step "3. version"
    $output = & $Clumsies --version 2>&1 | Out-String
    Assert-Output "version shown" "clumsies" $output

    # 4. Unknown command
    Step "4. unknown command"
    $output = & $Clumsies add 2>&1 | Out-String
    Assert-Output "unknown command error" "unknown command" $output

    # 5. Old commands rejected
    Step "5. old commands rejected"
    foreach ($cmd in @("remote", "pull", "push", "clone", "status", "log", "ls", "rm", "show", "set", "get", "pub", "stats", "config", "upgrade")) {
        $output = & $Clumsies $cmd 2>&1 | Out-String
        Assert-Output "old command '$cmd' rejected" "unknown command" $output
    }

    # 6. Login help
    Step "6. login help"
    $output = & $Clumsies login -h 2>&1 | Out-String
    Assert-Output "login help shown" "hub-url" $output

    # 7. Init help
    Step "7. init help"
    $output = & $Clumsies init -h 2>&1 | Out-String
    Assert-Output "init help shown" "create" $output

    # 8. Sync without workspace
    Step "8. sync without workspace"
    $output = & $Clumsies sync 2>&1 | Out-String
    Assert-Output "sync requires init" "clumsies init" $output

    # 9. MCP help
    Step "9. mcp help"
    $output = & $Clumsies mcp 2>&1 | Out-String
    Assert-Output "mcp help shown" "serve" $output

} catch {
    Write-Host "Error: $_"
} finally {
    Remove-Item -Recurse -Force $TmpBase -ErrorAction SilentlyContinue
}

Write-Host "`n=== Results: $Pass passed, $Fail failed ==="
if ($Fail -gt 0) { exit 1 }
