<#
session-append.ps1 -- appends one episode document to the OPEN session of
a configured operator. Episodes are append-only: an episode file is never
rewritten. The episode, the state bump, and the manifest land through ONE
staged store transaction (manifest last -- FIX1 F2), and the total-byte
limit is judged against the projected post-commit footprint including
.lkg bookkeeping and the manifest (FIX1 F3; E_LIMIT, never silent
truncation).

Episode naming per store\v1\SCHEMA.md: episodes\<utc-compact>-<seq>.json,
where <seq> is 1 + the count of existing episodes carrying this sessionId.

-ConfigPath: harness-only override for limits, containment-guarded to
the repository tree.

EXIT: 0 appended; 2 refused (JSON result carries the failure code);
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
    [Parameter(Mandatory = $true)][ValidateSet('completed','stopped','failed')][string]$Outcome,
    [string]$Notes = '',
    [string]$StartedUtc = '',
    [string]$EndedUtc = '',
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

    # FIX1 F4: the same strict RFC 3339 lexical space the validator
    # enforces -- an offset is REQUIRED.
    foreach ($tf in @(@('StartedUtc', $StartedUtc), @('EndedUtc', $EndedUtc))) {
        if ($tf[1] -ne '') {
            if (-not (Test-IbRfc3339DateTime -Value $tf[1])) {
                Out-IbResult -Object (New-IbFailure -Code 'E_MALFORMED' -Message ("{0} is not an RFC 3339 date-time with a required offset (Z or +/-hh:mm): {1}" -f $tf[0], $tf[1])) -ExitCode 2
            }
        }
    }
    $started = $StartedUtc; if ($started -eq '') { $started = Get-IbUtcNow }
    $ended   = $EndedUtc;   if ($ended   -eq '') { $ended   = Get-IbUtcNow }

    foreach ($ch in $Notes.ToCharArray()) {
        if ([int]$ch -gt 126) {
            Out-IbResult -Object (New-IbFailure -Code 'E_BOUNDS' -Message 'Notes refused: non-ASCII character (ASCII discipline for authored store text)') -ExitCode 2
        }
    }

    # Sequence number: 1 + count of episodes already carrying this session.
    $seq = 1
    foreach ($ep in @(Get-IbEpisodeFiles -OperatorDir $opDir)) {
        $er = Read-IbStoreDoc -OperatorDir $opDir -RelPath ('episodes\' + $ep.Name)
        if (-not $er.Ok) { Out-IbResult -Object $er.Failure -ExitCode 2 }
        if ($er.Doc.sessionId -ceq $SessionId) { $seq += 1 }
    }

    $episode = [ordered]@{
        schemaVersion = 1
        operatorId    = $OperatorId
        sessionId     = $SessionId
        startedUtc    = $started
        endedUtc      = $ended
        outcome       = $Outcome
        notes         = $Notes
    }
    $episodeText  = ConvertTo-IbJsonText -Value $episode -Depth 4
    $episodeBytes = [System.Text.Encoding]::UTF8.GetByteCount($episodeText)

    if ($episodeBytes -gt [long]$limits.maxEpisodeBytes) {
        Out-IbResult -Object (New-IbFailure -Code 'E_LIMIT' -Message ("episode document {0} B exceeds maxEpisodeBytes {1}; never silently truncated" -f $episodeBytes, $limits.maxEpisodeBytes)) -ExitCode 2
    }
    $usage = Get-IbStoreUsage -OperatorDir $opDir
    if (($usage.EpisodeCount + 1) -gt [long]$limits.maxEpisodesPerOperator) {
        Out-IbResult -Object (New-IbFailure -Code 'E_LIMIT' -Message ("episode count {0} at maxEpisodesPerOperator {1}" -f $usage.EpisodeCount, $limits.maxEpisodesPerOperator)) -ExitCode 2
    }
    # The total-byte gate rides INSIDE the store transaction (FIX1 F3):
    # it judges the full projected post-commit footprint, not just the
    # episode bytes.

    $epRel = 'episodes\' + (Get-IbUtcCompact) + '-' + $seq + '.json'
    if (Test-Path -LiteralPath (Join-Path $opDir $epRel) -PathType Leaf) {
        Out-IbResult -Object (New-IbFailure -Code 'E_INTERNAL' -Message ("episode file already exists (append-only law): {0}" -f $epRel)) -ExitCode 2
    }

    $newState = [ordered]@{
        schemaVersion = 1
        operatorId    = $OperatorId
        lifecycle     = 'open'
        stateVersion  = ([long]$state.stateVersion + 1)
        lastSessionId = $SessionId
        updatedUtc    = (Get-IbUtcNow)
    }

    $commit = Invoke-IbStoreCommit -OperatorDir $opDir -Writes @(
        @{ Rel = $epRel;       Document = $episode;  AppendOnly = $true },
        @{ Rel = 'state.json'; Document = $newState; AppendOnly = $false }
    ) -MaxTotalBytes ([long]$limits.maxTotalBytesPerOperator)
    if (-not $commit.Ok) { Out-IbResult -Object (Add-IbHealedEvidence -Failure $commit.Failure -Healed $healedNotes) -ExitCode 2 }

    Out-IbResult -Object ([ordered]@{
        ok           = $true
        action       = 'session-append'
        operatorId   = $OperatorId
        sessionId    = $SessionId
        episodeFile  = $epRel
        seq          = $seq
        stateVersion = $newState.stateVersion
        episodePin   = $commit.Pins[$epRel]
        statePin     = $commit.Pins['state.json']
        manifestPin  = $commit.ManifestPin
        healed       = $healedNotes
    }) -ExitCode 0
} catch {
    # FIX2 F2: a rollback that did not fully restore is reported as
    # E_STORE_CORRUPT (recovery required), not as E_INTERNAL.
    Out-IbResult -Object (Add-IbHealedEvidence -Failure (Resolve-IbToolFault -Message $_.Exception.Message) -Healed $healedNotes) -ExitCode 3
}
