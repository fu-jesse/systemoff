# Developer shell for the system_off sample. Started by dev.cmd (double-click), or: . .\dev.ps1
#
#   setup    check / configure NCS, then choose board / mode / log
#   build    incremental build of the chosen configuration (west build)
#   rebuild  pristine build of the chosen configuration (west build -p)
#   flash    flash the chosen configuration's build (no rebuild, no mass erase)
#   recover  recover the DK (erases all flash and UICR and removes the access port protection)
#   clean    delete the whole build\ directory
#
# setup asks for what it needs; the answers can also be given as parameters, e.g.
#   setup -Board lm20a -Mode grtc -Log off      (see Get-Help setup -Full)

# Run (double-click, .\dev.ps1) instead of dot-sourced: the commands would be lost when the
# script ends, so start a shell that keeps them and stays open.
if ($MyInvocation.InvocationName -ne '.') {
    & powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -Command ". '$PSCommandPath'"
    return
}

# ---- settings ---------------------------------------------------------------
$script:NcsVersion   = 'v3.4.1'
$script:NcsDir       = 'C:\ncs\v3.4.1'
$script:ToolchainDir = 'C:\ncs\toolchains\4f5b6ad6dd'
# -----------------------------------------------------------------------------

$script:App      = $PSScriptRoot
$script:Ready    = $false     # NCS usable in this shell
$script:Cfg      = $null      # chosen board / mode / log
$script:UserHome = $env:NRFUTIL_HOME      # nrfutil home outside the toolchain env
$script:BasePath = $env:PATH              # PATH and PYTHONPATH of the shell before any toolchain env
$script:BasePyPath = $env:PYTHONPATH

$script:Boards = [ordered]@{
    'l15'   = @{ Target = 'nrf54l15dk/nrf54l15/cpuapp' }
    'lm20a' = @{ Target = 'nrf54lm20dk/nrf54lm20a/cpuapp' }
    'lm20b' = @{ Target = 'nrf54lm20dk/nrf54lm20b/cpuapp' }
    'ls05a' = @{ Target = 'nrf54ls05dk/nrf54ls05a/cpuapp' }
    'ls05b' = @{ Target = 'nrf54ls05dk/nrf54ls05b/cpuapp' }
}

function Write-Err([string]$Message) { Write-Host "ERROR: $Message" -ForegroundColor Red }

function Read-Choice([string]$Title, [string[]]$Items, [int]$Default = 1) {
    Write-Host ''
    Write-Host "===== $Title =====" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $Items[$i]) }
    $s = Read-Host ('Select [1-{0}, default {1}]' -f $Items.Count, $Default)
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    $n = 0
    if ([int]::TryParse($s, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $n }
    throw "Invalid selection: $s"
}

function Test-West {
    if (-not (Get-Command west -ErrorAction SilentlyContinue)) { return $false }
    & west --version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Resolve-Toolchain([string]$Version) {
    # toolchains.json (next to the toolchain directories) maps an NCS version to its toolchain bundle;
    # without a match the ToolchainDir from the settings is kept
    $json = Join-Path (Split-Path $script:ToolchainDir -Parent) 'toolchains.json'
    if (-not (Test-Path -LiteralPath $json)) { return }
    try {
        foreach ($entry in @(Get-Content -LiteralPath $json -Raw | ConvertFrom-Json)) {
            foreach ($t in @($entry.toolchains)) {
                if ($t.ncs_versions -contains $Version) {
                    $script:ToolchainDir = Join-Path (Split-Path $script:ToolchainDir -Parent) $t.identifier.bundle_id
                    return
                }
            }
        }
    } catch { Write-Host "[toolchain] cannot read ${json}: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Initialize-Ncs([string]$Version, [bool]$Fallback) {
    # 1. nrfutil sdk-manager  2. ToolchainDir + NcsDir  3. error
    $script:Ready = $false
    if ($Version) {
        $script:NcsVersion = $Version
        $script:NcsDir = Join-Path (Split-Path $script:NcsDir -Parent) $Version
    }
    Write-Host "Checking NCS $($script:NcsVersion) ..."

    # Start from the shell's original environment. The toolchain env of an earlier call puts the
    # toolchain's own nrfutil first in PATH and moves NRFUTIL_HOME, so a second call would not find
    # the SDK through the user's nrfutil any more.
    $env:PATH = $script:BasePath
    $env:PYTHONPATH = $script:BasePyPath
    $env:NRFUTIL_HOME = $script:UserHome

    if (-not $Fallback) {
        if (Get-Command nrfutil -ErrorAction SilentlyContinue) {
            $envScript = & nrfutil sdk-manager toolchain env --ncs-version $script:NcsVersion --as-script powershell 2>$null | Out-String
            if ($LASTEXITCODE -eq 0 -and $envScript.Trim()) {
                Invoke-Expression $envScript
                if (Test-West) {
                    $script:Ready = $true
                    Write-Host "NCS    : nrfutil sdk-manager, $($script:NcsVersion)" -ForegroundColor Green
                }
            }
            if (-not $script:Ready) { Write-Host "[nrfutil] NCS $($script:NcsVersion) is not usable, trying toolchain/NCS directories..." }
        } else {
            Write-Host '[nrfutil] not found, trying toolchain/NCS directories...'
        }
    }

    if (-not $script:Ready) {
        Resolve-Toolchain $script:NcsVersion
        $tc = $script:ToolchainDir
        if (-not (Test-Path "$tc\opt\bin")) { Write-Err "toolchain not found: $tc"; return $false }
        if (-not (Test-Path "$($script:NcsDir)\zephyr")) { Write-Err "NCS not found: $($script:NcsDir)"; return $false }
        $env:PATH = (@("$tc", "$tc\mingw64\bin", "$tc\bin", "$tc\opt\bin", "$tc\opt\bin\Scripts",
                       "$tc\opt\nanopb\generator-bin", "$tc\nrfutil\bin",
                       "$tc\opt\zephyr-sdk\gnu\arm-zephyr-eabi\bin",
                       "$tc\opt\zephyr-sdk\gnu\riscv64-zephyr-elf\bin") -join ';') + ';' + $env:PATH
        $env:PYTHONPATH = "$tc\opt\bin;$tc\opt\bin\Lib;$tc\opt\bin\Lib\site-packages"
        $env:NRFUTIL_HOME = "$tc\nrfutil\home"
        $env:ZEPHYR_TOOLCHAIN_VARIANT = 'zephyr/gnu'
        $env:ZEPHYR_SDK_INSTALL_DIR = "$tc\opt\zephyr-sdk"
        if (-not (Test-West)) { Write-Err "west is not usable with $tc and $($script:NcsDir)"; return $false }
        $script:Ready = $true
        Write-Host "NCS    : $($script:NcsDir), toolchain $tc" -ForegroundColor Green
    }
    $env:ZEPHYR_BASE = "$($script:NcsDir)\zephyr"
    return $true
}

function Get-BuildName($Cfg) {
    # short on purpose (Windows path length): <board>_<mode>[_log]
    #   board : l15 | lm20a | lm20b | ls05a | ls05b      mode : pin | grtc | ret
    #   log   : only when the log is on (release = nothing)
    $name = '{0}_{1}' -f $Cfg.Board, $Cfg.Mode
    if ($Cfg.Log -eq 'on') { $name += '_log' }
    return $name
}

function Show-Config {
    $c = $script:Cfg
    Write-Host ''
    Write-Host "Board : $($c.Target)"
    Write-Host "Mode  : $($c.Mode)    Log : $($c.Log)"
    Write-Host "Build : $(Join-Path $script:App ('build\' + (Get-BuildName $c)))"
}

function setup {
    <#
    .SYNOPSIS  Checks / configures NCS in this shell, then chooses the configuration to build and flash.
    .DESCRIPTION
      NCS: 1. nrfutil sdk-manager  2. ToolchainDir + NcsDir from the settings at the top of dev.ps1
           3. otherwise prints an error and stops (nothing else is asked).
      Then asks for board / mode / log unless given as parameters.
      build, rebuild and flash use this configuration. Run setup again to change it.
    .PARAMETER Version  NCS version, default from the settings (the NCS dir becomes C:\ncs\<version>).
    .PARAMETER Fallback Skip nrfutil and use the toolchain / NCS directories directly.
    .PARAMETER Board    1|l15, 2|lm20a, 3|lm20b, 4|ls05a, 5|ls05b
    .PARAMETER Mode     pin  (sw0 wake-up, all RAM powered down)
                        grtc (GRTC wake-up after 10 s, all RAM powered down)
                        ret  (sw0 wake-up, 4 KB retained RAM)
    .PARAMETER Log      on | off (off = release: no log, uart20 disabled)
    #>
    param([string]$Version, [switch]$Fallback, [string]$Board, [string]$Mode, [string]$Log)

    $script:Cfg = $null
    if (-not (Initialize-Ncs $Version $Fallback.IsPresent)) { return }

    try {
        $keys = @($script:Boards.Keys)
        if (-not $Board) {
            $Board = $keys[(Read-Choice 'Board' ($keys | ForEach-Object { $script:Boards[$_].Target }) 1) - 1]
        } elseif ($Board -match '^[1-5]$') { $Board = $keys[[int]$Board - 1] }
        if (-not $script:Boards.Contains($Board)) { throw "unknown board: $Board (use 1-5, l15, lm20a, lm20b, ls05a, ls05b)" }

        if (-not $Mode) {
            $Mode = @('pin', 'grtc', 'ret')[(Read-Choice 'Mode' @('pin   : sw0 wake-up, all RAM powered down',
                                                                    'grtc  : GRTC wake-up (10 s), all RAM powered down',
                                                                    'ret   : sw0 wake-up, 4 KB retained RAM, other RAM powered down') 1) - 1]
        }
        if ($Mode -notin 'pin', 'grtc', 'ret') { throw "unknown mode: $Mode (use pin, grtc or ret)" }

        if (-not $Log) { $Log = @('on', 'off')[(Read-Choice 'Log' @('Log on uart20  (default)', 'No log, uart20 disabled (release)') 1) - 1] }
        $Log = $Log -replace '^log$', 'on' -replace '^nolog$', 'off'
        if ($Log -notin 'on', 'off') { throw "unknown log mode: $Log (use on or off)" }
    } catch { Write-Err $_.Exception.Message; return }

    $b = $script:Boards[$Board]
    $script:Cfg = @{ Board = $Board; Target = $b.Target; Mode = $Mode; Log = $Log }
    Show-Config
    Write-Host ''
    Write-Host 'Ready: build | rebuild | flash | clean' -ForegroundColor Green
}

function Confirm-Setup {
    if (-not $script:Ready -or -not $script:Cfg) { setup }
    return ($script:Ready -and $null -ne $script:Cfg)
}

function Invoke-West {
    # west must run inside the NCS workspace
    Push-Location $script:NcsDir
    try { & west @args } finally { Pop-Location }
}

function Invoke-Build([bool]$Pristine) {
    # returns $true when the build succeeded
    if (-not (Confirm-Setup)) { return $false }
    $c = $script:Cfg
    $cmake = @()
    if ($c.Log -eq 'off') { $cmake += '-DFILE_SUFFIX=release' }
    # modes are snippets (snippets\); sysbuild needs the application directory as a snippet root
    $cmake += ('-DSNIPPET_ROOT=' + $script:App.Replace('\', '/'))
    $snippets = switch ($c.Mode) {
        'pin'  { @('pinwake') }               # sw0 wake-up, system clock off (Kconfig default)
        'grtc' { @('grtcwake') }
        'ret'  { @('pinwake', 'retram') }
    }

    $bdir = Join-Path $script:App ('build\' + (Get-BuildName $c))
    $pflag = @()
    if ($Pristine) { $pflag = @('-p') }
    Show-Config
    Write-Host ''
    Write-Host ('west build {0}-b {1} -d <build> <app> {2} -- {3}' -f $(if ($Pristine) { '-p ' } else { '' }), $c.Target, (($snippets | ForEach-Object { "-S $_" }) -join ' '), ($cmake -join ' ')) -ForegroundColor DarkGray
    Write-Host ''

    # Out-Host: the build output must not become part of the return value
    Invoke-West build @pflag --sysbuild -b $c.Target -d $bdir @($snippets | ForEach-Object { '-S'; $_ }) $script:App -- @cmake | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Err "build failed, exit code $LASTEXITCODE"; return $false }
    Write-Host "`nBuild OK: $bdir" -ForegroundColor Green
    return $true
}

function build {
    <#
    .SYNOPSIS  Incremental build of the configuration chosen by setup (west build).
    #>
    [void](Invoke-Build $false)
}

function rebuild {
    <#
    .SYNOPSIS  Pristine build of the configuration chosen by setup (west build -p).
    #>
    [void](Invoke-Build $true)
}

function Select-Device([string]$DevId) {
    # returns the extra west arguments for the probe; throws when none is found
    if ($DevId) { Write-Host "Device: $DevId"; return @('--dev-id', $DevId) }
    $saved = $env:NRFUTIL_HOME
    $env:NRFUTIL_HOME = $script:UserHome
    try { $out = & nrfutil device list --traits jlink 2>$null | Out-String } finally { $env:NRFUTIL_HOME = $saved }
    $m = [regex]::Match($out, 'Found (\d+) supported device')
    $n = 0
    if ($m.Success) { $n = [int]$m.Groups[1].Value }
    if ($n -eq 0) { throw 'no J-Link device found, connect and power the board' }
    if ($n -eq 1) { Write-Host 'Device: the only connected J-Link device'; return @() }
    Write-Host ''
    Write-Host '===== Devices =====' -ForegroundColor Cyan
    Write-Host $out
    $s = Read-Host 'Enter the serial number of the device to use'
    if ([string]::IsNullOrWhiteSpace($s)) { throw 'no device selected' }
    return @('--dev-id', $s.Trim())
}

function flash {
    <#
    .SYNOPSIS  Flashes the build of the configuration chosen by setup (no rebuild, no mass erase).
    .PARAMETER Build  Name of another directory in build\ to flash instead
    .PARAMETER DevId  J-Link serial number (default: detect)
    #>
    param([string]$Build, [string]$DevId)

    if (-not (Confirm-Setup)) { return }
    $own = -not $Build
    if ($own) { $Build = Get-BuildName $script:Cfg }
    $bdir = Join-Path $script:App "build\$Build"
    if ($own -and -not (Test-Path (Join-Path $bdir 'domains.yaml'))) {
        # nothing built for the chosen configuration yet (e.g. flash right after a fresh setup)
        Write-Host "No build for this configuration yet, building first ..." -ForegroundColor Yellow
        if (-not (Invoke-Build $false)) { return }
    }
    if (-not (Test-Path (Join-Path $bdir 'domains.yaml'))) { Write-Err "no build found: $bdir"; return }
    Write-Host "Build : $bdir"
    try { $dev = Select-Device $DevId } catch { Write-Err $_.Exception.Message; return }

    Write-Host ''
    Invoke-West flash -d $bdir --no-rebuild @dev
    if ($LASTEXITCODE -ne 0) { Write-Err "flash failed, exit code $LASTEXITCODE"; return }
    Write-Host "`nFlash OK: $bdir" -ForegroundColor Green
}

function Get-JLinkSerial([string]$DevId) {
    # returns the serial number of the J-Link device to use; throws when none is found
    if ($DevId) { return $DevId.Trim() }
    $saved = $env:NRFUTIL_HOME
    $env:NRFUTIL_HOME = $script:UserHome
    try { $out = & nrfutil device list --traits jlink 2>$null | Out-String } finally { $env:NRFUTIL_HOME = $saved }
    $serials = @([regex]::Matches($out, '(?m)^\s*(\d{9,})\s*$') | ForEach-Object { $_.Groups[1].Value })
    if ($serials.Count -eq 0) { throw 'no J-Link device found, connect and power the board' }
    if ($serials.Count -eq 1) { Write-Host "Device: $($serials[0]) (the only connected J-Link device)"; return $serials[0] }
    Write-Host ''
    Write-Host '===== Devices =====' -ForegroundColor Cyan
    Write-Host $out
    $s = Read-Host 'Enter the serial number of the device to recover'
    if ([string]::IsNullOrWhiteSpace($s) -or $serials -notcontains $s.Trim()) { throw 'no valid device selected' }
    return $s.Trim()
}
function recover {
    <#
    .SYNOPSIS  Recovers the DK: erases all flash and UICR and removes the access port protection (nrfutil device recover).
    .DESCRIPTION
      Use it when the board cannot be programmed or connected to (protection set, corrupted state).
      All firmware and user data on the chip are lost: run flash afterwards.
    .PARAMETER DevId  J-Link serial number (default: detect)
    .PARAMETER Force  Do not ask for confirmation.
    #>
    param([string]$DevId, [switch]$Force)

    try { $sn = Get-JLinkSerial $DevId } catch { Write-Err $_.Exception.Message; return }
    Write-Host "Recover device ${sn}: erases ALL flash and UICR on the chip, firmware and data are lost." -ForegroundColor Yellow
    if (-not $Force) {
        $a = Read-Host 'Recover it? [y/N]'
        if ($a -notmatch '^[yY]') { Write-Host 'Cancelled, nothing changed.'; return }
    }
    $saved = $env:NRFUTIL_HOME
    $env:NRFUTIL_HOME = $script:UserHome
    try { & nrfutil device recover --serial-number $sn } finally { $env:NRFUTIL_HOME = $saved }
    if ($LASTEXITCODE -ne 0) { Write-Err "recover failed, exit code $LASTEXITCODE"; return }
    Write-Host "`nRecover OK: ${sn}. Run flash to program the board again." -ForegroundColor Green
}
function clean {
    <#
    .SYNOPSIS  Deletes the whole build\ directory (all builds of all configurations).
    .PARAMETER Force  Do not ask for confirmation.
    #>
    param([switch]$Force)

    $root = Join-Path $script:App 'build'
    if (-not (Test-Path -LiteralPath $root)) { Write-Host "Nothing to clean: $root does not exist"; return }
    $full = (Resolve-Path -LiteralPath $root).Path
    $expected = Join-Path (Resolve-Path -LiteralPath $script:App).Path 'build'
    if ($full -ne $expected -or (Split-Path $full -Leaf) -ne 'build') { Write-Err "refusing to delete unexpected path: $full"; return }

    $builds = @(Get-ChildItem -LiteralPath $full -Directory)
    Write-Host "Delete $full ($($builds.Count) build(s))" -ForegroundColor Yellow
    $builds | ForEach-Object { Write-Host "  $($_.Name)" }
    if (-not $Force) {
        $a = Read-Host 'Delete it? [y/N]'
        if ($a -notmatch '^[yY]') { Write-Host 'Cancelled, nothing deleted.'; return }
    }
    # the current directory cannot be deleted
    $cwd = (Get-Location).Path
    if ($cwd.Equals($full, 'OrdinalIgnoreCase') -or $cwd.StartsWith($full + [IO.Path]::DirectorySeparatorChar, 'OrdinalIgnoreCase')) { Set-Location $script:App }
    try {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        Write-Host "Deleted $full" -ForegroundColor Green
    } catch {
        Write-Err "could not delete everything: $($_.Exception.Message) (is a build still running or a file open?)"
    }
}

Write-Host ''
Write-Host 'system_off sample developer shell' -ForegroundColor Cyan
Write-Host '  setup    check NCS, choose board / mode / log'
Write-Host '  build    incremental build'
Write-Host '  rebuild  pristine build (west build -p)'
Write-Host '  flash    flash the chosen build'
Write-Host '  recover  recover the DK (erases the chip)'
Write-Host '  clean    delete the build\ directory'
Write-Host ''
