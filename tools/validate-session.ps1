<#
validate-session.ps1 -- FILE-LEVEL validator for IntelliBot session action
envelopes against contracts\session-v1.schema.json (v1 tool surface).

Windows PowerShell 5.1, zero external dependencies. READ-ONLY: this tool
writes nothing anywhere. It parses envelope JSON files and reports, per
file, a verdict plus failure codes from contracts\failure-codes.md.

DRIFT SENSOR: the checks below are hand-mirrored from one exact revision
of the schema. The pin of that revision is embedded here, and the live
schema file is re-hashed on every run. If the schema has moved, this tool
REFUSES TO JUDGE (exit 3) rather than judge against a stale mirror.

STATIC SCOPE: a file-level validator can judge structure, types, bounds,
enums, and wall-clock expiry. It CANNOT judge session state. These codes
are out of scope here and are enforced by the session host at runtime:
E_DUPLICATE_REQUEST, E_STALE_SEQ, E_UNKNOWN_SESSION, E_WRONG_STATE_VERSION,
E_NOT_HOST, E_GATE0_HELD, E_STORE_CORRUPT, E_SCHEMA_FUTURE, E_LIMIT.

CODE MAPPING (documented in docs\CONTROL-PLANE-TOOLS.md):
  structural fault (unknown/missing field, wrong type, top-level not an
    object, unparseable JSON, bad date-time format) ......... E_MALFORMED
  protocolVersion an integer but not 1 ............... E_PROTOCOL_VERSION
  action a string but outside the v1 enum ............. E_ACTION_EXCLUDED
  args value outside its clamp (moveTarget, lookYawPitch,
    memoryKey pattern, memoryValue size, operatorId enum) ...... E_BOUNDS
  expiresUtc parseable but in the past (static, vs now UTC) ... E_EXPIRED
Primary code precedence when several apply:
  E_MALFORMED > E_PROTOCOL_VERSION > E_ACTION_EXCLUDED > E_BOUNDS > E_EXPIRED

EXIT CODES: 0 = every input valid; 2 = at least one input invalid;
3 = tool error (schema drift, no readable input, internal fault).

USAGE:
  powershell -File tools\validate-session.ps1 -Path <envelope.json> [...]
  Output: one JSON array on stdout (one result object per input file).
  -Quiet suppresses the human-readable summary lines (written to the
  information stream, never to stdout).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\intellibot-common.ps1')

# --- Drift sensor: the schema revision these checks mirror -------------
$ExpectedSchemaBytes  = 4248
$ExpectedSchemaSha256 = '0D1CE3DC5708B740F1D9C8833369A42B091BCDC1DEC473E9508D56D5F654DAB6'

$RepoRoot   = Get-IbRepoRoot
$SchemaPath = Join-Path $RepoRoot 'contracts\session-v1.schema.json'

# Tool-level refusals (drift, unreadable schema) are OUTSIDE the envelope
# failure-code vocabulary; per contracts\failure-codes.md the catch-all is
# E_INTERNAL. They exit 3 and are emitted as JSON on stdout like every
# other result. (Write-Error is deliberately avoided: under this script's
# ErrorActionPreference=Stop it would throw before the exit ran.)
try {
    $schemaPin = Get-IbPin -Path $SchemaPath
} catch {
    ConvertTo-Json -InputObject (New-IbFailure -Code 'E_INTERNAL' -Message ('DRIFT SENSOR: schema unreadable at {0}: {1}' -f $SchemaPath, $_.Exception.Message))
    exit 3
}
if ($schemaPin.Bytes -ne $ExpectedSchemaBytes -or $schemaPin.Sha256 -ne $ExpectedSchemaSha256) {
    ConvertTo-Json -InputObject (New-IbFailure -Code 'E_INTERNAL' -Message ('DRIFT SENSOR: contracts\session-v1.schema.json is {0} B / {1} but this validator mirrors {2} B / {3}. The schema moved; re-author the validator against the new revision. REFUSING TO JUDGE.' -f `
        $schemaPin.Bytes, $schemaPin.Sha256, $ExpectedSchemaBytes, $ExpectedSchemaSha256))
    exit 3
}

# --- Mirrored contract constants ----------------------------------------
$EnvelopeRequired = @('protocolVersion','requestId','sessionId','botHandle','seq','expectedStateVersion','expiresUtc','action')
$EnvelopeAllowed  = $EnvelopeRequired + @('args')
$ActionEnum = @('status','operator.spawn','operator.despawn','operator.stop',
                'move.bounded','look.bounded','memory.list','memory.get',
                'memory.upsert','memory.delete')
$OperatorEnum = @('op-grok-01','op-fred-01')
$ArgsAllowed  = @('operatorId','moveTarget','lookYawPitch','memoryKey','memoryValue')
$MemoryKeyPattern = '^[a-z0-9][a-z0-9._-]{0,127}$'
$MemoryValueMax   = 16384
# Which args field each action reads (advisory layer only -- the schema
# leaves every args field optional; a foreign field is legal and ignored).
$ActionReads = @{
    'status'           = @()
    'operator.spawn'   = @('operatorId')
    'operator.despawn' = @()
    'operator.stop'    = @()
    'move.bounded'     = @('moveTarget')
    'look.bounded'     = @('lookYawPitch')
    'memory.list'      = @()
    'memory.get'       = @('memoryKey')
    'memory.upsert'    = @('memoryKey','memoryValue')
    'memory.delete'    = @('memoryKey')
}
$OutOfScopeNote = 'stateful codes not judged at file level: E_DUPLICATE_REQUEST, E_STALE_SEQ, E_UNKNOWN_SESSION, E_WRONG_STATE_VERSION, E_NOT_HOST, E_GATE0_HELD, E_STORE_CORRUPT, E_SCHEMA_FUTURE, E_LIMIT'

function Test-BoundedString {
    param($Value, [int]$Min, [int]$Max)
    if (-not ($Value -is [string])) { return $false }
    return ($Value.Length -ge $Min -and $Value.Length -le $Max)
}

function Test-OneEnvelope {
    param([string]$FilePath)

    $faults     = New-Object System.Collections.ArrayList
    $advisories = New-Object System.Collections.ArrayList

    function Add-Fault([string]$Code, [string]$Message) {
        [void]$faults.Add((New-Object PSObject -Property @{ code = $Code; message = $Message }))
    }

    $read = Read-IbJsonStrict -Path $FilePath
    if (-not $read.Ok) {
        Add-Fault 'E_MALFORMED' $read.Error
    } else {
        $env = $read.Value
        if (-not (Test-IbJsonObject $env)) {
            Add-Fault 'E_MALFORMED' 'top level is not a JSON object'
        } else {
            $names = Get-IbPropertyNames -Object $env

            foreach ($n in $names) {
                if (-not ($EnvelopeAllowed -ccontains $n)) {
                    Add-Fault 'E_MALFORMED' ('unknown envelope field (case-sensitive): {0}' -f $n)
                }
            }
            foreach ($r in $EnvelopeRequired) {
                if (-not ($names -ccontains $r)) {
                    Add-Fault 'E_MALFORMED' ('missing required field: {0}' -f $r)
                }
            }

            if ($names -ccontains 'protocolVersion') {
                $pv = $env.protocolVersion
                if (-not (Test-IbJsonInteger $pv)) {
                    Add-Fault 'E_MALFORMED' 'protocolVersion is not an integer'
                } elseif ([long]$pv -ne 1) {
                    Add-Fault 'E_PROTOCOL_VERSION' ('protocolVersion {0} not implemented; const 1' -f [long]$pv)
                }
            }

            foreach ($sf in @('requestId','sessionId','botHandle')) {
                if ($names -ccontains $sf) {
                    if (-not (Test-BoundedString $env.$sf 8 64)) {
                        Add-Fault 'E_MALFORMED' ('{0} must be a string of length 8..64' -f $sf)
                    }
                }
            }

            foreach ($nf in @('seq','expectedStateVersion')) {
                if ($names -ccontains $nf) {
                    $v = $env.$nf
                    if (-not (Test-IbJsonInteger $v)) {
                        Add-Fault 'E_MALFORMED' ('{0} is not an integer' -f $nf)
                    } elseif ([long]$v -lt 0) {
                        Add-Fault 'E_MALFORMED' ('{0} minimum is 0' -f $nf)
                    }
                }
            }

            if ($names -ccontains 'expiresUtc') {
                $ex = $env.expiresUtc
                if (-not ($ex -is [string])) {
                    Add-Fault 'E_MALFORMED' 'expiresUtc is not a string'
                } elseif (-not (Test-IbRfc3339DateTime -Value $ex)) {
                    # FIX1 F4: the schema's date-time lexical space (RFC
                    # 3339) REQUIRES an offset; an offset-free value with
                    # local-time semantics is refused, not guessed at.
                    Add-Fault 'E_MALFORMED' ('expiresUtc is not an RFC 3339 date-time with a required offset (Z or +/-hh:mm): {0}' -f $ex)
                } else {
                    $parsed = ConvertTo-IbDateTimeOffset -Value $ex
                    if ($parsed.UtcDateTime -lt [DateTime]::UtcNow) {
                        Add-Fault 'E_EXPIRED' ('expiresUtc {0} is in the past (static judgment vs now UTC)' -f $ex)
                    }
                }
            }

            $actionValue = $null
            if ($names -ccontains 'action') {
                $a = $env.action
                if (-not ($a -is [string])) {
                    Add-Fault 'E_MALFORMED' 'action is not a string'
                } elseif (-not ($ActionEnum -ccontains $a)) {
                    Add-Fault 'E_ACTION_EXCLUDED' ('action outside the v1 surface: {0}' -f $a)
                } else {
                    $actionValue = $a
                }
            }

            if ($names -ccontains 'args') {
                $args_ = $env.args
                if (-not (Test-IbJsonObject $args_)) {
                    Add-Fault 'E_MALFORMED' 'args is not a JSON object'
                } else {
                    $argNames = Get-IbPropertyNames -Object $args_
                    foreach ($an in $argNames) {
                        if (-not ($ArgsAllowed -ccontains $an)) {
                            Add-Fault 'E_MALFORMED' ('unknown args field (case-sensitive): {0}' -f $an)
                        }
                    }

                    if ($argNames -ccontains 'operatorId') {
                        $op = $args_.operatorId
                        if (-not ($op -is [string]) -or -not ($OperatorEnum -ccontains $op)) {
                            Add-Fault 'E_BOUNDS' 'operatorId outside the configured enum (op-grok-01, op-fred-01)'
                        }
                    }

                    if ($argNames -ccontains 'moveTarget') {
                        $mt = $args_.moveTarget
                        if (-not (Test-IbJsonObject $mt)) {
                            Add-Fault 'E_MALFORMED' 'moveTarget is not a JSON object'
                        } else {
                            $mtNames = Get-IbPropertyNames -Object $mt
                            foreach ($k in $mtNames) {
                                if (-not (@('x','y','z') -ccontains $k)) {
                                    Add-Fault 'E_MALFORMED' ('unknown moveTarget field: {0}' -f $k)
                                }
                            }
                            foreach ($k in @('x','y','z')) {
                                if (-not ($mtNames -ccontains $k)) {
                                    Add-Fault 'E_MALFORMED' ('moveTarget missing required field: {0}' -f $k)
                                } elseif (-not (Test-IbJsonNumber $mt.$k)) {
                                    Add-Fault 'E_MALFORMED' ('moveTarget.{0} is not a number' -f $k)
                                } elseif ([double]$mt.$k -lt -50000 -or [double]$mt.$k -gt 50000) {
                                    Add-Fault 'E_BOUNDS' ('moveTarget.{0}={1} outside clamp [-50000, 50000]' -f $k, $mt.$k)
                                }
                            }
                        }
                    }

                    if ($argNames -ccontains 'lookYawPitch') {
                        $lp = $args_.lookYawPitch
                        if (-not (Test-IbJsonObject $lp)) {
                            Add-Fault 'E_MALFORMED' 'lookYawPitch is not a JSON object'
                        } else {
                            $lpNames = Get-IbPropertyNames -Object $lp
                            foreach ($k in $lpNames) {
                                if (-not (@('yaw','pitch') -ccontains $k)) {
                                    Add-Fault 'E_MALFORMED' ('unknown lookYawPitch field: {0}' -f $k)
                                }
                            }
                            $clamps = @{ yaw = @(-180, 180); pitch = @(-89, 89) }
                            foreach ($k in @('yaw','pitch')) {
                                if (-not ($lpNames -ccontains $k)) {
                                    Add-Fault 'E_MALFORMED' ('lookYawPitch missing required field: {0}' -f $k)
                                } elseif (-not (Test-IbJsonNumber $lp.$k)) {
                                    Add-Fault 'E_MALFORMED' ('lookYawPitch.{0} is not a number' -f $k)
                                } elseif ([double]$lp.$k -lt $clamps[$k][0] -or [double]$lp.$k -gt $clamps[$k][1]) {
                                    Add-Fault 'E_BOUNDS' ('lookYawPitch.{0}={1} outside clamp [{2}, {3}]' -f $k, $lp.$k, $clamps[$k][0], $clamps[$k][1])
                                }
                            }
                        }
                    }

                    if ($argNames -ccontains 'memoryKey') {
                        $mk = $args_.memoryKey
                        if (-not ($mk -is [string]) -or -not ($mk -cmatch $MemoryKeyPattern)) {
                            Add-Fault 'E_BOUNDS' 'memoryKey fails the flat-identifier pattern ^[a-z0-9][a-z0-9._-]{0,127}$ (never a file path)'
                        }
                    }

                    if ($argNames -ccontains 'memoryValue') {
                        $mv = $args_.memoryValue
                        if (-not ($mv -is [string])) {
                            Add-Fault 'E_MALFORMED' 'memoryValue is not a string'
                        } elseif ($mv.Length -gt $MemoryValueMax) {
                            Add-Fault 'E_BOUNDS' ('memoryValue length {0} exceeds maxLength {1}' -f $mv.Length, $MemoryValueMax)
                        }
                    }

                    # Advisory layer: schema-legal but operationally inert
                    # or incomplete pairings of action and args.
                    if ($null -ne $actionValue) {
                        $reads = $ActionReads[$actionValue]
                        foreach ($an in $argNames) {
                            if (($ArgsAllowed -ccontains $an) -and -not ($reads -ccontains $an)) {
                                [void]$advisories.Add(('args.{0} is not read by action {1} (legal; ignored by contract)' -f $an, $actionValue))
                            }
                        }
                        foreach ($need in $reads) {
                            if (-not ($argNames -ccontains $need)) {
                                [void]$advisories.Add(('action {0} reads args.{1}, which is absent (schema-legal; host will reject at runtime)' -f $actionValue, $need))
                            }
                        }
                    }
                }
            } elseif ($null -ne $actionValue) {
                $reads = $ActionReads[$actionValue]
                foreach ($need in $reads) {
                    [void]$advisories.Add(('action {0} reads args.{1}, but args is absent (schema-legal; host will reject at runtime)' -f $actionValue, $need))
                }
            }
        }
    }

    # Primary code by documented precedence.
    $codes = @($faults | ForEach-Object { $_.code } | Select-Object -Unique)
    $primary = $null
    foreach ($c in @('E_MALFORMED','E_PROTOCOL_VERSION','E_ACTION_EXCLUDED','E_BOUNDS','E_EXPIRED')) {
        if ($codes -ccontains $c) { $primary = $c; break }
    }

    return New-Object PSObject -Property @{
        file        = $FilePath
        valid       = ($faults.Count -eq 0)
        primaryCode = $primary
        codes       = $codes
        faults      = @($faults)
        advisories  = @($advisories)
        outOfScope  = $OutOfScopeNote
    }
}

# --- Run ---------------------------------------------------------------
$results = New-Object System.Collections.ArrayList
$anyInvalid = $false

foreach ($p in $Path) {
    $r = Test-OneEnvelope -FilePath $p
    [void]$results.Add($r)
    if (-not $r.valid) { $anyInvalid = $true }
    if (-not $Quiet) {
        if ($r.valid) {
            Write-Information ('VALID   {0}' -f $p) -InformationAction Continue
        } else {
            Write-Information ('INVALID {0} [{1}] ({2})' -f $p, $r.primaryCode, (($r.codes) -join ', ')) -InformationAction Continue
        }
    }
}

# Stdout carries exactly one JSON document: the result array.
ConvertTo-Json -InputObject @($results) -Depth 6

if ($anyInvalid) { exit 2 } else { exit 0 }
