<#
run-dryrun.ps1 -- FILE-LEVEL dry-run harness for the IntelliBot
control-plane tools. Windows PowerShell 5.1, zero dependencies.

THIS HARNESS LAUNCHES NOTHING. No s&box, no editor, no Host Play, no pawn,
no network, no process creation: every tool under test is a PowerShell
script invoked IN-PROCESS with the call operator. It exercises files and
only files.

WRITE SURFACE: test\scratch\run-<utc>\ (fresh per run, never reused) and
test\results\. Both are gitignored. The seed store store\v1 is never
written; check N01 proves it byte-identical before and after the run.

EXIT: 0 every check passed; 2 at least one check failed; 3 harness fault.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tools    = Join-Path $RepoRoot 'tools'
$Fixtures = Join-Path $PSScriptRoot 'fixtures'
$RunId    = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$Scratch  = Join-Path $PSScriptRoot ('scratch\run-' + $RunId)
$Results  = Join-Path $PSScriptRoot 'results'

New-Item -ItemType Directory -Force $Scratch | Out-Null
New-Item -ItemType Directory -Force $Results | Out-Null

$Checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Id, [string]$Desc, [string]$Expected, [string]$Actual)
    $pass = ($Expected -ceq $Actual)
    [void]$Checks.Add([ordered]@{
        id = $Id; desc = $Desc; expected = $Expected; actual = $Actual; pass = $pass
    })
    $tag = 'FAIL'; if ($pass) { $tag = 'PASS' }
    Write-Information ('{0} {1}: {2} (expected {3}, got {4})' -f $tag, $Id, $Desc, $Expected, $Actual) -InformationAction Continue
}

function Invoke-Tool {
    # In-process invocation; returns exit code and parsed JSON (or null).
    param([string]$ScriptPath, [hashtable]$Arguments)
    try {
        $raw = & $ScriptPath @Arguments
        $exit = $LASTEXITCODE
        $json = $null
        if ($null -ne $raw) {
            $text = ($raw | Out-String)
            if ($text.Trim().Length -gt 0) { $json = $text | ConvertFrom-Json }
        }
        return @{ Exit = $exit; Json = $json }
    } catch {
        return @{ Exit = -1; Json = $null; Error = $_.Exception.Message }
    }
}

function Get-TreeFingerprint {
    # AMEND R-4: -Force so hidden files are fingerprinted. Without it the
    # N01 seed-identity control carried the same hidden-file blind spot
    # R13 closed in the store layer -- a control that cannot see a planted
    # hidden file reports a stronger guarantee than it holds. Proven by
    # check C01 below.
    param([string]$Root)
    $rows = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash + ' ' + $_.FullName.Substring($Root.Length)
    }
    return ($rows -join "`n")
}

try {
    $seedBefore = Get-TreeFingerprint -Root (Join-Path $RepoRoot 'store\v1')

    # ---------------- V-series: envelope validator --------------------
    $validator = Join-Path $Tools 'validate-session.ps1'
    $envDir = Join-Path $Fixtures 'envelopes'

    # V10 fixture is generated (a 16385-char memoryValue would be noise
    # as a committed file).
    $oversizePath = Join-Path $Scratch 'gen-bad-memory-value-size.json'
    $oversize = [ordered]@{
        protocolVersion = 1; requestId = 'req-b10-oversize'
        sessionId = 'sess-fixture-0001'; botHandle = 'bh-fixture-01'
        seq = 10; expectedStateVersion = 9
        expiresUtc = '2030-01-01T00:00:00Z'; action = 'memory.upsert'
        args = [ordered]@{ memoryKey = 'oversize.test'; memoryValue = ('a' * 16385) }
    }
    [System.IO.File]::WriteAllText($oversizePath, (ConvertTo-Json $oversize -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

    $vExpect = [ordered]@{
        'valid-status.json'         = 'VALID'
        'valid-move.json'           = 'VALID'
        'valid-memory-upsert.json'  = 'VALID'
        'bad-unknown-field.json'    = 'E_MALFORMED'
        'bad-missing-field.json'    = 'E_MALFORMED'
        'bad-protocol-version.json' = 'E_PROTOCOL_VERSION'
        'bad-action-excluded.json'  = 'E_ACTION_EXCLUDED'
        'bad-bounds-move.json'      = 'E_BOUNDS'
        'bad-memory-key.json'       = 'E_BOUNDS'
        'gen-bad-memory-value-size.json' = 'E_BOUNDS'
        'bad-expired.json'          = 'E_EXPIRED'
        'bad-not-json.json'         = 'E_MALFORMED'
        'bad-top-level-array.json'  = 'E_MALFORMED'
        'bad-case-field.json'       = 'E_MALFORMED'
        # FIX1 F4 regressions: the date-time lexical space requires an
        # offset (old code judged the tz-free value VALID).
        'bad-tz-free-datetime.json' = 'E_MALFORMED'
        'valid-offset-datetime.json' = 'VALID'
        'valid-lowercase-z.json'    = 'VALID'
        # FIX1-verify F4: an out-of-range offset minute (old code passed
        # it and XmlConvert silently normalized +00:60 -> +01:00), and a
        # trailing newline (old $-anchor let it through).
        'bad-offset-minute.json'    = 'E_MALFORMED'
        'bad-trailing-lf.json'      = 'E_MALFORMED'
    }
    $paths = New-Object System.Collections.ArrayList
    foreach ($name in $vExpect.Keys) {
        if ($name -clike 'gen-*') { [void]$paths.Add($oversizePath) }
        else { [void]$paths.Add((Join-Path $envDir $name)) }
    }
    $vRun = Invoke-Tool -ScriptPath $validator -Arguments @{ Path = @($paths); Quiet = $true }
    $i = 1
    foreach ($name in $vExpect.Keys) {
        $verdict = '(missing result)'
        if ($null -ne $vRun.Json) {
            foreach ($r in @($vRun.Json)) {
                if ((Split-Path -Leaf $r.file) -ceq $name) {
                    if ($r.valid) { $verdict = 'VALID' } else { $verdict = [string]$r.primaryCode }
                }
            }
        }
        Add-Check -Id ('V{0:D2}' -f $i) -Desc ('validator: ' + $name) -Expected $vExpect[$name] -Actual $verdict
        $i += 1
    }
    Add-Check -Id 'V90' -Desc 'validator exit code with mixed input' -Expected '2' -Actual ([string]$vRun.Exit)

    # V91: drift sensor -- a scratch copy of the tools beside a schema
    # whose bytes moved must REFUSE TO JUDGE (exit 3). The real schema is
    # never touched.
    $driftRepo = Join-Path $Scratch 'drift-repo'
    New-Item -ItemType Directory -Force (Join-Path $driftRepo 'tools\lib') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $driftRepo 'contracts') | Out-Null
    Copy-Item $validator (Join-Path $driftRepo 'tools\validate-session.ps1')
    Copy-Item (Join-Path $Tools 'lib\intellibot-common.ps1') (Join-Path $driftRepo 'tools\lib\intellibot-common.ps1')
    $schemaText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'contracts\session-v1.schema.json'))
    [System.IO.File]::WriteAllText((Join-Path $driftRepo 'contracts\session-v1.schema.json'), ($schemaText + ' '), (New-Object System.Text.UTF8Encoding($false)))
    $dRun = Invoke-Tool -ScriptPath (Join-Path $driftRepo 'tools\validate-session.ps1') -Arguments @{ Path = @((Join-Path $envDir 'valid-status.json')); Quiet = $true }
    Add-Check -Id 'V91' -Desc 'drift sensor refuses moved schema' -Expected '3' -Actual ([string]$dRun.Exit)

    # ---------------- S-series: session lifecycle ---------------------
    $storeA = Join-Path $Scratch 'store-A'
    New-Item -ItemType Directory -Force $storeA | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $storeA -Recurse

    $create = Join-Path $Tools 'session-create.ps1'
    $append = Join-Path $Tools 'session-append.ps1'
    $close  = Join-Path $Tools 'session-close.ps1'

    $s1 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeA }
    $sid = ''
    $s1ok = 'refused'
    if ($s1.Exit -eq 0 -and $null -ne $s1.Json -and $s1.Json.ok) { $s1ok = 'ok'; $sid = $s1.Json.sessionId }
    Add-Check -Id 'S01' -Desc 'create opens a session' -Expected 'ok' -Actual $s1ok

    $s2 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeA }
    $s2code = ''; if ($null -ne $s2.Json) { $s2code = [string]$s2.Json.code }
    Add-Check -Id 'S02' -Desc 'second create while open refuses' -Expected 'E_INTERNAL' -Actual $s2code

    $s3 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $sid; Outcome = 'completed'; Notes = 'dry-run episode one'; StoreRoot = $storeA }
    $s3seq = ''; if ($null -ne $s3.Json -and $s3.Exit -eq 0) { $s3seq = [string]$s3.Json.seq }
    Add-Check -Id 'S03' -Desc 'first append lands seq 1' -Expected '1' -Actual $s3seq

    $s4 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $sid; Outcome = 'stopped'; Notes = 'dry-run episode two'; StoreRoot = $storeA }
    $s4seq = ''; if ($null -ne $s4.Json -and $s4.Exit -eq 0) { $s4seq = [string]$s4.Json.seq }
    Add-Check -Id 'S04' -Desc 'second append lands seq 2' -Expected '2' -Actual $s4seq

    $s5 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = 'sess-bogus-00000000'; Outcome = 'completed'; StoreRoot = $storeA }
    $s5code = ''; if ($null -ne $s5.Json) { $s5code = [string]$s5.Json.code }
    Add-Check -Id 'S05' -Desc 'append to unknown session refuses' -Expected 'E_UNKNOWN_SESSION' -Actual $s5code

    $s6 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $sid; Outcome = 'completed'; Notes = ('n' * 17000); StoreRoot = $storeA }
    $s6code = ''; if ($null -ne $s6.Json) { $s6code = [string]$s6.Json.code }
    Add-Check -Id 'S06' -Desc 'oversize episode refuses, never truncates' -Expected 'E_LIMIT' -Actual $s6code

    $s7 = Invoke-Tool -ScriptPath $close -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $sid; StoreRoot = $storeA }
    $s7state = 'refused'
    if ($s7.Exit -eq 0 -and $null -ne $s7.Json -and $s7.Json.ok) { $s7state = ('closed:{0}:{1}' -f $s7.Json.episodeCount, $s7.Json.lastOutcome) }
    Add-Check -Id 'S07' -Desc 'close rolls up episodes and last outcome' -Expected 'closed:2:stopped' -Actual $s7state

    $s8 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $sid; Outcome = 'completed'; StoreRoot = $storeA }
    $s8code = ''; if ($null -ne $s8.Json) { $s8code = [string]$s8.Json.code }
    Add-Check -Id 'S08' -Desc 'append after close refuses' -Expected 'E_UNKNOWN_SESSION' -Actual $s8code

    $epFile = @(Get-ChildItem (Join-Path $storeA 'operators\op-grok-01\episodes\*.json'))[0]
    $bytes = [System.IO.File]::ReadAllBytes($epFile.FullName)
    $bytes[$bytes.Length - 5] = 88
    [System.IO.File]::WriteAllBytes($epFile.FullName, $bytes)
    $s9 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeA }
    $s9code = ''; if ($null -ne $s9.Json) { $s9code = [string]$s9.Json.code }
    Add-Check -Id 'S09' -Desc 'flipped byte freezes the store' -Expected 'E_STORE_CORRUPT' -Actual $s9code

    $storeB = Join-Path $Scratch 'store-B'
    New-Item -ItemType Directory -Force $storeB | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $storeB -Recurse
    $statePath = Join-Path $storeB 'operators\op-grok-01\state.json'
    $stateDoc = Get-Content $statePath -Raw | ConvertFrom-Json
    $stateDoc.schemaVersion = 2
    [System.IO.File]::WriteAllText($statePath, (ConvertTo-Json $stateDoc -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $s10 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeB }
    $s10code = ''; if ($null -ne $s10.Json) { $s10code = [string]$s10.Json.code }
    Add-Check -Id 'S10' -Desc 'future schemaVersion freezes the store' -Expected 'E_SCHEMA_FUTURE' -Actual $s10code

    $s11 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $env:TEMP }
    $s11code = ''; if ($null -ne $s11.Json) { $s11code = [string]$s11.Json.code }
    Add-Check -Id 'S11' -Desc 'store root outside the repo refuses' -Expected 'E_NOT_HOST' -Actual $s11code

    # S12 EXPECTATION CHANGED BY FIX1 F2 (declared contract-behavior
    # change): leftover .new staging residue is now SELF-HEALED by the
    # sweep instead of freezing the store.
    $storeC = Join-Path $Scratch 'store-C'
    New-Item -ItemType Directory -Force $storeC | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $storeC -Recurse
    [System.IO.File]::WriteAllText((Join-Path $storeC 'operators\op-grok-01\state.json.new'), '{}', (New-Object System.Text.UTF8Encoding($false)))
    $s12 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeC }
    $s12state = 'refused'
    if ($s12.Exit -eq 0 -and $null -ne $s12.Json -and $s12.Json.ok) {
        $healNote = (@($s12.Json.healed) -join '; ')
        $newGone = -not (Test-Path (Join-Path $storeC 'operators\op-grok-01\state.json.new'))
        if (($healNote -clike '*staging-residue*') -and $newGone) { $s12state = 'healed+ok' }
        else { $s12state = ('ok-but-heal-evidence-missing:{0}:{1}' -f $healNote, $newGone) }
    }
    Add-Check -Id 'S12' -Desc 'leftover .new staging residue self-heals (FIX1 F2 semantics)' -Expected 'healed+ok' -Actual $s12state

    # ---------------- L-series: operator loader -----------------------
    $loader = Join-Path $Tools 'load-operators.ps1'
    $l1 = Invoke-Tool -ScriptPath $loader -Arguments @{}
    $l1state = 'refused'
    if ($l1.Exit -eq 0 -and $null -ne $l1.Json -and $l1.Json.ok) {
        $allFalse = $true
        foreach ($op in @($l1.Json.operators)) { if ($op.spawnPermitted) { $allFalse = $false } }
        $l1state = ('ok:{0}:allSpawnFalse={1}' -f $l1.Json.count, $allFalse)
    }
    Add-Check -Id 'L01' -Desc 'real roster loads, spawn universally false' -Expected 'ok:2:allSpawnFalse=True' -Actual $l1state

    $l2 = Invoke-Tool -ScriptPath $loader -Arguments @{ RepoRoot = (Join-Path $Fixtures 'tamper-repo') }
    $l2state = ''
    if ($null -ne $l2.Json) { $l2state = ('{0}:{1}' -f $l2.Exit, [string]$l2.Json.code) }
    Add-Check -Id 'L02' -Desc 'tampered spawnPermitted=true refused' -Expected '1:E_GATE0_HELD' -Actual $l2state

    # ---------------- R-series: FIX1 regressions -----------------------
    # Each regression is built from the cross-maker reviewer's recorded
    # scratch positive (LUNA grade header of record, 2026-08-22): the
    # old code produced the defective outcome documented there; the
    # fixed code must produce the expected outcome asserted here.

    function Get-EpisodeOrphanCount {
        # Episodes on disk minus episodes the manifest attests. A
        # committed store always measures 0; an interrupted append on
        # the OLD code measured 1 (the reviewer's F2 positive).
        param([string]$OpDir)
        $m = Get-Content (Join-Path $OpDir 'manifest.json') -Raw | ConvertFrom-Json
        $trackedCount = 0
        if ($null -ne $m.lastKnownGood) {
            $trackedCount = @($m.lastKnownGood.PSObject.Properties.Name | Where-Object { $_ -clike 'episodes*' }).Count
        }
        $disk = @(Get-ChildItem (Join-Path $OpDir 'episodes\*.json') -ErrorAction SilentlyContinue).Count
        return ($disk - $trackedCount)
    }

    # R01 -- F1: an in-repo junction as -StoreRoot must refuse and leave
    # the junction target byte-identical (old code: exit 0 and mutated).
    $jtTarget = Join-Path $Scratch 'r01-target'
    New-Item -ItemType Directory -Force $jtTarget | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $jtTarget -Recurse
    $jtBefore = Get-TreeFingerprint -Root $jtTarget
    New-Item -ItemType Junction -Path (Join-Path $Scratch 'r01-junction') -Target $jtTarget | Out-Null
    $r01 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = (Join-Path $Scratch 'r01-junction') }
    $r01code = ''; if ($null -ne $r01.Json) { $r01code = [string]$r01.Json.code }
    Add-Check -Id 'R01a' -Desc 'F1: junction store root refused' -Expected 'E_NOT_HOST' -Actual $r01code
    $jtAfter = Get-TreeFingerprint -Root $jtTarget
    $r01b = 'CHANGED'; if ($jtBefore -ceq $jtAfter) { $r01b = 'BYTE-IDENTICAL' }
    Add-Check -Id 'R01b' -Desc 'F1: junction target untouched by refusal' -Expected 'BYTE-IDENTICAL' -Actual $r01b

    # R02 -- F2/FIX1-verify: an empty foreign DIRECTORY at a bookkeeping
    # path (state.json.new) is foreign topology; the shape guard freezes
    # it up front rather than write through it. (Round-1 healed it; the
    # verify pass showed a foreign directory must never be trusted.)
    $storeF2 = Join-Path $Scratch 'r02-store'
    New-Item -ItemType Directory -Force $storeF2 | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $storeF2 -Recurse
    $opF2 = Join-Path $storeF2 'operators\op-grok-01'
    $r02c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeF2 }
    $r02sid = ''; if ($r02c.Exit -eq 0) { $r02sid = $r02c.Json.sessionId }
    New-Item -ItemType Directory -Path (Join-Path $opF2 'state.json.new') | Out-Null
    $r02mBefore = (Get-FileHash (Join-Path $opF2 'manifest.json')).Hash
    $r02 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r02sid; Outcome = 'completed'; Notes = 'r02 regression'; StoreRoot = $storeF2 }
    $r02code = ''; if ($null -ne $r02.Json) { $r02code = [string]$r02.Json.code }
    Add-Check -Id 'R02a' -Desc 'F2: empty foreign .new-dir frozen by shape guard' -Expected 'E_STORE_CORRUPT' -Actual $r02code
    $r02mAfter = (Get-FileHash (Join-Path $opF2 'manifest.json')).Hash
    Add-Check -Id 'R02b' -Desc 'F2: shape-guard freeze left no partial state' -Expected 'manifestSame=True;orphans=0' -Actual ('manifestSame={0};orphans={1}' -f ($r02mBefore -ceq $r02mAfter), (Get-EpisodeOrphanCount -OpDir $opF2))
    [System.IO.Directory]::Delete((Join-Path $opF2 'state.json.new'), $false)

    # R03 -- F2: a NON-EMPTY foreign directory at a bookkeeping path is
    # frozen too, and is never recursively deleted.
    New-Item -ItemType Directory -Path (Join-Path $opF2 'state.json.new') | Out-Null
    Set-Content -Path (Join-Path $opF2 'state.json.new\foreign.txt') -Value 'foreign' -Encoding ASCII
    $r03 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r02sid; Outcome = 'completed'; Notes = 'r03 regression'; StoreRoot = $storeF2 }
    $r03code = ''; if ($null -ne $r03.Json) { $r03code = [string]$r03.Json.code }
    Add-Check -Id 'R03a' -Desc 'F2: non-empty foreign plant frozen, not deleted' -Expected 'E_STORE_CORRUPT' -Actual $r03code
    Add-Check -Id 'R03b' -Desc 'F2: foreign contents preserved (never recursively removed)' -Expected 'True' -Actual ([string](Test-Path (Join-Path $opF2 'state.json.new\foreign.txt')))
    [System.IO.File]::Delete((Join-Path $opF2 'state.json.new\foreign.txt'))
    [System.IO.Directory]::Delete((Join-Path $opF2 'state.json.new'), $false)

    # R06 -- FIX1-verify F1 (HIGH): a junction planted AT episodes\ must
    # not let a write escape the store root. (Round-1 fix gated only to
    # the operator dir; the verify pass wrote an episode to an external
    # target.) Shape guard freezes without following; zero external writes.
    $r06store = Join-Path $Scratch 'r06-store'
    New-Item -ItemType Directory -Force $r06store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r06store -Recurse
    $r06op = Join-Path $r06store 'operators\op-grok-01'
    $r06escape = Join-Path $Scratch 'r06-escape'
    New-Item -ItemType Directory -Force $r06escape | Out-Null
    [System.IO.Directory]::Delete((Join-Path $r06op 'episodes'), $true)
    New-Item -ItemType Junction -Path (Join-Path $r06op 'episodes') -Target $r06escape | Out-Null
    $r06 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r06store }
    $r06code = ''; if ($null -ne $r06.Json) { $r06code = [string]$r06.Json.code }
    Add-Check -Id 'R06a' -Desc 'F1: episodes\ junction refused (no follow)' -Expected 'E_STORE_CORRUPT' -Actual $r06code
    Add-Check -Id 'R06b' -Desc 'F1: nothing written across the junction' -Expected '0' -Actual ([string]@(Get-ChildItem (Join-Path $r06escape '*.json') -ErrorAction SilentlyContinue).Count)

    # R07 -- FIX1-verify F1 (HIGH): the same junction must not turn the
    # heal sweep into an external DELETE. An external non-manifest file
    # must survive.
    $r07store = Join-Path $Scratch 'r07-store'
    New-Item -ItemType Directory -Force $r07store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r07store -Recurse
    $r07op = Join-Path $r07store 'operators\op-grok-01'
    $r07escape = Join-Path $Scratch 'r07-escape'
    New-Item -ItemType Directory -Force $r07escape | Out-Null
    Set-Content -Path (Join-Path $r07escape 'bystander.json') -Value '{"x":1}' -Encoding ASCII
    [System.IO.Directory]::Delete((Join-Path $r07op 'episodes'), $true)
    New-Item -ItemType Junction -Path (Join-Path $r07op 'episodes') -Target $r07escape | Out-Null
    $r07 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r07store }
    Add-Check -Id 'R07' -Desc 'F1: external file NOT deleted by heal across junction' -Expected 'True' -Actual ([string](Test-Path (Join-Path $r07escape 'bystander.json')))

    # R08 -- FIX1-verify F2 (HIGH): a foreign directory planted at a
    # commit-target path (an episode name) must not commit a phantom or
    # advance the manifest. Shape guard freezes; manifest byte-identical.
    $r08store = Join-Path $Scratch 'r08-store'
    New-Item -ItemType Directory -Force $r08store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r08store -Recurse
    $r08op = Join-Path $r08store 'operators\op-grok-01'
    $r08c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r08store }
    $r08sid = $r08c.Json.sessionId
    $r08mBefore = (Get-FileHash (Join-Path $r08op 'manifest.json')).Hash
    New-Item -ItemType Directory -Path (Join-Path $r08op 'episodes\phantom-episode-1.json') | Out-Null
    $r08 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r08sid; Outcome = 'completed'; Notes = 'phantom'; StoreRoot = $r08store }
    $r08code = ''; if ($null -ne $r08.Json) { $r08code = [string]$r08.Json.code }
    Add-Check -Id 'R08a' -Desc 'F2: foreign dir at commit target frozen, no phantom' -Expected 'E_STORE_CORRUPT' -Actual $r08code
    $r08mAfter = (Get-FileHash (Join-Path $r08op 'manifest.json')).Hash
    Add-Check -Id 'R08b' -Desc 'F2: manifest never advanced by the faulted commit' -Expected 'True' -Actual ([string]($r08mBefore -ceq $r08mAfter))

    # R04 -- FIX1-verify F2: the live rollback path with verification
    # INSIDE the try. Hold state.json open (FileShare.Read: the tool can
    # still read it) during an append; File.Replace on it throws AFTER the
    # episode already committed, so the rollback must remove the episode,
    # leave the manifest unchanged, and the store must be usable once the
    # handle releases.
    $storeRB = Join-Path $Scratch 'r04-store'
    New-Item -ItemType Directory -Force $storeRB | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $storeRB -Recurse
    $opRB = Join-Path $storeRB 'operators\op-grok-01'
    $rbCreate = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $storeRB }
    $rbSid = $rbCreate.Json.sessionId
    $rbMBefore = (Get-FileHash (Join-Path $opRB 'manifest.json')).Hash
    $rbHandle = [System.IO.File]::Open((Join-Path $opRB 'state.json'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $r04 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $rbSid; Outcome = 'completed'; Notes = 'rollback'; StoreRoot = $storeRB }
    $rbHandle.Close(); $rbHandle.Dispose()
    $r04state = 'no-fault'
    if ($r04.Exit -eq 3 -and ([string]$r04.Json.message) -clike '*rolled back*') { $r04state = 'rolled-back' }
    Add-Check -Id 'R04a' -Desc 'F2: mid-commit fault rolls back with report' -Expected 'rolled-back' -Actual $r04state
    $rbMAfter = (Get-FileHash (Join-Path $opRB 'manifest.json')).Hash
    Add-Check -Id 'R04b' -Desc 'F2: rollback left no partial state' -Expected 'manifestSame=True;orphans=0' -Actual ('manifestSame={0};orphans={1}' -f ($rbMBefore -ceq $rbMAfter), (Get-EpisodeOrphanCount -OpDir $opRB))
    $r04c = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $rbSid; Outcome = 'completed'; Notes = 'after rollback'; StoreRoot = $storeRB }
    $r04cState = 'refused'; if ($r04c.Exit -eq 0 -and $r04c.Json.ok) { $r04cState = ('ok:seq' + $r04c.Json.seq) }
    Add-Check -Id 'R04c' -Desc 'F2: store fully usable after rollback' -Expected 'ok:seq1' -Actual $r04cState

    # R09 -- FIX1-verify F2: manifest forward-recovery. A manifest lost
    # in the replace window (absent on disk, valid staged copy present) is
    # completed forward, not frozen.
    $r09store = Join-Path $Scratch 'r09-store'
    New-Item -ItemType Directory -Force $r09store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r09store -Recurse
    $r09op = Join-Path $r09store 'operators\op-grok-01'
    $r09c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r09store }
    Copy-Item (Join-Path $r09op 'manifest.json') (Join-Path $r09op 'manifest.json.new') -Force
    [System.IO.File]::Delete((Join-Path $r09op 'manifest.json'))
    $r09 = Invoke-Tool -ScriptPath $close -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r09c.Json.sessionId; StoreRoot = $r09store }
    $r09state = 'failed'
    if ($r09.Exit -eq 0 -and $r09.Json.ok -and ((@($r09.Json.healed) -join ';') -clike '*forward-completed manifest*')) { $r09state = 'forward-recovered' }
    Add-Check -Id 'R09' -Desc 'F2: manifest absent+staged is forward-completed, not frozen' -Expected 'forward-recovered' -Actual $r09state

    # R10 -- FIX1-verify F2: orphan episodes are QUARANTINED, never
    # deleted -- a manifest-lkg restore must not destroy committed data.
    $r10store = Join-Path $Scratch 'r10-store'
    New-Item -ItemType Directory -Force $r10store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r10store -Recurse
    $r10op = Join-Path $r10store 'operators\op-grok-01'
    Set-Content -Path (Join-Path $r10op 'episodes\19990101T000000Z-9.json') -Value '{ "schemaVersion": 1, "operatorId": "op-grok-01", "sessionId": "orphan", "startedUtc": "1999-01-01T00:00:00Z", "endedUtc": "1999-01-01T00:00:00Z", "outcome": "failed", "notes": "real data" }' -Encoding ASCII
    $r10 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r10store }
    $r10orig = -not (Test-Path (Join-Path $r10op 'episodes\19990101T000000Z-9.json'))
    $r10quar = @(Get-ChildItem (Join-Path $r10op 'episodes\*.orphan') -ErrorAction SilentlyContinue).Count
    Add-Check -Id 'R10' -Desc 'F2: orphan episode quarantined (preserved), not deleted' -Expected 'renamed=True;preserved=True' -Actual ('renamed={0};preserved={1}' -f $r10orig, ($r10quar -ge 1))

    # R11 -- FIX1-verify F2: single-writer lock. A second holder of the
    # exclusive lock makes a lifecycle op refuse (not race); the op works
    # once the lock releases.
    $r11store = Join-Path $Scratch 'r11-store'
    New-Item -ItemType Directory -Force $r11store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r11store -Recurse
    $r11op = Join-Path $r11store 'operators\op-grok-01'
    $r11lock = [System.IO.File]::Open((Join-Path $r11op '.session.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $r11a = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r11store }
    $r11aState = ''; if ($null -ne $r11a.Json) { $r11aState = [string]$r11a.Json.code }
    Add-Check -Id 'R11a' -Desc 'F2: concurrent lock holder refuses the op' -Expected 'E_INTERNAL' -Actual $r11aState
    $r11lock.Close(); $r11lock.Dispose()
    $r11b = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r11store }
    Add-Check -Id 'R11b' -Desc 'F2: op succeeds once the lock releases' -Expected 'True' -Actual ([string]($r11b.Exit -eq 0 -and $r11b.Json.ok))

    # R12 -- FIX1-verify round-3: the lock path is the one write primitive
    # before the shape guard, so it self-checks -- a reparse point planted
    # at .session.lock is refused, not followed.
    $r12store = Join-Path $Scratch 'r12-store'
    New-Item -ItemType Directory -Force $r12store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r12store -Recurse
    $r12op = Join-Path $r12store 'operators\op-grok-01'
    $r12ext = Join-Path $Scratch 'r12-ext'; New-Item -ItemType Directory -Force $r12ext | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $r12op '.session.lock') -Target $r12ext | Out-Null
    $r12 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r12store }
    $r12code = ''; if ($null -ne $r12.Json) { $r12code = [string]$r12.Json.code }
    Add-Check -Id 'R12' -Desc 'FIX1-verify: reparse at lock path refused (no follow)' -Expected 'E_STORE_CORRUPT' -Actual $r12code

    # R13 -- FIX1-verify round-3: a HIDDEN orphan episode is still seen
    # (enumeration uses -Force) and quarantined, closing the hidden-file
    # accounting/heal blind spot.
    $r13store = Join-Path $Scratch 'r13-store'
    New-Item -ItemType Directory -Force $r13store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r13store -Recurse
    $r13op = Join-Path $r13store 'operators\op-grok-01'
    $r13ep = Join-Path $r13op 'episodes\hidden-orphan.json'
    Set-Content -Path $r13ep -Value '{ "schemaVersion": 1, "operatorId": "op-grok-01", "sessionId": "orphan", "startedUtc": "1999-01-01T00:00:00Z", "endedUtc": "1999-01-01T00:00:00Z", "outcome": "failed", "notes": "hidden" }' -Encoding ASCII
    [System.IO.File]::SetAttributes($r13ep, [System.IO.FileAttributes]::Hidden)
    $r13 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r13store }
    $r13state = 'not-healed'
    if ($r13.Exit -eq 0 -and ((@($r13.Json.healed) -join ';') -clike '*quarantined orphan*') -and -not (Test-Path $r13ep)) { $r13state = 'hidden-orphan-quarantined' }
    Add-Check -Id 'R13' -Desc 'FIX1-verify: hidden orphan enumerated (-Force) and quarantined' -Expected 'hidden-orphan-quarantined' -Actual $r13state

    # R14 -- CONSISTENCY CHECK, NOT A FAILS-ON-OLD REGRESSION.
    # FIX2 F4 (LOW), conceded to the cross-maker reviewer: this check
    # compares the reported pin with the on-disk pin after an ORDINARY
    # SUCCESSFUL append. The pre-FIX1-verify code re-read the pin from disk
    # after the commit, and that re-read returns the same value on a
    # healthy filesystem -- so the OLD code passes this check too, absent
    # the transient read fault that motivated the cure. It therefore does
    # NOT satisfy law 1847 and must not be counted as proof of its cure.
    # It is retained as a genuine consistency invariant (reported pin ==
    # on-disk pin) under an honest label. No differential test for that
    # cure is constructible: every value the fixed code reports is also
    # read PRE-commit by the staging readback, so any injected fault that
    # would break the post-commit read breaks the pre-commit read first and
    # the transaction never reaches the reporting line. The claim is
    # narrowed rather than a synthetic differential manufactured.
    $r14store = Join-Path $Scratch 'r14-store'
    New-Item -ItemType Directory -Force $r14store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r14store -Recurse
    $r14c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r14store }
    $r14a = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r14c.Json.sessionId; Outcome = 'completed'; Notes = 'pin check'; StoreRoot = $r14store }
    $r14match = 'no-result'
    if ($r14a.Exit -eq 0 -and $r14a.Json.ok) {
        $epPath = Join-Path (Join-Path $r14store 'operators\op-grok-01') $r14a.Json.episodeFile
        $actualPin = ('{0} B / {1}' -f (Get-Item $epPath).Length, (Get-FileHash -Algorithm SHA256 $epPath).Hash)
        $r14match = [string]($r14a.Json.episodePin -ceq $actualPin)
    }
    Add-Check -Id 'R14' -Desc 'FIX1-verify (consistency check, NOT fails-on-old): reported staged pin equals on-disk pin' -Expected 'True' -Actual $r14match

    # R05 -- F3 (reviewer's construction): set the limit to exactly
    # current usage + episode bytes. Old code admitted the write and
    # landed hundreds of bytes over; new code refuses E_LIMIT on the
    # projected post-commit footprint and writes nothing.
    $probeStore = Join-Path $Scratch 'r05-probe'
    New-Item -ItemType Directory -Force $probeStore | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $probeStore -Recurse
    $p1 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $probeStore }
    $p2 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $p1.Json.sessionId; Outcome = 'completed'; Notes = 'limit probe payload'; StoreRoot = $probeStore }
    $probeEp = @(Get-ChildItem (Join-Path $probeStore 'operators\op-grok-01\episodes\*.json'))[0]
    $epBytes = [long]$probeEp.Length

    $limitStore = Join-Path $Scratch 'r05-store'
    New-Item -ItemType Directory -Force $limitStore | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $limitStore -Recurse
    $l1 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $limitStore }
    $opL = Join-Path $limitStore 'operators\op-grok-01'
    $usageNow = [long]0
    foreach ($f in @(Get-ChildItem -LiteralPath $opL -Recurse -File)) { $usageNow += $f.Length }
    $cfgObj = Get-Content (Join-Path $RepoRoot 'config\intellibot.local.json') -Raw | ConvertFrom-Json
    $cfgObj.store.limits.maxTotalBytesPerOperator = ($usageNow + $epBytes)
    $cfgPath = Join-Path $Scratch 'r05-config.json'
    [System.IO.File]::WriteAllText($cfgPath, (ConvertTo-Json $cfgObj -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    $lBefore = Get-TreeFingerprint -Root $opL
    $r05 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $l1.Json.sessionId; Outcome = 'completed'; Notes = 'limit probe payload'; StoreRoot = $limitStore; ConfigPath = $cfgPath }
    $r05code = ''; if ($null -ne $r05.Json) { $r05code = [string]$r05.Json.code }
    Add-Check -Id 'R05a' -Desc ('F3: exact-limit ({0}+{1} B) refused on projected footprint' -f $usageNow, $epBytes) -Expected 'E_LIMIT' -Actual $r05code
    $lAfter = Get-TreeFingerprint -Root $opL
    $r05b = 'CHANGED'; if ($lBefore -ceq $lAfter) { $r05b = 'BYTE-IDENTICAL' }
    Add-Check -Id 'R05b' -Desc 'F3: refused write landed zero bytes' -Expected 'BYTE-IDENTICAL' -Actual $r05b

    # ---------------- FIX2 regressions (cross-vendor regrade) -----------
    # From the LUNA (OpenAI Codex, GPT-5 family) REQUEST_CHANGES regrade of
    # record, 2026-08-22. Each is built to FAIL on the pre-FIX2 tree and
    # PASS on the fixed tree (law 1847). Where a differential is NOT
    # constructible that is stated at the check, never papered over.

    # R15 -- FIX2 F1 (HIGH): FIRST-GENERATION HARD-CRASH RESIDUE.
    # ATTRIBUTION, stated precisely (FIX2-verify): R15 is a differential
    # for the SEED RESEED half of the F1 cure, not for the baseline guard.
    # Once the manifest attests anything at all, pre-existing FIX1
    # machinery (sweep step 4, .lkg rollback) performs the recovery -- so
    # reverting Test-IbManifestBaseline alone leaves R15 passing. The
    # GUARD half is pinned by R16a/R16b and R20/R21. Both halves are part
    # of the cure and each has its own differential; neither check should
    # be read as covering the other.
    # Reproduces the reviewer's recorded scratch positive exactly: a crash
    # AFTER the state File.Replace but BEFORE the manifest File.Replace.
    # On the pre-FIX2 tree the shipped manifest seeded lastKnownGood null,
    # so the sweep tracked ZERO documents, rolled back nothing, verified
    # nothing, and silently accepted the unattested new state -- the
    # reviewer measured exit 2 / E_INTERNAL / "session already open" with
    # the manifest byte-identical and zero tracked entries. On the fixed
    # tree the seeded baseline lets the sweep roll state.json back from its
    # .lkg to the manifest-attested generation and the create proceeds.
    $r15store = Join-Path $Scratch 'r15-store'
    New-Item -ItemType Directory -Force $r15store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r15store -Recurse
    $r15op = Join-Path $r15store 'operators\op-grok-01'

    $r15oldState = Get-Content (Join-Path $r15op 'state.json') -Raw | ConvertFrom-Json
    $r15newStateText = ((ConvertTo-Json ([ordered]@{
        schemaVersion = 1
        operatorId    = 'op-grok-01'
        lifecycle     = 'open'
        stateVersion  = ([long]$r15oldState.stateVersion + 1)
        lastSessionId = 'sess-crash-window-probe'
        updatedUtc    = '2026-08-22T09:20:00Z'
    }) -Depth 4) + "`n")
    [System.IO.File]::WriteAllText((Join-Path $r15op 'state.json.new'), $r15newStateText, (New-Object System.Text.UTF8Encoding($false)))
    # the exact primitive the commit loop uses -- new state live, previous
    # generation preserved as .lkg, in one atomic operation
    [System.IO.File]::Replace((Join-Path $r15op 'state.json.new'), (Join-Path $r15op 'state.json'), (Join-Path $r15op 'state.json.lkg'))
    # ...and the manifest that WOULD have been committed, left staged only
    $r15m = Get-Content (Join-Path $r15op 'manifest.json') -Raw | ConvertFrom-Json
    $r15m.lastKnownGood.'state.json'.sha256 = (Get-FileHash -LiteralPath (Join-Path $r15op 'state.json') -Algorithm SHA256).Hash
    $r15m.lastKnownGood.'state.json'.bytes  = (Get-Item -LiteralPath (Join-Path $r15op 'state.json')).Length
    [System.IO.File]::WriteAllText((Join-Path $r15op 'manifest.json.new'), ((ConvertTo-Json $r15m -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    $r15 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r15store }
    $r15aState = 'no-result'
    if ($null -ne $r15.Json) {
        if ($r15.Exit -eq 0 -and $r15.Json.ok) { $r15aState = 'ok' }
        else { $r15aState = ('refused:' + [string]$r15.Json.code) }
    }
    Add-Check -Id 'R15a' -Desc 'F1: first-generation crash residue is recovered, not silently accepted' -Expected 'ok' -Actual $r15aState

    $r15healed = ''
    if ($null -ne $r15.Json -and $r15.Exit -eq 0) { $r15healed = (@($r15.Json.healed) -join '; ') }
    Add-Check -Id 'R15b' -Desc 'F1: recovery rolled state.json back from .lkg to the attested generation' -Expected 'True' -Actual ([string]($r15healed -clike '*rolled back state.json from .lkg*'))

    $r15c = 'False'
    if ($r15.Exit -eq 0 -and $null -ne $r15.Json -and $r15.Json.ok) {
        $r15live = Get-Content (Join-Path $r15op 'state.json') -Raw | ConvertFrom-Json
        $r15c = [string](($r15live.lastSessionId -ceq $r15.Json.sessionId) -and ($r15live.lastSessionId -cne 'sess-crash-window-probe'))
    }
    Add-Check -Id 'R15c' -Desc 'F1: orphaned crash session discarded; live state carries the newly minted session' -Expected 'True' -Actual $r15c

    # R16 -- FIX2 F1 (HIGH), the general half: a manifest that attests
    # NOTHING must FREEZE, not degrade into an empty trust map. This is the
    # rule that stops the defect being reintroduced by any future operator
    # shipped with a null baseline. Pre-FIX2: exit 0, store reported
    # integral over documents nothing attested.
    $r16store = Join-Path $Scratch 'r16-store'
    New-Item -ItemType Directory -Force $r16store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r16store -Recurse
    $r16op = Join-Path $r16store 'operators\op-grok-01'
    $r16m = Get-Content (Join-Path $r16op 'manifest.json') -Raw | ConvertFrom-Json
    $r16m.lastKnownGood = $null
    [System.IO.File]::WriteAllText((Join-Path $r16op 'manifest.json'), ((ConvertTo-Json $r16m -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r16 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r16store }
    $r16code = ''; if ($null -ne $r16.Json) { $r16code = [string]$r16.Json.code }
    Add-Check -Id 'R16a' -Desc 'F1: null lastKnownGood freezes instead of becoming an empty trust map' -Expected 'E_STORE_CORRUPT' -Actual $r16code

    # ...and the same for a baseline that is present but INCOMPLETE.
    $r16bstore = Join-Path $Scratch 'r16b-store'
    New-Item -ItemType Directory -Force $r16bstore | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r16bstore -Recurse
    $r16bop = Join-Path $r16bstore 'operators\op-grok-01'
    $r16bm = Get-Content (Join-Path $r16bop 'manifest.json') -Raw | ConvertFrom-Json
    $r16bm.lastKnownGood.PSObject.Properties.Remove('state.json')
    [System.IO.File]::WriteAllText((Join-Path $r16bop 'manifest.json'), ((ConvertTo-Json $r16bm -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r16b = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r16bstore }
    $r16bcode = ''; if ($null -ne $r16b.Json) { $r16bcode = [string]$r16b.Json.code }
    Add-Check -Id 'R16b' -Desc 'F1: a required document missing from the baseline freezes the store' -Expected 'E_STORE_CORRUPT' -Actual $r16bcode

    # R17 -- FIX2 F2 (MED): THE ROLLBACK-FAILURE PATH IS EXECUTED, not
    # established statically. The reviewer noted R04 proves one SUCCESSFUL
    # rollback only and that the failure trigger was static-only.
    #
    # Trigger, derived on this sensor and fully in-process (no process
    # creation): Win32 ReplaceFile PRESERVES the destination's security
    # descriptor, so a Deny(WriteData|AppendData) ACE placed on the live
    # summary-current.json survives the commit onto the newly committed
    # file. Denying exactly those two rights leaves WriteAttributes and
    # DELETE intact, so SetAttributes and File.Replace still succeed and
    # the document really does commit; only the ROLLBACK's Copy-Item write
    # is denied. The transaction is forced to fault AFTER that commit by
    # holding manifest.json open FileShare.Read so its own Replace throws.
    # Pre-FIX2 outcome (measured on this sensor before the fix): exit 3 /
    # E_INTERNAL / "commit failed and was rolled back to the
    # manifest-attested state" -- a false claim, since the rollback log in
    # the same string said the restoration had failed.
    $r17store = Join-Path $Scratch 'r17-store'
    New-Item -ItemType Directory -Force $r17store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r17store -Recurse
    $r17op = Join-Path $r17store 'operators\op-grok-01'
    $r17c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r17store }
    $r17sid = $r17c.Json.sessionId
    $null = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r17sid; Outcome = 'completed'; Notes = 'r17'; StoreRoot = $r17store }

    $r17sum  = Join-Path $r17op 'summary-current.json'
    $r17me   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $r17deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $r17me,
        ([System.Security.AccessControl.FileSystemRights]::WriteData -bor [System.Security.AccessControl.FileSystemRights]::AppendData),
        [System.Security.AccessControl.AccessControlType]::Deny)
    $r17 = $null
    try {
        $r17acl = Get-Acl -LiteralPath $r17sum
        $r17acl.AddAccessRule($r17deny)
        Set-Acl -LiteralPath $r17sum -AclObject $r17acl
        $r17mh = [System.IO.File]::Open((Join-Path $r17op 'manifest.json'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $r17 = Invoke-Tool -ScriptPath $close -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r17sid; StoreRoot = $r17store }
        } finally { $r17mh.Close(); $r17mh.Dispose() }
    } finally {
        # always lift the deny ACE, or the scratch tree becomes unusable
        $r17aclR = Get-Acl -LiteralPath $r17sum
        [void]$r17aclR.RemoveAccessRule($r17deny)
        Set-Acl -LiteralPath $r17sum -AclObject $r17aclR
    }
    $r17code = ''; if ($null -ne $r17 -and $null -ne $r17.Json) { $r17code = [string]$r17.Json.code }
    Add-Check -Id 'R17a' -Desc 'F2: a rollback that did NOT fully restore reports E_STORE_CORRUPT, not E_INTERNAL' -Expected 'E_STORE_CORRUPT' -Actual $r17code
    $r17msg = ''; if ($null -ne $r17 -and $null -ne $r17.Json) { $r17msg = [string]$r17.Json.message }
    # NOTE: ordinal .Contains, not -clike -- the expected substrings carry
    # square brackets, which -clike parses as a wildcard character class.
    Add-Check -Id 'R17b' -Desc 'F2: the outcome stops claiming a full rollback and names the failed leaf' -Expected 'honest=True;names=True' -Actual ('honest={0};names={1}' -f $r17msg.Contains('did NOT fully restore'), $r17msg.Contains('failed restorations: [summary-current.json]'))
    # the independent half: post-rollback verification re-read the store
    # against the manifest and agreed, rather than trusting the loop.
    Add-Check -Id 'R17c' -Desc 'F2: post-rollback verification independently confirms the store does not match the manifest' -Expected 'True' -Actual ([string]$r17msg.Contains('still not matching the manifest: [summary-current.json'))

    # R18 -- FIX2 F3 (LOW): the store DERIVES append-only from the leaf.
    # Calls the store layer directly with the caller flag deliberately set
    # to $false for an EXISTING episode -- the exact future-regression the
    # reviewer named. Pre-FIX2 the store trusted that flag and overwrote a
    # committed episode; now the episodes\*.json leaf is append-only by the
    # store's own law and the overwrite is refused.
    . (Join-Path $Tools 'lib\intellibot-store.ps1')
    $r18store = Join-Path $Scratch 'r18-store'
    New-Item -ItemType Directory -Force $r18store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r18store -Recurse
    $r18op = Join-Path $r18store 'operators\op-grok-01'
    $r18c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r18store }
    $null = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r18c.Json.sessionId; Outcome = 'completed'; Notes = 'r18'; StoreRoot = $r18store }
    $r18epName = @(Get-ChildItem (Join-Path $r18op 'episodes\*.json'))[0].Name
    $r18before = (Get-FileHash -LiteralPath (Join-Path $r18op ('episodes\' + $r18epName)) -Algorithm SHA256).Hash
    $r18state = 'OVERWROTE'
    try {
        $null = Invoke-IbStoreCommit -OperatorDir $r18op -MaxTotalBytes 4194304 -Writes @(
            @{ Rel = ('episodes\' + $r18epName); AppendOnly = $false; Document = [ordered]@{
                schemaVersion = 1; operatorId = 'op-grok-01'; sessionId = 'overwrite-attempt'
                startedUtc = '1999-01-01T00:00:00Z'; endedUtc = '1999-01-01T00:00:00Z'
                outcome = 'failed'; notes = 'store-layer append-only probe' } }
        )
    } catch {
        if ($_.Exception.Message -clike '*append-only violation*') { $r18state = 'refused' }
        else { $r18state = ('other-fault:' + $_.Exception.Message) }
    }
    Add-Check -Id 'R18a' -Desc 'F3: store refuses an episode overwrite even when the caller says AppendOnly=$false' -Expected 'refused' -Actual $r18state
    $r18after = (Get-FileHash -LiteralPath (Join-Path $r18op ('episodes\' + $r18epName)) -Algorithm SHA256).Hash
    Add-Check -Id 'R18b' -Desc 'F3: the committed episode is byte-identical after the refused overwrite' -Expected 'True' -Actual ([string]($r18before -ceq $r18after))

    # R19 -- FIX2 F5 (LOW): healing performed by the pre-op sweep is
    # surfaced ON A REFUSAL, not only on success. Pre-FIX2 the refusal
    # object carried no healed field at all, while the contract text still
    # said a refusal leaves "nothing changed" -- yet the sweep had already
    # deleted staging residue by then.
    $r19store = Join-Path $Scratch 'r19-store'
    New-Item -ItemType Directory -Force $r19store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r19store -Recurse
    $r19op = Join-Path $r19store 'operators\op-grok-01'
    $null = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r19store }
    [System.IO.File]::WriteAllText((Join-Path $r19op 'state.json.new'), '{}', (New-Object System.Text.UTF8Encoding($false)))
    $r19 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r19store }
    $r19code = ''; if ($null -ne $r19.Json) { $r19code = [string]$r19.Json.code }
    Add-Check -Id 'R19a' -Desc 'F5: the unrelated session-state refusal still refuses' -Expected 'E_INTERNAL' -Actual $r19code
    $r19heal = 'absent'
    if ($null -ne $r19.Json -and (@($r19.Json.PSObject.Properties.Name) -ccontains 'healed')) {
        if ((@($r19.Json.healed) -join '; ') -clike '*staging-residue*') { $r19heal = 'reported' }
        else { $r19heal = 'present-but-empty' }
    }
    Add-Check -Id 'R19b' -Desc 'F5: healing performed before the refusal is reported on the refusal' -Expected 'reported' -Actual $r19heal

    # ------- FIX2-VERIFY regressions (author's own adversarial pass) ----
    # Four independent read-only refuters were run against the FIX2 cure
    # before it was returned. These cover the defects they found IN THE
    # CURE ITSELF. Each fails on the FIX2-as-first-written code.

    # R20 -- the manifest ENVELOPE is validated, not just lastKnownGood.
    # As first written, Test-IbManifestBaseline checked only lastKnownGood,
    # so a manifest carrying schemaVersion + lastKnownGood alone (exactly
    # what the freeze message tells an operator to reseed) PASSED the sweep
    # and then faulted every commit at the unguarded $manifest.operatorId
    # read, which sits OUTSIDE the rollback envelope -- surfacing as
    # E_INTERNAL "tool fault: The property operatorId cannot be found".
    # A permanently unwritable store reported as a transient error.
    $r20store = Join-Path $Scratch 'r20-store'
    New-Item -ItemType Directory -Force $r20store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r20store -Recurse
    $r20op = Join-Path $r20store 'operators\op-grok-01'
    $r20m = Get-Content (Join-Path $r20op 'manifest.json') -Raw | ConvertFrom-Json
    $r20m.PSObject.Properties.Remove('operatorId')
    [System.IO.File]::WriteAllText((Join-Path $r20op 'manifest.json'), ((ConvertTo-Json $r20m -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r20 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r20store }
    $r20code = ''; if ($null -ne $r20.Json) { $r20code = [string]$r20.Json.code }
    Add-Check -Id 'R20' -Desc 'FIX2-verify: a manifest missing an identity field freezes, not E_INTERNAL at commit' -Expected 'E_STORE_CORRUPT' -Actual $r20code

    # R21 -- EVERY tracked entry is shape-validated, not only the three
    # required ones. Episodes are exempt from being REQUIRED; they were
    # wrongly also exempt from being WELL-FORMED, so one malformed episode
    # entry hit an unguarded $entry.sha256 under StrictMode mid-sweep --
    # after staging residue was already deleted -- and surfaced as
    # E_INTERNAL rather than freezing the genuinely corrupt store.
    $r21store = Join-Path $Scratch 'r21-store'
    New-Item -ItemType Directory -Force $r21store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r21store -Recurse
    $r21op = Join-Path $r21store 'operators\op-grok-01'
    $r21c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r21store }
    $null = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r21c.Json.sessionId; Outcome = 'completed'; Notes = 'r21'; StoreRoot = $r21store }
    $r21m = Get-Content (Join-Path $r21op 'manifest.json') -Raw | ConvertFrom-Json
    $r21epKey = @($r21m.lastKnownGood.PSObject.Properties.Name | Where-Object { $_ -clike 'episodes*' })[0]
    $r21m.lastKnownGood.$r21epKey = 'corrupt-not-an-object'
    [System.IO.File]::WriteAllText((Join-Path $r21op 'manifest.json'), ((ConvertTo-Json $r21m -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r21 = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r21c.Json.sessionId; Outcome = 'completed'; Notes = 'r21b'; StoreRoot = $r21store }
    $r21code = ''; if ($null -ne $r21.Json) { $r21code = [string]$r21.Json.code }
    Add-Check -Id 'R21' -Desc 'FIX2-verify: a malformed EPISODE manifest entry freezes, not a StrictMode E_INTERNAL' -Expected 'E_STORE_CORRUPT' -Actual $r21code

    # R22 -- the line-ending DIAGNOSTIC. `.gitattributes` normalizes text
    # (`* text=auto`), so a checkout whose convention differs from the one
    # that produced the manifest fails every attested checksum. That is
    # indistinguishable from corruption by the hash alone. The freeze now
    # says which it is. R22a: an EOL-only difference is named as such.
    # R22b (control): real corruption must NOT get the reassuring note.
    $r22store = Join-Path $Scratch 'r22-store'
    New-Item -ItemType Directory -Force $r22store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r22store -Recurse
    $r22op = Join-Path $r22store 'operators\op-grok-01'
    $r22path = Join-Path $r22op 'state.json'
    $r22text = [System.IO.File]::ReadAllText($r22path)
    [System.IO.File]::WriteAllText($r22path, $r22text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r22 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r22store }
    $r22msg = ''; if ($null -ne $r22.Json) { $r22msg = [string]$r22.Json.message }
    Add-Check -Id 'R22a' -Desc 'FIX2-verify: an EOL-only mismatch freezes AND is named as a line-ending difference' -Expected 'frozen=True;named=True' -Actual ('frozen={0};named={1}' -f ([string]$r22.Json.code -ceq 'E_STORE_CORRUPT'), $r22msg.Contains('NOT data corruption'))

    $r22bstore = Join-Path $Scratch 'r22b-store'
    New-Item -ItemType Directory -Force $r22bstore | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r22bstore -Recurse
    $r22bpath = Join-Path $r22bstore 'operators\op-grok-01\state.json'
    $r22bytes = [System.IO.File]::ReadAllBytes($r22bpath)
    $r22bytes[$r22bytes.Length - 5] = 88
    [System.IO.File]::WriteAllBytes($r22bpath, $r22bytes)
    $r22b = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r22bstore }
    $r22bmsg = ''; if ($null -ne $r22b.Json) { $r22bmsg = [string]$r22b.Json.message }
    Add-Check -Id 'R22b' -Desc 'FIX2-verify control: REAL corruption freezes WITHOUT the line-ending note' -Expected 'frozen=True;named=False' -Actual ('frozen={0};named={1}' -f ([string]$r22b.Json.code -ceq 'E_STORE_CORRUPT'), $r22bmsg.Contains('NOT data corruption'))

    # R23 -- forward-recovery promotes a staged manifest ONLY when it
    # matches the documents on disk. The rollback path tolerates a staging
    # cleanup failure on the ground that "the next sweep removes it" --
    # true only while manifest.json still exists. If the manifest is later
    # lost, step 0 fired first and promoted that STALE staged manifest as
    # the new root of trust after nothing but a parse check; step 4 then
    # rolled every live document back from .lkg to "restore" a generation
    # that had been explicitly reverted, silently destroying a committed
    # append. No attacker required. Now the staged manifest is verified
    # against live bytes and a mismatch freezes.
    $r23store = Join-Path $Scratch 'r23-store'
    New-Item -ItemType Directory -Force $r23store | Out-Null
    Copy-Item -Path (Join-Path $RepoRoot 'store\v1\*') -Destination $r23store -Recurse
    $r23op = Join-Path $r23store 'operators\op-grok-01'
    $r23c = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r23store }
    # capture generation 1's manifest IN MEMORY (planting it on disk now
    # would only have the next transaction's staging consume it)
    $r23stale = [System.IO.File]::ReadAllText((Join-Path $r23op 'manifest.json'))
    $r23a = Invoke-Tool -ScriptPath $append -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $r23c.Json.sessionId; Outcome = 'completed'; Notes = 'r23 committed append'; StoreRoot = $r23store }
    $r23epRel = [string]$r23a.Json.episodeFile
    # now the store is at generation 2; plant generation 1's manifest as
    # staging residue and lose the live manifest
    [System.IO.File]::WriteAllText((Join-Path $r23op 'manifest.json.new'), $r23stale, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Delete((Join-Path $r23op 'manifest.json'))
    $r23 = Invoke-Tool -ScriptPath $create -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $r23store }
    $r23code = ''; if ($null -ne $r23.Json) { $r23code = [string]$r23.Json.code }
    Add-Check -Id 'R23a' -Desc 'FIX2-verify: a STALE staged manifest is not forward-completed, it freezes' -Expected 'E_STORE_CORRUPT' -Actual $r23code
    Add-Check -Id 'R23b' -Desc 'FIX2-verify: the committed append survives (not reverted by a bogus forward-recovery)' -Expected 'True' -Actual ([string](Test-Path (Join-Path $r23op $r23epRel)))

    # ---------------- A3-series: FIX1-AMEND regressions ----------------
    # From the GROK review's LOW findings, taken at the author's
    # discretion under the amendment dispatch. Each fails on the
    # pre-amendment code and passes on the amended code (1847).

    # A3-R3 -- operators[] paths from config are containment-guarded. A
    # config naming a path outside the repository tree must refuse
    # E_NOT_HOST and read nothing. (Pre-amendment: the path was joined and
    # read with no guard -- the one caller-supplied path that lacked one.)
    $a3repo = Join-Path $Scratch 'a3r3-repo'
    New-Item -ItemType Directory -Force (Join-Path $a3repo 'config\operators') | Out-Null
    $a3outside = Join-Path $Scratch 'a3r3-outside.operator.json'
    Copy-Item (Join-Path $RepoRoot 'config\operators\grok.operator.json') $a3outside -Force
    $a3cfg = [ordered]@{
        schemaVersion = 1
        configId      = 'a3r3-escape-fixture'
        note          = 'FIXTURE: operators[] deliberately escapes the repo tree; the loader must refuse.'
        operators     = @('../a3r3-outside.operator.json')
    }
    [System.IO.File]::WriteAllText((Join-Path $a3repo 'config\intellibot.local.json'), (ConvertTo-Json $a3cfg -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $a3r3 = Invoke-Tool -ScriptPath $loader -Arguments @{ RepoRoot = $a3repo }
    $a3r3code = ''; if ($null -ne $a3r3.Json) { $a3r3code = [string]$a3r3.Json.code }
    Add-Check -Id 'A3-R3' -Desc 'AMEND: operators[] path escaping the repo refused' -Expected 'E_NOT_HOST' -Actual $a3r3code

    # A3-R4 -- the seed-identity control itself sees hidden files. A
    # hidden file added to a tree MUST change its fingerprint; without
    # -Force (pre-amendment) it did not, so N01 could have reported
    # BYTE-IDENTICAL over a tree that had gained a hidden file.
    $a3fp = Join-Path $Scratch 'a3r4-tree'
    New-Item -ItemType Directory -Force $a3fp | Out-Null
    Set-Content -Path (Join-Path $a3fp 'visible.txt') -Value 'v' -Encoding ASCII
    $a3fpBefore = Get-TreeFingerprint -Root $a3fp
    $a3hidden = Join-Path $a3fp 'planted.json'
    Set-Content -Path $a3hidden -Value '{"planted":true}' -Encoding ASCII
    [System.IO.File]::SetAttributes($a3hidden, [System.IO.FileAttributes]::Hidden)
    $a3fpAfter = Get-TreeFingerprint -Root $a3fp
    $a3r4 = 'BLIND'; if ($a3fpBefore -cne $a3fpAfter) { $a3r4 = 'DETECTED' }
    Add-Check -Id 'A3-R4' -Desc 'AMEND: seed-identity control detects a hidden planted file' -Expected 'DETECTED' -Actual $a3r4

    # ---------------- N-series: negative control ----------------------
    $seedAfter = Get-TreeFingerprint -Root (Join-Path $RepoRoot 'store\v1')
    $identity = 'CHANGED'; if ($seedBefore -ceq $seedAfter) { $identity = 'BYTE-IDENTICAL' }
    Add-Check -Id 'N01' -Desc 'seed store\v1 untouched by the whole run' -Expected 'BYTE-IDENTICAL' -Actual $identity

    # ---------------- Results -----------------------------------------
    $passCount = @($Checks | Where-Object { $_.pass }).Count
    $total = $Checks.Count
    $report = [ordered]@{
        harness   = 'test\run-dryrun.ps1'
        runId     = $RunId
        repoRoot  = $RepoRoot
        launches  = 'NONE -- file-level only, in-process invocations'
        passed    = $passCount
        total     = $total
        allPass   = ($passCount -eq $total)
        checks    = @($Checks)
    }
    $jsonPath = Join-Path $Results ('dryrun-' + $RunId + '.json')
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-Json $report -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    $mdLines = New-Object System.Collections.ArrayList
    [void]$mdLines.Add('# Dry-run harness results -- ' + $RunId)
    [void]$mdLines.Add('')
    [void]$mdLines.Add(('Result: {0}/{1} checks passed. Launches: NONE (file-level only).' -f $passCount, $total))
    [void]$mdLines.Add('')
    [void]$mdLines.Add('| id | pass | check | expected | actual |')
    [void]$mdLines.Add('|----|------|-------|----------|--------|')
    foreach ($c in $Checks) {
        $p = 'FAIL'; if ($c.pass) { $p = 'pass' }
        [void]$mdLines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $c.id, $p, $c.desc, $c.expected, $c.actual))
    }
    $mdPath = Join-Path $Results ('dryrun-' + $RunId + '.md')
    [System.IO.File]::WriteAllText($mdPath, (($mdLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Information ('RESULT {0}/{1} passed; report {2}' -f $passCount, $total, $jsonPath) -InformationAction Continue
    ConvertTo-Json -InputObject ([ordered]@{ ok = ($passCount -eq $total); passed = $passCount; total = $total; report = $jsonPath })

    if ($passCount -eq $total) { exit 0 } else { exit 2 }
} catch {
    ConvertTo-Json -InputObject ([ordered]@{ ok = $false; harnessFault = $_.Exception.Message; at = $_.ScriptStackTrace })
    exit 3
}
