<#
session-create.ps1 -- opens one control-plane session for a configured
operator. Writes ONLY under the resolved store root (production posture:
store\v1; containment refuses anything outside this repository tree or
across a reparse point -- FIX1 F1).

Fail-closed at every step:
  1. loads the operator through the full roster judgment (a tampered
     spawnPermitted=true anywhere refuses the load with E_GATE0_HELD)
  2. sweeps store integrity -- healing non-authoritative residue first
     (FIX1 F2), then freezing on real corruption or future schemas
  3. refuses if a session is already open (no v1 failure code exists for
     a session-state refusal; per contracts\failure-codes.md the
     catch-all E_INTERNAL is returned and a dedicated code is proposed
     for v2 in docs\CONTROL-PLANE-TOOLS.md)
  4. mints a sessionId and commits the state change through the staged
     store transaction (manifest last; total-byte gate uniform -- FIX1
     F2/F3)

NOTE: this opens a SESSION RECORD. It spawns nothing, launches nothing,
and cannot: operator.spawn remains barred by Gate-0 (E_GATE0_HELD) and no
runtime exists in this tree.

-ConfigPath: harness-only override for limits, containment-guarded to
the repository tree.

EXIT: 0 created; 2 refused (JSON result carries the failure code);
3 tool fault. READ THE CODE, NOT THE EXIT (FIX2-verify): exit 3 carries
E_INTERNAL when authoritative state is unchanged and any residue heals on
the next sweep -- but it carries E_STORE_CORRUPT when a commit rollback
did NOT fully restore, and that store must be repaired by hand from its
.lkg generations before the next operation. Do not retry on exit 3 alone.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OperatorId,
    [string]$StoreRoot = '',
    [string]$ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\intellibot-store.ps1')
. (Join-Path $PSScriptRoot 'lib\intellibot-operators.ps1')

$script:IbLock = $null
function Out-IbResult {
    param($Object, [int]$ExitCode)
    if ($null -ne $script:IbLock) { Exit-IbStoreLock -Lock $script:IbLock; $script:IbLock = $null }
    ConvertTo-Json -InputObject $Object -Depth 6
    exit $ExitCode
}

# FIX2-verify: declared OUTSIDE the try so the exit-3 fault path can also
# report what the pre-op sweep already healed. That path is precisely
# where it matters most: a FIX2 F2 "rollback did not fully restore" fault
# tells the operator to repair by hand from .lkg, and they need to know
# which files the sweep already renamed or deleted first.
$healedNotes = @()

try {
    $RepoRoot = Get-IbRepoRoot

    if ($ConfigPath -ne '') {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf) -or -not (Test-IbPathInside -Root $RepoRoot -Candidate $ConfigPath)) {
            Out-IbResult -Object (New-IbFailure -Code 'E_NOT_HOST' -Message ("config override {0} is absent, outside the repository tree, or across a reparse point; refused" -f $ConfigPath)) -ExitCode 2
        }
    }

    $opRes = Get-IbOperatorById -OperatorId $OperatorId -RepoRoot $RepoRoot -ConfigPath $ConfigPath
    if (-not $opRes.Ok) { Out-IbResult -Object $opRes.Failure -ExitCode 2 }
    $limits = $opRes.Config.store.limits

    $rootRes = Resolve-IbStoreRoot -RepoRoot $RepoRoot -StoreRoot $StoreRoot
    if (-not $rootRes.Ok) { Out-IbResult -Object $rootRes.Failure -ExitCode 2 }

    $dirRes = Get-IbOperatorDir -StoreRoot $rootRes.Root -OperatorId $OperatorId
    if (-not $dirRes.Ok) { Out-IbResult -Object $dirRes.Failure -ExitCode 2 }
    $opDir = $dirRes.Dir

    $lockRes = Enter-IbStoreLock -OperatorDir $opDir
    if (-not $lockRes.Ok) { Out-IbResult -Object $lockRes.Failure -ExitCode 2 }
    $script:IbLock = $lockRes

    $integ = Test-IbStoreIntegrity -OperatorDir $opDir
    # FIX2 F5: the sweep may already have healed residue before a later,
    # unrelated refusal. Carry that evidence onto every post-sweep result,
    # refusals included, instead of only onto the success result.
    # ($healedNotes is declared above the try so the exit-3 catch can
    # report it too -- FIX2-verify.)
    if ($integ.ContainsKey('Healed')) { $healedNotes = @($integ.Healed) }
    if (-not $integ.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $integ.Failure -Healed $healedNotes) -ExitCode 2 }

    $stateRes = Read-IbStoreDoc -OperatorDir $opDir -RelPath 'state.json'
    if (-not $stateRes.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $stateRes.Failure -Healed $healedNotes) -ExitCode 2 }
    $state = $stateRes.Doc

    if ($state.lifecycle -ceq 'open') {
        Out-IbResult -Object (Add-IbHealedEvidence -Failure (New-IbFailure -Code 'E_INTERNAL' -Message ("session already open for {0} (lastSessionId {1}); close it first. No v1 code covers session-state refusal -- E_SESSION_STATE proposed for v2; E_INTERNAL returned per the failure-codes catch-all clause. AUTHORITATIVE state is unchanged; any healing the pre-op sweep performed is listed under healed." -f $OperatorId, $state.lastSessionId)) -Healed $healedNotes) -ExitCode 2
    }

    $sessionId = 'sess-' + (Get-IbUtcCompact) + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))

    $newState = [ordered]@{
        schemaVersion = 1
        operatorId    = $OperatorId
        lifecycle     = 'open'
        stateVersion  = ([long]$state.stateVersion + 1)
        lastSessionId = $sessionId
        updatedUtc    = (Get-IbUtcNow)
    }

    $commit = Invoke-IbStoreCommit -OperatorDir $opDir -Writes @(
        @{ Rel = 'state.json'; Document = $newState; AppendOnly = $false }
    ) -MaxTotalBytes ([long]$limits.maxTotalBytesPerOperator)
    if (-not $commit.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $commit.Failure -Healed $healedNotes) -ExitCode 2 }

    Out-IbResult -Object ([ordered]@{
        ok           = $true
        action       = 'session-create'
        operatorId   = $OperatorId
        sessionId    = $sessionId
        stateVersion = $newState.stateVersion
        storeRoot    = $rootRes.Root
        statePin     = $commit.Pins['state.json']
        manifestPin  = $commit.ManifestPin
        healed       = $healedNotes
    }) -ExitCode 0
} catch {
    # FIX2 F2: a rollback that did not fully restore is reported as
    # E_STORE_CORRUPT (recovery required), not as E_INTERNAL (which the
    # contract defines as authoritative state unchanged).
    Out-IbResult -Object (Add-IbHealedEvidence -Failure (Resolve-IbToolFault -Message $_.Exception.Message) -Healed $healedNotes) -ExitCode 3
}
