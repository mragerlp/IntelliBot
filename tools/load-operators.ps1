<#
load-operators.ps1 -- loads and judges the configured operator roster.
READ-ONLY: writes nothing anywhere.

THE ENFORCED LAW (tools\lib\intellibot-operators.ps1): while Gate-0
stands unlifted (boards 2003/2005), spawnPermitted MUST be false in every
operator config. Any operator carrying true refuses the WHOLE load with
E_GATE0_HELD and exit 1 -- tamper evidence, not a preference. The roster
is judged whole; one bad file blocks everything, fail-closed.

-RepoRoot exists so the dry-run harness can point the judgment at a
scratch fixture tree; it defaults to this repository.

EXIT: 0 roster loaded, every operator lawful; 1 REFUSED (E_GATE0_HELD --
kept distinct so a tamper reads differently from an ordinary refusal);
2 refused for any other reason; 3 tool error.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\intellibot-operators.ps1')

function Out-IbResult {
    param($Object, [int]$ExitCode)
    ConvertTo-Json -InputObject $Object -Depth 6
    exit $ExitCode
}

try {
    if ($RepoRoot -eq '') { $RepoRoot = Get-IbRepoRoot }

    $res = Get-IbOperators -RepoRoot $RepoRoot
    if (-not $res.Ok) {
        $code = 2
        if ($res.Failure.code -ceq 'E_GATE0_HELD') { $code = 1 }
        Out-IbResult -Object $res.Failure -ExitCode $code
    }

    $roster = New-Object System.Collections.ArrayList
    foreach ($op in $res.Operators) {
        [void]$roster.Add([ordered]@{
            operatorId           = $op.operatorId
            displayName          = $op.displayName
            role                 = $op.role
            steamIdFake          = $op.steamIdFake
            storePath            = $op.storePath
            spawnPermitted       = $op.spawnPermitted
            spawnPermittedReason = $op.spawnPermittedReason
        })
    }

    Out-IbResult -Object ([ordered]@{
        ok        = $true
        action    = 'load-operators'
        repoRoot  = $RepoRoot
        count     = $roster.Count
        gate0     = 'UNLIFTED -- spawnPermitted=false enforced across the roster'
        operators = @($roster)
    }) -ExitCode 0
} catch {
    Out-IbResult -Object (New-IbFailure -Code 'E_INTERNAL' -Message ("tool fault: {0}" -f $_.Exception.Message)) -ExitCode 3
}
