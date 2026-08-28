<#
session-close.ps1 -- closes the OPEN session of a configured operator:
sets state lifecycle=closed and refreshes summary-current.json (rolling
summary; empty-safe). Both documents and the manifest land through ONE
staged store transaction (manifest last -- FIX1 F2), gated by the
projected post-commit total-byte limit (FIX1 F3).

-ConfigPath: harness-only override for limits, containment-guarded to
the repository tree.

EXIT: 0 closed; 2 refused (JSON result carries the failure code);
3 tool fault. READ THE CODE, NOT THE EXIT (FIX2-verify): exit 3 carries
E_INTERNAL when authoritative state is unchanged and any residue heals on
the next sweep -- but it carries E_STORE_CORRUPT when a commit rollback
did NOT fully restore, and that store must be repaired by hand from its
.lkg generations before the next operation. Do not retry on exit 3 alone.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OperatorId,
    [Parameter(Mandatory = $true)][string]$SessionId,
    [string]$Summary = '',
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
# report what the pre-op sweep already healed (see session-create.ps1).
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
    # FIX2 F5: carry any healing the pre-op sweep performed onto every
    # post-sweep result, refusals included.
    if ($integ.ContainsKey('Healed')) { $healedNotes = @($integ.Healed) }
    if (-not $integ.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $integ.Failure -Healed $healedNotes) -ExitCode 2 }

    $stateRes = Read-IbStoreDoc -OperatorDir $opDir -RelPath 'state.json'
    if (-not $stateRes.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $stateRes.Failure -Healed $healedNotes) -ExitCode 2 }
    $state = $stateRes.Doc

    if (($state.lifecycle -cne 'open') -or ($state.lastSessionId -cne $SessionId)) {
        Out-IbResult -Object (Add-IbHealedEvidence -Failure (New-IbFailure -Code 'E_UNKNOWN_SESSION' -Message ("sessionId {0} is not open for {1} (lifecycle={2}, lastSessionId={3}). AUTHORITATIVE state is unchanged; any healing the pre-op sweep performed is listed under healed." -f $SessionId, $OperatorId, $state.lifecycle, $state.lastSessionId)) -Healed $healedNotes) -ExitCode 2
    }

    # Rolling facts from the episodes on disk.
    $totalEpisodes = 0
    $lastOutcome = $null
    $bestSeq = 0
    foreach ($ep in @(Get-IbEpisodeFiles -OperatorDir $opDir)) {
        $er = Read-IbStoreDoc -OperatorDir $opDir -RelPath ('episodes\' + $ep.Name)
        if (-not $er.Ok) { Out-IbResult -Object $er.Failure -ExitCode 2 }
        $totalEpisodes += 1
        if ($er.Doc.sessionId -ceq $SessionId) {
            if ($ep.BaseName -match '-(\d+)$') {
                $s = [int]$Matches[1]
                if ($s -ge $bestSeq) { $bestSeq = $s; $lastOutcome = $er.Doc.outcome }
            }
        }
    }

    if ($Summary -eq '') {
        $Summary = ('session {0} closed with {1} episode(s) on record' -f $SessionId, $totalEpisodes)
    }
    foreach ($ch in $Summary.ToCharArray()) {
        if ([int]$ch -gt 126) {
            Out-IbResult -Object (New-IbFailure -Code 'E_BOUNDS' -Message 'Summary refused: non-ASCII character (ASCII discipline for authored store text)') -ExitCode 2
        }
    }
    if ($Summary.Length -gt 2048) {
        Out-IbResult -Object (New-IbFailure -Code 'E_BOUNDS' -Message ("Summary length {0} exceeds the 2048-char clamp" -f $Summary.Length)) -ExitCode 2
    }

    $newSummary = [ordered]@{
        schemaVersion = 1
        operatorId    = $OperatorId
        episodeCount  = $totalEpisodes
        lastSessionId = $SessionId
        lastOutcome   = $lastOutcome
        summary       = $Summary
        updatedUtc    = (Get-IbUtcNow)
    }
    $newState = [ordered]@{
        schemaVersion = 1
        operatorId    = $OperatorId
        lifecycle     = 'closed'
        stateVersion  = ([long]$state.stateVersion + 1)
        lastSessionId = $SessionId
        updatedUtc    = (Get-IbUtcNow)
    }

    $commit = Invoke-IbStoreCommit -OperatorDir $opDir -Writes @(
        @{ Rel = 'summary-current.json'; Document = $newSummary; AppendOnly = $false },
        @{ Rel = 'state.json';           Document = $newState;   AppendOnly = $false }
    ) -MaxTotalBytes ([long]$limits.maxTotalBytesPerOperator)
    if (-not $commit.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $commit.Failure -Healed $healedNotes) -ExitCode 2 }

    Out-IbResult -Object ([ordered]@{
        ok           = $true
        action       = 'session-close'
        operatorId   = $OperatorId
        sessionId    = $SessionId
        episodeCount = $totalEpisodes
        lastOutcome  = $lastOutcome
        stateVersion = $newState.stateVersion
        summaryPin   = $commit.Pins['summary-current.json']
        statePin     = $commit.Pins['state.json']
        manifestPin  = $commit.ManifestPin
        healed       = $healedNotes
    }) -ExitCode 0
} catch {
    # FIX2 F2: a rollback that did not fully restore is reported as
    # E_STORE_CORRUPT (recovery required), not as E_INTERNAL.
    Out-IbResult -Object (Add-IbHealedEvidence -Failure (Resolve-IbToolFault -Message $_.Exception.Message) -Healed $healedNotes) -ExitCode 3
}
