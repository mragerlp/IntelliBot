# intellibot-operators.ps1 -- operator-config reading and validation,
# shared by tools\load-operators.ps1 and the session lifecycle scripts.
# Windows PowerShell 5.1, zero dependencies. READ-ONLY: defines functions
# that read and judge; nothing here writes.
#
# THE ENFORCED LAW: while Gate-0 stands unlifted (boards 2003/2005),
# spawnPermitted MUST be false in every operator config. A config carrying
# true is treated as TAMPER EVIDENCE and refused with E_GATE0_HELD. This
# module is where that enforcement lives; every consumer inherits it.

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'intellibot-common.ps1')

$IbOperatorRequired = @('schemaVersion','operatorId','displayName','seat','role',
                        'steamIdFake','steamIdNote','adapter','storePath','bars',
                        'spawnPermitted','spawnPermittedReason')
$IbBarTokens = @('ORD 2001.1','ORD 2001.2','ORD 2001.3','GATE-0')

function Test-IbOperatorConfig {
    # Judges one parsed operator config. Returns:
    #   @{ Ok = $true;  Operator = <obj> }
    #   @{ Ok = $false; Failure = <failure>; }  -- first fault wins,
    #     fail-closed; E_GATE0_HELD dominates every other fault.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    if (-not (Test-IbJsonObject $Config)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: top level is not a JSON object" -f $SourcePath)) }
    }
    $names = Get-IbPropertyNames -Object $Config

    # Gate-0 first: even a malformed config that manages to carry
    # spawnPermitted=true is reported as the Gate-0 refusal, because that
    # is the fault an auditor must see first.
    if (($names -ccontains 'spawnPermitted') -and ($Config.spawnPermitted -eq $true)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_GATE0_HELD' -Message ("{0}: spawnPermitted=true while Gate-0 stands unlifted (boards 2003/2005). Tamper evidence; operator REFUSED." -f $SourcePath)) }
    }

    foreach ($r in $IbOperatorRequired) {
        if (-not ($names -ccontains $r)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: missing required field {1}" -f $SourcePath, $r)) }
        }
    }
    if (-not (Test-IbJsonInteger $Config.schemaVersion)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: schemaVersion not an integer" -f $SourcePath)) }
    }
    if ([long]$Config.schemaVersion -gt 1) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_SCHEMA_FUTURE' -Message ("{0}: schemaVersion {1} newer than this build" -f $SourcePath, $Config.schemaVersion)) }
    }
    if (-not ($Config.operatorId -is [string]) -or -not ($Config.operatorId -cmatch '^[a-z0-9][a-z0-9-]{0,63}$')) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: operatorId fails the identifier pattern" -f $SourcePath)) }
    }
    if (-not ($Config.steamIdFake -is [string]) -or -not ($Config.steamIdFake -cmatch '^7650\d{13}$')) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: steamIdFake must be a string in the non-real 7650... range" -f $SourcePath)) }
    }
    if (-not ($Config.spawnPermitted -is [bool])) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: spawnPermitted must be a JSON boolean" -f $SourcePath)) }
    }
    # spawnPermitted is known false here (true was refused above).
    $barsText = @($Config.bars) -join ' | '
    foreach ($tok in $IbBarTokens) {
        if (-not $barsText.Contains($tok)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: standing bar token absent from bars[]: {1}" -f $SourcePath, $tok)) }
        }
    }
    return @{ Ok = $true; Operator = $Config }
}

function Get-IbOperators {
    # Loads every operator named by config\intellibot.local.json.
    # Fail-closed: the FIRST refused operator refuses the whole load.
    param(
        [string]$RepoRoot = (Get-IbRepoRoot),
        [string]$ConfigPath = ''
    )

    $cfg = Get-IbConfig -RepoRoot $RepoRoot -ConfigPath $ConfigPath
    $cfgNames = Get-IbPropertyNames -Object $cfg
    if (-not ($cfgNames -ccontains 'operators')) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message 'config\intellibot.local.json: operators[] absent') }
    }
    $loaded = New-Object System.Collections.ArrayList
    foreach ($relPath in @($cfg.operators)) {
        $p = Join-Path $RepoRoot ($relPath -replace '/', '\')
        # AMEND R-3: operators[] is the one caller-supplied path in the
        # tree that reached a read without a containment guard. Reading is
        # not a privilege escalation, but every other path in these tools
        # is guarded and this one was not -- symmetry, fail-closed, and it
        # inherits the reparse rejection for free.
        if (-not (Test-IbPathInside -Root $RepoRoot -Candidate $p)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_NOT_HOST' -Message ("operator config path escapes the repository tree or crosses a reparse point: {0} (from operators[] entry '{1}'); containment refused" -f $p, $relPath)) }
        }
        $read = Read-IbJsonStrict -Path $p
        if (-not $read.Ok) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_MALFORMED' -Message ("{0}: {1}" -f $p, $read.Error)) }
        }
        $judged = Test-IbOperatorConfig -Config $read.Value -SourcePath $p
        if (-not $judged.Ok) { return @{ Ok = $false; Failure = $judged.Failure } }
        [void]$loaded.Add($judged.Operator)
    }
    return @{ Ok = $true; Operators = @($loaded); Config = $cfg }
}

function Get-IbOperatorById {
    # Resolves one operator through the full fail-closed load, so a
    # tampered SIBLING config also blocks work: while Gate-0 stands, the
    # roster is judged whole, never one file in isolation.
    param(
        [Parameter(Mandatory = $true)][string]$OperatorId,
        [string]$RepoRoot = (Get-IbRepoRoot),
        [string]$ConfigPath = ''
    )
    $all = Get-IbOperators -RepoRoot $RepoRoot -ConfigPath $ConfigPath
    if (-not $all.Ok) { return $all }
    foreach ($op in $all.Operators) {
        if ($op.operatorId -ceq $OperatorId) {
            return @{ Ok = $true; Operator = $op; Config = $all.Config }
        }
    }
    return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_BOUNDS' -Message ("operatorId not in the configured roster: {0}" -f $OperatorId)) }
}
