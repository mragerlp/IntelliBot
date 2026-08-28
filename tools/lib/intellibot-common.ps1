# intellibot-common.ps1 -- shared helpers for the IntelliBot control-plane
# tools. Windows PowerShell 5.1, zero external dependencies, pure ASCII.
#
# Dot-source this file; it defines functions only and mutates nothing.
# Write surface of every consumer is governed by the repository safety
# contract (docs/SAFETY-CONTRACT.md) and the containment guard below.

Set-StrictMode -Version 2.0

function Get-IbRepoRoot {
    # This file lives at <repo>\tools\lib\intellibot-common.ps1.
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-IbUtcNow {
    return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-IbUtcCompact {
    return [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
}

function Get-IbPin {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
    return New-Object PSObject -Property @{
        Path   = $item.FullName
        Bytes  = [long]$item.Length
        Sha256 = $hash.Hash
    }
}

function Format-IbPin {
    param([Parameter(Mandatory = $true)]$Pin)
    return ('{0} B / {1}' -f $Pin.Bytes, $Pin.Sha256)
}

function Test-IbPathInside {
    # True when Candidate resolves to Root or to a descendant of Root
    # AND no component between Root and Candidate is a reparse point
    # (junction, symlink, mount point). The textual prefix compare alone
    # is defeated by an in-tree junction whose target lies elsewhere
    # (FIX1 finding F1), so any reparse component on the relative chain
    # is REFUSED fail-closed rather than resolved -- rejection cannot be
    # spoofed by an unresolvable or cyclic link. Reparse points at or
    # ABOVE Root are tolerated: a junctioned repository root is lawful
    # topology shared identically by both sides of the compare.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Candidate
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\') + '\'
    if (-not $candFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    # NOTE: this compares TEXTUAL containment plus reparse points on the
    # named chain. It does NOT by itself guard leaf paths a caller builds
    # BELOW the returned directory -- the store layer additionally runs
    # Test-IbStoreShape over the whole operator subtree (FIX1-verify F1).
    $relative = $candFull.Substring($rootFull.Length).TrimEnd('\')
    if ($relative.Length -eq 0) { return $true }
    $walk = $rootFull.TrimEnd('\')
    foreach ($part in $relative.Split('\')) {
        $walk = $walk + '\' + $part
        if (Test-Path -LiteralPath $walk) {
            $item = Get-Item -LiteralPath $walk -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
        }
        # A component that does not exist yet cannot be a reparse point;
        # it will be created as an ordinary directory or file if at all.
    }
    return $true
}

function Test-IbReparsePoint {
    # True iff Path exists AND is a reparse point (junction, symlink,
    # mount point). Reads the attribute only; never follows the link.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-IbRfc3339DateTime {
    # Enforces the JSON Schema "date-time" lexical space (RFC 3339
    # section 5.6): full-date, T/t separator, full-time, and a REQUIRED
    # offset -- Z/z or +/-hh:mm with minute 00-59. XmlConvert alone
    # accepts an offset-free xs:dateTime with local-time semantics (FIX1
    # F4) AND normalizes out-of-range offset minutes (+00:60 -> +01:00,
    # FIX1-verify F4) -- both are barred here: the regex requires the
    # offset and constrains its minute field, and the anchor is \z (not
    # $, which matches before a trailing newline).
    #
    # DOCUMENTED DIVERGENCE (fail-closed, FIX1-verify F4 LOW): three
    # RFC-3339-legal shapes are REFUSED because XmlConvert cannot
    # represent them -- the leap second (time-second = 60), offsets beyond
    # +/-14:00, and year 0000. Rejecting a legal value is the safe
    # direction for an expiry gate (a year-0000 expiry is expired
    # regardless); it is stated here and in docs\CONTROL-PLANE-TOOLS.md
    # rather than papered over.
    param($Value)
    if (-not ($Value -is [string])) { return $false }
    if (-not ($Value -cmatch '^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:[0-5]\d)\z')) {
        return $false
    }
    try {
        [void][System.Xml.XmlConvert]::ToDateTimeOffset($Value.Replace('t', 'T').Replace('z', 'Z'))
        return $true
    } catch {
        return $false
    }
}

function ConvertTo-IbDateTimeOffset {
    # Strict parse companion to Test-IbRfc3339DateTime; call only after
    # it returned true.
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Xml.XmlConvert]::ToDateTimeOffset($Value.Replace('t', 'T').Replace('z', 'Z'))
}

function Read-IbJsonStrict {
    # Strict-as-available JSON read for PS 5.1. ConvertFrom-Json here
    # throws on duplicate keys (case-insensitively compared), which is
    # treated as malformed input -- fail closed. Returns:
    #   @{ Ok = $true;  Value = <parsed> }
    #   @{ Ok = $false; Error = <message> }
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ Ok = $false; Error = ('file not found: {0}' -f $Path) }
    }
    $raw = $null
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
    } catch {
        return @{ Ok = $false; Error = ('unreadable: {0}' -f $_.Exception.Message) }
    }
    if ($null -eq $raw -or $raw.Trim().Length -eq 0) {
        return @{ Ok = $false; Error = 'empty or whitespace-only file' }
    }
    try {
        $value = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        return @{ Ok = $true; Value = $value; Raw = $raw }
    } catch {
        return @{ Ok = $false; Error = ('JSON parse failure: {0}' -f $_.Exception.Message) }
    }
}

function Write-IbTextFile {
    # Writes text as UTF-8 with NO byte-order mark. Refuses non-ASCII
    # content: every byte of this tree's authored text is plain ASCII by
    # increment-2 discipline, so a non-ASCII character is evidence of an
    # upstream fault, not something to smuggle through.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    foreach ($ch in $Content.ToCharArray()) {
        if ([int]$ch -gt 126) {
            throw ('Write-IbTextFile refused: non-ASCII char U+{0:X4} in content for {1}' -f [int]$ch, $Path)
        }
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function ConvertTo-IbJsonText {
    # Canonical-enough JSON serialization for store documents: PS 5.1
    # ConvertTo-Json with bounded depth plus a trailing newline.
    param(
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 8
    )
    return ((ConvertTo-Json -InputObject $Value -Depth $Depth) + "`n")
}

function Test-IbJsonInteger {
    # JSON-schema "integer": any number with an integral value. Strings
    # never qualify.
    param($Value)
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) { return $true }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return ([math]::Floor([double]$Value) -eq [double]$Value)
    }
    return $false
}

function Test-IbJsonNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
            $Value -is [byte] -or $Value -is [double] -or $Value -is [decimal] -or
            $Value -is [single])
}

function Test-IbJsonObject {
    param($Value)
    return ($Value -is [System.Management.Automation.PSCustomObject])
}

function Get-IbPropertyNames {
    # Actual (case-preserved) property names of a parsed JSON object.
    param([Parameter(Mandatory = $true)]$Object)
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-IbConfig {
    # Loads config\intellibot.local.json and returns the parsed object.
    # Throws on parse failure -- a broken config is a stop, not a default.
    # ConfigPath override exists solely for the dry-run harness (small
    # scratch limits); callers containment-guard it to the repo tree.
    param(
        [string]$RepoRoot = (Get-IbRepoRoot),
        [string]$ConfigPath = ''
    )
    $cfgPath = $ConfigPath
    if ([string]::IsNullOrEmpty($cfgPath)) {
        $cfgPath = Join-Path $RepoRoot 'config\intellibot.local.json'
    }
    $read = Read-IbJsonStrict -Path $cfgPath
    if (-not $read.Ok) {
        throw ('config unreadable ({0}): {1}' -f $cfgPath, $read.Error)
    }
    return $read.Value
}

function New-IbFailure {
    # Uniform fail-closed result object. Code vocabulary:
    # contracts\failure-codes.md. Nothing may have changed when one of
    # these is returned.
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    return New-Object PSObject -Property @{
        ok      = $false
        code    = $Code
        message = $Message
    }
}
