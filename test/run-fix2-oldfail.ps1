<#
run-fix2-oldfail.ps1 -- THE OLD-FAIL HALF of the FIX2 regressions.

Law 1847: a regression that does not FAIL on the old code did not prove
its cure. The cross-vendor regrade (LUNA, OpenAI Codex GPT-5 family,
2026-08-22) raised that to apply to the TEST ITSELF (its finding F4), so
this harness exists to DEMONSTRATE the old-fail half rather than assert it
in prose.

It reconstructs a PRE-FIX2 tree in scratch by reversing each FIX2 hunk
exactly, then runs the R15/R16/R17/R18/R19 constructions against it and
asserts each produces the DEFECTIVE outcome.

SCOPE, STATED HONESTLY (corrected FIX2-verify -- an earlier draft of this
header claimed these were "the same constructions", which they are not
everywhere):
  - O15 stages a byte COPY of manifest.json where R15 stages a manifest
    whose state.json attestation is rewritten to the crash generation.
    FORCED, not sloppy: the reversed manifest has lastKnownGood null, so
    R15's mutation would fault under StrictMode. The residue that matters
    (new state live, old state in .lkg, manifest not advanced, a staged
    manifest present) is identical.
  - O16b is the old-tree EQUIVALENT of R16b, not its twin, for the same
    reason: with a null baseline there is no entry to remove, so it writes
    a partial baseline instead.
  - R17c (post-rollback verification) has NO old-tree counterpart, because
    the mechanism it checks did not exist before FIX2. Its old-fail half
    is carried by O17a/O17b, which prove the old code's claim was false.
  - R14 has no counterpart by design: it is a consistency check, not a
    differential (FIX2 F4).
  - R20/R21/R22 target defects in the FIX2 cure found by the author's own
    adversarial pass; their "old" code is FIX2-as-first-written, not the
    pre-FIX2 tree this harness reconstructs, so they are differentials
    against a tree that was never filed and are not mirrored here.

SELF-VERIFYING: every reversal asserts that the anchor text was actually
found and replaced. A stale anchor fails LOUDLY (exit 3) instead of
silently producing a half-old tree that would make the old-fail evidence
worthless. This is the failure mode that matters here: a reversal harness
that quietly reverses nothing "proves" old-fail for code that is already
fixed.

THIS HARNESS LAUNCHES NOTHING: no s&box, no editor, no pawn, no network,
no process creation. Every tool under test is a PowerShell script invoked
IN-PROCESS. Writes are confined to test\scratch\oldfail-<utc>\ and
test\results\. The seed store store\v1 is never written; check ON01
proves it byte-identical before and after.

EXIT: 0 every old-fail check behaved defectively as expected (i.e. the
FIX2 regressions are genuine differentials); 2 at least one did not;
3 harness fault.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RunId    = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$Scratch  = Join-Path $PSScriptRoot ('scratch\oldfail-' + $RunId)
$Results  = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Force $Scratch | Out-Null
New-Item -ItemType Directory -Force $Results | Out-Null

$Checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Id, [string]$Desc, [string]$Expected, [string]$Actual)
    $pass = ($Expected -ceq $Actual)
    [void]$Checks.Add([ordered]@{ id = $Id; desc = $Desc; expected = $Expected; actual = $Actual; pass = $pass })
    $tag = 'FAIL'; if ($pass) { $tag = 'PASS' }
    Write-Information ('{0} {1}: {2} (expected {3}, got {4})' -f $tag, $Id, $Desc, $Expected, $Actual) -InformationAction Continue
}

function Invoke-Tool {
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
    } catch { return @{ Exit = -1; Json = $null; Error = $_.Exception.Message } }
}

function Get-TreeFingerprint {
    param([string]$Root)
    $rows = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash + ' ' + $_.FullName.Substring($Root.Length)
    }
    return ($rows -join "`n")
}

$script:Reversals = 0
function Invoke-Reversal {
    # Exact-text reversal of one FIX2 hunk, with a hard assertion that the
    # anchor was present. Throwing here is the point: a silent no-op would
    # make every old-fail claim below a lie.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$From,
        [AllowEmptyString()][string]$To = ''
    )
    # Normalise BOTH sides to LF before matching: the tree carries CRLF
    # source while the patterns in this file are here-strings, and a
    # line-ending mismatch would raise a false ANCHOR NOT FOUND.
    $text = ([System.IO.File]::ReadAllText($Path)).Replace("`r`n", "`n")
    $fromN = $From.Replace("`r`n", "`n")
    $toN   = $To.Replace("`r`n", "`n")
    if (-not $text.Contains($fromN)) {
        throw ("REVERSAL ANCHOR NOT FOUND for '{0}' in {1} -- the old-tree reconstruction is not trustworthy; refusing to report old-fail evidence from it." -f $Label, $Path)
    }
    $text = $text.Replace($fromN, $toN)
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    $script:Reversals += 1
}

try {
    $seedBefore = Get-TreeFingerprint -Root (Join-Path $RepoRoot 'store\v1')

    # ============ BUILD THE PRE-FIX2 TREE =========================
    $Old = Join-Path $Scratch 'oldtree'
    New-Item -ItemType Directory -Force $Old | Out-Null
    foreach ($sub in @('tools','config','contracts','store')) {
        Copy-Item -Path (Join-Path $RepoRoot $sub) -Destination $Old -Recurse -Force
    }
    $OldTools = Join-Path $Old 'tools'
    $OldLib   = Join-Path $OldTools 'lib\intellibot-store.ps1'

    # --- F1 reversal 1: drop the required-baseline guard from the sweep.
    Invoke-Reversal -Path $OldLib -Label 'F1 sweep baseline guard' -From @'

    # 2b. REQUIRED-BASELINE GUARD (FIX2 F1). This runs BEFORE any
    #     manifest-driven healing below, because with an unattested
    #     manifest step 3 would quarantine every episode as an orphan and
    #     step 4 would roll back nothing -- healing decisions must never be
    #     taken from a trust map that attests nothing.
    $baseline = Test-IbManifestBaseline -Manifest $mr.Doc
    if (-not $baseline.Ok) { return @{ Ok = $false; Healed = @($healed); Failure = $baseline.Failure } }
'@ -To ''

    # --- F1 reversal 2: drop the defense-in-depth guard on the write path.
    Invoke-Reversal -Path $OldLib -Label 'F1 commit baseline guard' -From @'
    # Defense in depth (FIX2 F1): every lifecycle caller sweeps first, but
    # the write path must not depend on that. An unattested manifest here
    # would silently carry an empty lastKnownGood forward into the new
    # manifest, re-creating the untracked-store hole one generation later.
    $mBase = Test-IbManifestBaseline -Manifest $mr.Doc
    if (-not $mBase.Ok) { return @{ Ok = $false; Failure = $mBase.Failure } }
'@ -To ''

    # --- F3 reversal: append-only trusted from caller metadata again.
    Invoke-Reversal -Path $OldLib -Label 'F3 derived append-only' -From @'
            # FIX2 F3: append-only status is DERIVED from the leaf, not
            # merely taken from caller metadata. Every episodes\*.json is
            # append-only by the store's own law (store\v1\SCHEMA.md), so a
            # caller that forgets the flag -- or supplies $false -- can no
            # longer talk the store into overwriting a committed episode.
            # The caller flag is still honoured as an ADDITIONAL assertion
            # for non-episode leaves; it can only ever tighten, never relax.
            AppendOnly = ([bool]$w.AppendOnly -or (Test-IbAppendOnlyRel -Rel $w.Rel))
'@ -To @'
            AppendOnly = [bool]$w.AppendOnly
'@

    # --- F2 reversal: the unconditional "rolled back" claim returns.
    $oldCatch = @'
    } catch {
        $fault = $_.Exception.Message
        $rollbackNotes = New-Object System.Collections.ArrayList
        for ($i = $committed.Count - 1; $i -ge 0; $i--) {
            $c = $committed[$i]
            try {
                if ($c.HadPrevious) {
                    Copy-Item -LiteralPath ($c.Staged.Target + '.lkg') -Destination $c.Staged.Target -Force
                    [void]$rollbackNotes.Add(('restored {0} from .lkg' -f $c.Staged.Rel))
                } else {
                    [System.IO.File]::Delete($c.Staged.Target)
                    [void]$rollbackNotes.Add(('removed uncommitted new file {0}' -f $c.Staged.Rel))
                }
            } catch { [void]$rollbackNotes.Add(('rollback of {0} itself failed: {1} (heals on next sweep)' -f $c.Staged.Rel, $_.Exception.Message)) }
        }
        foreach ($s in $staged) {
            try {
                if (Test-Path -LiteralPath ($s.Target + '.new') -PathType Leaf) { [System.IO.File]::Delete($s.Target + '.new') }
            } catch { [void]$rollbackNotes.Add(('staging cleanup of {0}.new failed: {1} (heals on next sweep)' -f $s.Rel, $_.Exception.Message)) }
        }
        throw ("commit failed and was rolled back to the manifest-attested state -- fault: {0}; rollback: {1}" -f $fault, ($rollbackNotes -join '; '))
    }
'@
    $libText = ([System.IO.File]::ReadAllText($OldLib)).Replace("`r`n", "`n")
    $oldCatchN = $oldCatch.Replace("`r`n", "`n")
    $catchStart = $libText.IndexOf("    } catch {`n        `$fault = `$_.Exception.Message")
    if ($catchStart -lt 0) { throw 'REVERSAL ANCHOR NOT FOUND for F2 rollback catch block' }
    $catchEndMarker = '        throw ("commit failed and was rolled back to the manifest-attested state -- fault: {0}; rollback: {1}" -f $fault, ($rollbackNotes -join ''; ''))' + "`n    }`n"
    $catchEnd = $libText.IndexOf($catchEndMarker, $catchStart)
    if ($catchEnd -lt 0) { throw 'REVERSAL ANCHOR NOT FOUND for F2 rollback catch terminator' }
    $libText = $libText.Substring(0, $catchStart) + $oldCatchN + $libText.Substring($catchEnd + $catchEndMarker.Length)
    [System.IO.File]::WriteAllText($OldLib, $libText, (New-Object System.Text.UTF8Encoding($false)))
    $script:Reversals += 1

    # --- F2/F5 reversal in each lifecycle tool.
    foreach ($t in @('session-create.ps1','session-append.ps1','session-close.ps1')) {
        $tp = Join-Path $OldTools $t
        Invoke-Reversal -Path $tp -Label ('F2 fault classification in ' + $t) -From 'Out-IbResult -Object (Add-IbHealedEvidence -Failure (Resolve-IbToolFault -Message $_.Exception.Message) -Healed $healedNotes) -ExitCode 3' `
            -To 'Out-IbResult -Object (New-IbFailure -Code ''E_INTERNAL'' -Message ("tool fault: {0}" -f $_.Exception.Message)) -ExitCode 3'
        Invoke-Reversal -Path $tp -Label ('FIX2-verify pre-try healed declaration in ' + $t) -From @'
$healedNotes = @()

try {
'@ -To @'
try {
'@
        Invoke-Reversal -Path $tp -Label ('F5 healed-on-refusal in ' + $t) -From 'if (-not $integ.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $integ.Failure -Healed $healedNotes) -ExitCode 2 }' `
            -To 'if (-not $integ.Ok) { Out-IbResult -Object $integ.Failure -ExitCode 2 }'
    }
    # session-create's own post-sweep refusal is the one R19 exercises.
    Invoke-Reversal -Path (Join-Path $OldTools 'session-create.ps1') -Label 'F5 session-already-open refusal' `
        -From 'Out-IbResult -Object (Add-IbHealedEvidence -Failure (New-IbFailure -Code ''E_INTERNAL'' -Message ("session already open for {0} (lastSessionId {1}); close it first. No v1 code covers session-state refusal -- E_SESSION_STATE proposed for v2; E_INTERNAL returned per the failure-codes catch-all clause. AUTHORITATIVE state is unchanged; any healing the pre-op sweep performed is listed under healed." -f $OperatorId, $state.lastSessionId)) -Healed $healedNotes) -ExitCode 2' `
        -To 'Out-IbResult -Object (New-IbFailure -Code ''E_INTERNAL'' -Message ("session already open for {0} (lastSessionId {1}); close it first. No v1 code covers session-state refusal -- E_SESSION_STATE proposed for v2; E_INTERNAL returned per the failure-codes catch-all clause. Nothing changed." -f $OperatorId, $state.lastSessionId)) -ExitCode 2'

    # --- F1 reversal 3: the shipped manifests seed lastKnownGood null.
    foreach ($opId in @('op-grok-01','op-fred-01')) {
        $mp = Join-Path $Old ('store\v1\operators\' + $opId + '\manifest.json')
        $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
        $m.lastKnownGood = $null
        [System.IO.File]::WriteAllText($mp, ((ConvertTo-Json $m -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $script:Reversals += 1
    }

    Write-Information ('OLD-TREE BUILT at {0}; {1} reversals applied' -f $Old, $script:Reversals) -InformationAction Continue
    Add-Check -Id 'OB01' -Desc 'pre-FIX2 tree reconstructed (all reversal anchors found)' -Expected '16' -Actual ([string]$script:Reversals)

    $oCreate = Join-Path $OldTools 'session-create.ps1'
    $oAppend = Join-Path $OldTools 'session-append.ps1'
    $oClose  = Join-Path $OldTools 'session-close.ps1'
    $OldSeed = Join-Path $Old 'store\v1'

    function New-OldStore {
        # The per-check stores MUST live inside the reconstructed repo
        # root: the old tools resolve their repo root from their own
        # $PSScriptRoot and refuse (E_NOT_HOST, correctly) any store root
        # outside that tree. A sibling directory would make every old-fail
        # check measure containment instead of the defect under test.
        param([string]$Name)
        $s = Join-Path (Join-Path $Old '_stores') $Name
        New-Item -ItemType Directory -Force $s | Out-Null
        Copy-Item -Path (Join-Path $OldSeed '*') -Destination $s -Recurse
        return $s
    }

    # ============ O15: F1 first-generation crash residue ============
    # OLD BEHAVIOUR (the defect): the unattested new state is silently
    # accepted as integral and the operator is wedged open on a session
    # nobody holds.
    $o15store = New-OldStore -Name 'o15-store'
    $o15op = Join-Path $o15store 'operators\op-grok-01'
    $o15old = Get-Content (Join-Path $o15op 'state.json') -Raw | ConvertFrom-Json
    $o15text = ((ConvertTo-Json ([ordered]@{
        schemaVersion = 1; operatorId = 'op-grok-01'; lifecycle = 'open'
        stateVersion = ([long]$o15old.stateVersion + 1)
        lastSessionId = 'sess-crash-window-probe'; updatedUtc = '2026-08-22T09:20:00Z'
    }) -Depth 4) + "`n")
    [System.IO.File]::WriteAllText((Join-Path $o15op 'state.json.new'), $o15text, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Replace((Join-Path $o15op 'state.json.new'), (Join-Path $o15op 'state.json'), (Join-Path $o15op 'state.json.lkg'))
    Copy-Item (Join-Path $o15op 'manifest.json') (Join-Path $o15op 'manifest.json.new') -Force
    $o15mBefore = (Get-FileHash (Join-Path $o15op 'manifest.json')).Hash
    $o15 = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o15store }
    $o15state = 'no-result'
    if ($null -ne $o15.Json) {
        if ($o15.Exit -eq 0 -and $o15.Json.ok) { $o15state = 'ok' } else { $o15state = ('refused:' + [string]$o15.Json.code) }
    }
    Add-Check -Id 'O15a' -Desc 'OLD F1: crash residue wedges the operator open (reviewer measured E_INTERNAL)' -Expected 'refused:E_INTERNAL' -Actual $o15state
    $o15live = Get-Content (Join-Path $o15op 'state.json') -Raw | ConvertFrom-Json
    Add-Check -Id 'O15b' -Desc 'OLD F1: the UNATTESTED crash generation survived the sweep (never rolled back)' -Expected 'True' -Actual ([string]($o15live.lastSessionId -ceq 'sess-crash-window-probe'))
    Add-Check -Id 'O15c' -Desc 'OLD F1: manifest byte-identical, still attesting nothing' -Expected 'True' -Actual ([string]($o15mBefore -ceq (Get-FileHash (Join-Path $o15op 'manifest.json')).Hash))

    # ============ O16: F1 null baseline silently accepted =============
    $o16store = New-OldStore -Name 'o16-store'
    $o16 = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o16store }
    $o16state = 'refused'
    if ($o16.Exit -eq 0 -and $null -ne $o16.Json -and $o16.Json.ok) { $o16state = 'ok' }
    Add-Check -Id 'O16' -Desc 'OLD F1: a manifest attesting NOTHING was accepted as integral (no freeze)' -Expected 'ok' -Actual $o16state

    # O16b -- the counterpart to R16b. The reversed seed has lastKnownGood
    # null, so R16b's exact construction (removing one entry) has nothing
    # to remove; the faithful old-tree equivalent is a manifest carrying a
    # PARTIAL baseline. No guard existed on the old code, so it was
    # accepted just the same.
    $o16bstore = New-OldStore -Name 'o16b-store'
    $o16bop = Join-Path $o16bstore 'operators\op-grok-01'
    $o16bm = Get-Content (Join-Path $o16bop 'manifest.json') -Raw | ConvertFrom-Json
    $o16bm.lastKnownGood = [ordered]@{
        'profile.json' = [ordered]@{
            sha256 = (Get-FileHash -LiteralPath (Join-Path $o16bop 'profile.json') -Algorithm SHA256).Hash
            bytes  = (Get-Item -LiteralPath (Join-Path $o16bop 'profile.json')).Length
            updatedUtc = '2026-08-22T09:15:00Z'
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $o16bop 'manifest.json'), ((ConvertTo-Json $o16bm -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $o16b = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o16bstore }
    $o16bstate = 'refused'
    if ($o16b.Exit -eq 0 -and $null -ne $o16b.Json -and $o16b.Json.ok) { $o16bstate = 'ok' }
    Add-Check -Id 'O16b' -Desc 'OLD F1: an INCOMPLETE baseline (state.json unattested) was accepted too' -Expected 'ok' -Actual $o16bstate

    # ============ O17: F2 dishonest rollback claim ====================
    # OLD BEHAVIOUR: the rollback restoration genuinely fails, and the tool
    # STILL reports E_INTERNAL plus "was rolled back to the
    # manifest-attested state" -- in the same string that records the
    # failure.
    $o17store = New-OldStore -Name 'o17-store'
    $o17op = Join-Path $o17store 'operators\op-grok-01'
    $o17c = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o17store }
    $o17sid = $o17c.Json.sessionId
    $null = Invoke-Tool -ScriptPath $oAppend -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $o17sid; Outcome = 'completed'; Notes = 'o17'; StoreRoot = $o17store }
    $o17sum = Join-Path $o17op 'summary-current.json'
    $o17me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $o17deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $o17me,
        ([System.Security.AccessControl.FileSystemRights]::WriteData -bor [System.Security.AccessControl.FileSystemRights]::AppendData),
        [System.Security.AccessControl.AccessControlType]::Deny)
    $o17 = $null
    try {
        $o17acl = Get-Acl -LiteralPath $o17sum; $o17acl.AddAccessRule($o17deny); Set-Acl -LiteralPath $o17sum -AclObject $o17acl
        $o17mh = [System.IO.File]::Open((Join-Path $o17op 'manifest.json'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try { $o17 = Invoke-Tool -ScriptPath $oClose -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $o17sid; StoreRoot = $o17store } }
        finally { $o17mh.Close(); $o17mh.Dispose() }
    } finally {
        $o17aclR = Get-Acl -LiteralPath $o17sum; [void]$o17aclR.RemoveAccessRule($o17deny); Set-Acl -LiteralPath $o17sum -AclObject $o17aclR
    }
    $o17code = ''; $o17msg = ''
    if ($null -ne $o17 -and $null -ne $o17.Json) { $o17code = [string]$o17.Json.code; $o17msg = [string]$o17.Json.message }
    Add-Check -Id 'O17a' -Desc 'OLD F2: an unrestored rollback was reported as E_INTERNAL (authoritative state unchanged)' -Expected 'E_INTERNAL' -Actual $o17code
    Add-Check -Id 'O17b' -Desc 'OLD F2: the throw claimed a full rollback WHILE recording that the restoration failed' -Expected 'claimed=True;butFailed=True' -Actual ('claimed={0};butFailed={1}' -f $o17msg.Contains('was rolled back to the manifest-attested state'), $o17msg.Contains('itself failed'))

    # ============ O18: F3 caller metadata trusted =====================
    $o18store = New-OldStore -Name 'o18-store'
    $o18op = Join-Path $o18store 'operators\op-grok-01'
    $o18c = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o18store }
    $null = Invoke-Tool -ScriptPath $oAppend -Arguments @{ OperatorId = 'op-grok-01'; SessionId = $o18c.Json.sessionId; Outcome = 'completed'; Notes = 'o18'; StoreRoot = $o18store }
    $o18ep = @(Get-ChildItem (Join-Path $o18op 'episodes\*.json'))[0].Name
    $o18before = (Get-FileHash -LiteralPath (Join-Path $o18op ('episodes\' + $o18ep)) -Algorithm SHA256).Hash
    # dot-source the OLD lib in a child scope so the fixed lib already
    # loaded in this session cannot mask it
    $o18state = 'refused'
    $o18sb = {
        param($LibPath, $OpDir, $EpRel)
        . $LibPath
        Invoke-IbStoreCommit -OperatorDir $OpDir -MaxTotalBytes 4194304 -Writes @(
            @{ Rel = $EpRel; AppendOnly = $false; Document = [ordered]@{
                schemaVersion = 1; operatorId = 'op-grok-01'; sessionId = 'overwrite-attempt'
                startedUtc = '1999-01-01T00:00:00Z'; endedUtc = '1999-01-01T00:00:00Z'
                outcome = 'failed'; notes = 'store-layer append-only probe' } }
        )
    }
    # Assert the commit's OWN Ok flag, not merely "no exception thrown":
    # Invoke-IbStoreCommit RETURNS a failure object (without throwing) for
    # E_LIMIT, a shape freeze, and an unreadable manifest, so treating
    # "no exception" as proof of an overwrite would record OVERWROTE --
    # a false PASS -- for a commit that never touched the episode.
    try {
        $o18res = & $o18sb $OldLib $o18op ('episodes\' + $o18ep)
        if ($null -ne $o18res -and $o18res.Ok) { $o18state = 'OVERWROTE' }
        else { $o18state = ('returned-failure:' + [string]$o18res.Failure.code) }
    } catch { $o18state = 'refused' }
    $o18after = (Get-FileHash -LiteralPath (Join-Path $o18op ('episodes\' + $o18ep)) -Algorithm SHA256).Hash
    Add-Check -Id 'O18a' -Desc 'OLD F3: the store trusted AppendOnly=$false and overwrote a committed episode' -Expected 'OVERWROTE' -Actual $o18state
    Add-Check -Id 'O18b' -Desc 'OLD F3: the committed episode bytes actually changed' -Expected 'CHANGED' -Actual $(if ($o18before -ceq $o18after) { 'BYTE-IDENTICAL' } else { 'CHANGED' })

    # ============ O19: F5 healing invisible on refusal ================
    $o19store = New-OldStore -Name 'o19-store'
    $o19op = Join-Path $o19store 'operators\op-grok-01'
    $null = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o19store }
    [System.IO.File]::WriteAllText((Join-Path $o19op 'state.json.new'), '{}', (New-Object System.Text.UTF8Encoding($false)))
    $o19 = Invoke-Tool -ScriptPath $oCreate -Arguments @{ OperatorId = 'op-grok-01'; StoreRoot = $o19store }
    $o19heal = 'absent'
    if ($null -ne $o19.Json -and (@($o19.Json.PSObject.Properties.Name) -ccontains 'healed')) { $o19heal = 'reported' }
    Add-Check -Id 'O19a' -Desc 'OLD F5: the refusal carried NO healed evidence' -Expected 'absent' -Actual $o19heal
    Add-Check -Id 'O19b' -Desc 'OLD F5: yet the sweep had already deleted the staging residue before refusing' -Expected 'True' -Actual ([string](-not (Test-Path (Join-Path $o19op 'state.json.new'))))
    $o19msg = ''; if ($null -ne $o19.Json) { $o19msg = [string]$o19.Json.message }
    Add-Check -Id 'O19c' -Desc 'OLD F5: and the refusal text still said "Nothing changed."' -Expected 'True' -Actual ([string]$o19msg.Contains('Nothing changed.'))

    # ============ negative control ====================================
    $seedAfter = Get-TreeFingerprint -Root (Join-Path $RepoRoot 'store\v1')
    $identity = 'CHANGED'; if ($seedBefore -ceq $seedAfter) { $identity = 'BYTE-IDENTICAL' }
    Add-Check -Id 'ON01' -Desc 'seed store\v1 untouched by the old-fail run' -Expected 'BYTE-IDENTICAL' -Actual $identity

    # ---------------- Results -----------------------------------------
    $passCount = @($Checks | Where-Object { $_.pass }).Count
    $total = $Checks.Count
    $report = [ordered]@{
        harness   = 'test\run-fix2-oldfail.ps1'
        purpose   = 'law 1847 old-fail half for the FIX2 regressions R15/R16/R17/R18/R19'
        runId     = $RunId
        repoRoot  = $RepoRoot
        launches  = 'NONE -- file-level only, in-process invocations'
        reversals = $script:Reversals
        passed    = $passCount
        total     = $total
        allPass   = ($passCount -eq $total)
        checks    = @($Checks)
    }
    $jsonPath = Join-Path $Results ('fix2-oldfail-' + $RunId + '.json')
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-Json $report -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    Write-Information ('RESULT {0}/{1} old-fail checks behaved defectively as expected; report {2}' -f $passCount, $total, $jsonPath) -InformationAction Continue
    ConvertTo-Json -InputObject ([ordered]@{ ok = ($passCount -eq $total); passed = $passCount; total = $total; report = $jsonPath })

    if ($passCount -eq $total) { exit 0 } else { exit 2 }
} catch {
    ConvertTo-Json -InputObject ([ordered]@{ ok = $false; harnessFault = $_.Exception.Message; at = $_.ScriptStackTrace })
    exit 3
}
