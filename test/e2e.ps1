$ErrorActionPreference = "Stop"

$ClumiesRaw = if ($env:CLUMSIES) { $env:CLUMSIES } else { ".\zig-out\bin\clumsies.exe" }
$Clumsies = (Resolve-Path $ClumiesRaw).Path
$TmpBase = Join-Path ([System.IO.Path]::GetTempPath()) "clumsies-e2e-$(Get-Random)"
New-Item -ItemType Directory -Path $TmpBase -Force | Out-Null

$Registry = Join-Path $TmpBase "mock-registry"
$Workspace = Join-Path $TmpBase "workspace"
$HomeDir = Join-Path $TmpBase "home"
New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null

$env:USERPROFILE = $HomeDir
$env:HOME = $HomeDir

$Pass = 0
$Fail = 0

function Step($msg) { Write-Host "`n=== $msg ===" }

function Assert($desc, [scriptblock]$test) {
    try {
        $result = & $test
        if ($result -eq $false) { throw "returned false" }
        Write-Host "  OK: $desc"
        $script:Pass++
    } catch {
        Write-Host "  FAIL: $desc"
        Write-Host "  Error: $_"
        $script:Fail++
        throw "Assertion failed: $desc"
    }
}

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

function Assert-FileContains($desc, $file, $pattern) {
    if ((Test-Path $file) -and (Select-String -Path $file -Pattern $pattern -SimpleMatch -Quiet)) {
        Write-Host "  OK: $desc"
        $script:Pass++
    } else {
        Write-Host "  FAIL: $desc"
        Write-Host "  File: $file"
        Write-Host "  Expected pattern: $pattern"
        $script:Fail++
        throw "Assertion failed: $desc"
    }
}

function Assert-FileNotContains($desc, $file, $pattern) {
    if (-not (Test-Path $file) -or -not (Select-String -Path $file -Pattern $pattern -SimpleMatch -Quiet)) {
        Write-Host "  OK: $desc"
        $script:Pass++
    } else {
        Write-Host "  FAIL: $desc"
        Write-Host "  File: $file"
        Write-Host "  Should NOT contain: $pattern"
        $script:Fail++
        throw "Assertion failed: $desc"
    }
}

try {
    # Git identity for the test HOME
    git config --global user.email "test@test.com"
    git config --global user.name "Test"

    # Setup mock registry
    Step "Setup mock registry"
    New-Item -ItemType Directory -Path $Registry -Force | Out-Null
    git -C $Registry init -b main
    git -C $Registry commit --allow-empty -m "init"
    New-Item -ItemType Directory -Path "$Registry\prompts" -Force | Out-Null
    New-Item -ItemType Directory -Path "$Registry\bundles" -Force | Out-Null
    '{"prompts":[]}' | Set-Content "$Registry\prompts\index.json" -Encoding UTF8
    '{"bundles":[]}' | Set-Content "$Registry\bundles\index.json" -Encoding UTF8
    git -C $Registry add -A
    git -C $Registry commit -m "scaffold"
    Write-Host "  Registry at: $Registry"

    # Setup workspace
    Step "Setup workspace"
    New-Item -ItemType Directory -Path "$Workspace\.prompts\rule\coding" -Force | Out-Null
    "# Test Coding Rule`n`nAlways use snake_case.`n" | Set-Content "$Workspace\.prompts\rule\coding\00_SNAKE_CASE.md" -Encoding UTF8
    New-Item -ItemType Directory -Path "$Workspace\.prompts\rule\testing" -Force | Out-Null
    "# Test Testing Rule`n`nWrite tests first.`n" | Set-Content "$Workspace\.prompts\rule\testing\00_TDD.md" -Encoding UTF8
    Set-Location $Workspace

    # 1. config set registry
    Step "1. config set registry"
    & $Clumsies config set registry $Registry
    $ConfigPath = Join-Path $HomeDir ".clumsies\config.json"
    Assert "config.json exists" { Test-Path $ConfigPath }
    Assert-FileContains "config.json contains registry" $ConfigPath "mock-registry"

    # 2. add with explicit -c
    Step "2. add with -c flag"
    & $Clumsies add ".prompts\rule\coding\00_SNAKE_CASE.md" -c "rule/coding" -Q
    $PromptsIndex = Join-Path $HomeDir ".clumsies\registry\prompts\index.json"
    Assert "prompts/index.json exists" { Test-Path $PromptsIndex }
    Assert-FileContains "index has SNAKE_CASE entry" $PromptsIndex "SNAKE_CASE"
    Assert-FileContains "category uses forward slash" $PromptsIndex "rule/coding"

    # 3. add directory (derive category from path)
    Step "3. add directory (derive category)"
    & $Clumsies add ".prompts\rule\testing\" -Q
    Assert-FileContains "index has TDD entry" $PromptsIndex "TDD"
    Assert-FileContains "derived category uses forward slash" $PromptsIndex "rule/testing"
    Assert-FileNotContains "no backslash in categories" $PromptsIndex 'rule\\testing'

    # Extract hash
    $HashLine = Select-String -Path $PromptsIndex -Pattern '"hash": "([a-f0-9]+)"' | Select-Object -First 1
    $Hash = $HashLine.Matches[0].Groups[1].Value
    $ShortHash = $Hash.Substring(0, 8)
    Write-Host "  Using hash: $ShortHash"

    # 4. ls -p
    Step "4. ls -p"
    $LsOutput = & $Clumsies ls -p -Q 2>&1 | Out-String
    Assert-Output "output contains SNAKE_CASE" "SNAKE_CASE" $LsOutput

    # 5. ls -ps (combined short flags)
    Step "5. ls -ps (combined flags)"
    $LsCombined = & $Clumsies ls -ps -Q 2>&1 | Out-String
    Assert-Output "combined flags work" "SNAKE_CASE" $LsCombined

    # 6. show <hash>
    Step "6. show <hash>"
    $ShowOutput = & $Clumsies show $ShortHash -Q 2>&1 | Out-String
    Assert-Output "show contains prompt content" "snake_case" $ShowOutput

    # 7. get <hash>
    Step "7. get <hash>"
    Remove-Item -Recurse -Force "$Workspace\.prompts\rule\coding" -ErrorAction SilentlyContinue
    & $Clumsies get $ShortHash -Q
    Assert ".prompts/ exists" { Test-Path "$Workspace\.prompts" }
    $Found = Get-ChildItem -Path "$Workspace\.prompts" -Recurse -Filter "*SNAKE_CASE*" -File | Select-Object -First 1
    Assert "SNAKE_CASE file was imported" { $null -ne $Found }

    # 8. pub bundle
    Step "8. pub bundle"
    New-Item -ItemType Directory -Path "$Workspace\bundle-test\conduct" -Force | Out-Null
    "# Conduct Rule`n`nBe nice.`n" | Set-Content "$Workspace\bundle-test\conduct\00_BE_NICE.md" -Encoding UTF8
    @"
---
name: test-bundle
description: A test bundle
task: testing
---
# Test Meta Prompt

This is a test meta-prompt file.
"@ | Set-Content "$Workspace\bundle-test\META.md" -Encoding UTF8
    & $Clumsies pub "bundle-test\META.md" "bundle-test\conduct" -Q
    $BundlesIndex = Join-Path $HomeDir ".clumsies\registry\bundles\index.json"
    Assert "bundles/index.json exists" { Test-Path $BundlesIndex }
    Assert-FileContains "bundle name in index" $BundlesIndex "test-bundle"
    $MetaHashLine = Select-String -Path $BundlesIndex -Pattern '"meta_prompt": "([a-f0-9]+)"' | Select-Object -First 1
    $MetaHash = $MetaHashLine.Matches[0].Groups[1].Value
    $MetaFile = Join-Path $HomeDir ".clumsies\registry\prompts\$MetaHash"
    Assert "meta-prompt file in prompts/" { Test-Path $MetaFile }

    # 9. get bundle
    Step "9. get bundle"
    Remove-Item -Recurse -Force "$Workspace\.prompts" -ErrorAction SilentlyContinue
    & $Clumsies get test-bundle -Q
    Assert ".prompts/ created" { Test-Path "$Workspace\.prompts" }
    $ConductFile = Get-ChildItem -Path "$Workspace\.prompts" -Recurse -Filter "*BE_NICE*" -File | Select-Object -First 1
    Assert "bundle prompt imported" { $null -ne $ConductFile }
    Assert "meta-prompt created at project root" { Test-Path "$Workspace\META.md" }

    # 10. set metadata
    Step "10. set metadata"
    $ConductHashLine = Select-String -Path $PromptsIndex -Pattern '"hash": "([a-f0-9]+)"' | Select-Object -Last 1
    $ConductHash = $ConductHashLine.Matches[0].Groups[1].Value
    $ConductShort = $ConductHash.Substring(0, 8)
    & $Clumsies set $ConductShort -d "Updated description" -Q
    Assert-FileContains "description updated" $PromptsIndex "Updated description"

    # 11. rm prompt
    Step "11. rm prompt"
    & $Clumsies rm $ConductShort -Q
    Assert-FileNotContains "prompt removed from index" $PromptsIndex $ConductHash
    $PromptFile = Join-Path $HomeDir ".clumsies\registry\prompts\$ConductHash"
    Assert "prompt file deleted" { -not (Test-Path $PromptFile) }

} finally {
    Set-Location $PSScriptRoot
    Remove-Item -Recurse -Force $TmpBase -ErrorAction SilentlyContinue
}

Write-Host "`n=== Results: $Pass passed, $Fail failed ==="
if ($Fail -gt 0) { exit 1 }
