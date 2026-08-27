# intellibot-store.ps1 -- store\v1 access layer for the IntelliBot
# control-plane session tools. Windows PowerShell 5.1, zero dependencies.
#
# WRITE SURFACE: every mutation goes through Invoke-IbStoreCommit; every
# caller resolves its root through Resolve-IbStoreRoot (refuses roots
# outside the repo tree or across a reparse point). Production posture is
# store\v1 ONLY; the override exists solely for the dry-run harness.
#
# TOPOLOGY GUARD (FIX1-verify F1): Test-IbStoreShape runs FIRST on every
# operation and freezes on any reparse point (junction/symlink) or
# foreign subdirectory inside the operator store, reading attributes
# only and NEVER following a link. A textual containment check alone is
# defeated by a junction planted at episodes\ or a document leaf, and a
# foreign directory planted at a commit-target path defeats a naive
# move; the shape guard closes both before any enumerate/delete/write.
#
# CONSISTENCY MODEL (FIX1 F2, hardened FIX1-verify F2): authoritative
# state is what manifest.json attests. Each mutation is ONE staged
# transaction: all documents serialized, staged to <doc>.new, verified,
# THEN committed with [IO.File]::Replace (atomic target+backup in a
# single op -- no delete-then-move window) and the manifest committed
# LAST as the commit point; any throw rolls back to the manifest-attested
# state, and verification runs INSIDE the rollback envelope. Crash
# residue is reconciled by Repair-IbStoreResidue before any operation:
# a manifest lost mid-replace is forward-completed from its verified
# staged copy; .new staging residue is removed; an episode absent from
# the manifest is QUARANTINED (renamed .orphan, never deleted -- no
# committed data is destroyed); a document mismatching the manifest whose
# .lkg matches it is rolled back from .lkg. The manifest is the root of
# trust and is never auto-healed.
#
# SINGLE WRITER (FIX1-verify F2): the pre-op sweep heals destructively,
# so concurrent invocations would race. Each lifecycle tool holds an
# exclusive lock (Enter-IbStoreLock) for the sweep+commit; a second
# invocation refuses rather than corrupting. This is a local
# single-user control-plane tool, not a concurrent server.
#
# BYTE-LIMIT RULE (FIX1 F3): maxTotalBytesPerOperator is judged against
# the PROJECTED POST-COMMIT operator-directory size (documents + .lkg
# generations + manifest), refused E_LIMIT before any byte lands,
# enforced uniformly for create, append, and close.

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'intellibot-common.ps1')

$IbLockFileName = '.session.lock'

# FIX2 F2: marker prefix on the ONE thrown fault that means "the rollback
# did not fully restore the manifest-attested state". Callers translate a
# marked fault to E_STORE_CORRUPT (recovery required) and an unmarked one
# to E_INTERNAL (authoritative state unchanged). It is a message prefix
# rather than a custom exception type because PS 5.1 callers only ever see
# $_.Exception.Message across the dot-sourced boundary.
$IbUnrecoveredMarker = 'IB_STORE_UNRECOVERED:'

function Resolve-IbStoreRoot {
    param(
        [string]$RepoRoot = (Get-IbRepoRoot),
        [string]$StoreRoot = ''
    )
    if ([string]::IsNullOrEmpty($StoreRoot)) {
        $StoreRoot = Join-Path $RepoRoot 'store\v1'
    }
    $full = [System.IO.Path]::GetFullPath($StoreRoot)
    if (-not (Test-IbPathInside -Root $RepoRoot -Candidate $full)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_NOT_HOST' -Message ("store root {0} is outside the repository tree {1} or reaches across a reparse point (junction/symlink); containment refused (production posture: store\v1 only)" -f $full, $RepoRoot)) }
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_INTERNAL' -Message ("store root does not exist: {0}" -f $full)) }
    }
    return @{ Ok = $true; Root = $full }
}

function Get-IbOperatorDir {
    param(
        [Parameter(Mandatory = $true)][string]$StoreRoot,
        [Parameter(Mandatory = $true)][string]$OperatorId
    )
    if (-not ($OperatorId -cmatch '^[a-z0-9][a-z0-9-]{0,63}$')) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_BOUNDS' -Message ("operatorId fails the identifier pattern: {0}" -f $OperatorId)) }
    }
    $dir = Join-Path (Join-Path $StoreRoot 'operators') $OperatorId
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_INTERNAL' -Message ("operator store directory absent: {0}" -f $dir)) }
    }
    if (-not (Test-IbPathInside -Root $StoreRoot -Candidate $dir)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_NOT_HOST' -Message ("operator directory {0} reaches across a reparse point; containment refused" -f $dir)) }
    }
    return @{ Ok = $true; Dir = $dir }
}

function Test-IbStoreShape {
    # Freezes on foreign topology inside the operator store WITHOUT
    # following any reparse point (FIX1-verify F1). Run before any
    # enumerate/delete/write.
    param([Parameter(Mandatory = $true)][string]$OperatorDir)

    if (Test-IbReparsePoint -Path $OperatorDir) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("operator directory is a reparse point: {0}; refusing to follow it" -f $OperatorDir)) }
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $OperatorDir -Force)) {
        if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("reparse point inside the operator store: {0}; refusing to follow it" -f $child.FullName)) }
        }
        if ($child.PSIsContainer -and ($child.Name -cne 'episodes')) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("foreign subdirectory in the operator store (possible planted commit target): {0}" -f $child.FullName)) }
        }
    }
    $epDir = Join-Path $OperatorDir 'episodes'
    if (Test-Path -LiteralPath $epDir -PathType Container) {
        foreach ($child in @(Get-ChildItem -LiteralPath $epDir -Force)) {
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("reparse point inside episodes\: {0}" -f $child.FullName)) }
            }
            if ($child.PSIsContainer) {
                return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("foreign subdirectory under episodes\ (possible planted commit target): {0}" -f $child.FullName)) }
            }
        }
    }
    return @{ Ok = $true }
}

function Enter-IbStoreLock {
    # Exclusive single-writer lock (FIX1-verify F2). Holds an open
    # FileShare.None handle for the operation; a second invocation gets a
    # sharing violation and refuses. The OS releases the handle if the
    # process dies, so a leftover lock file is reopenable, never a
    # permanent block.
    param([Parameter(Mandatory = $true)][string]$OperatorDir)
    $lockPath = Join-Path $OperatorDir $IbLockFileName
    # The lock is the one write primitive that runs before the shape
    # guard, so it re-checks the lock leaf itself: a reparse point here
    # would be followed by File.Open (FIX1-verify). Refuse without
    # following.
    if (Test-IbReparsePoint -Path $lockPath) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("lock path is a reparse point: {0}; refusing to follow it" -f $lockPath)) }
    }
    try {
        $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        return @{ Ok = $true; Stream = $stream; Path = $lockPath }
    } catch {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_INTERNAL' -Message ("operator store is locked by another invocation (single-writer): {0}. No v1 code covers a busy store -- E_BUSY proposed for v2; E_INTERNAL per the failure-codes catch-all. Nothing changed." -f $lockPath)) }
    }
}

function Exit-IbStoreLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { if ($Lock.Stream) { $Lock.Stream.Close(); $Lock.Stream.Dispose() } } catch {}
    try { if (Test-Path -LiteralPath $Lock.Path -PathType Leaf) { [System.IO.File]::Delete($Lock.Path) } } catch {}
}

function Get-IbEpisodeFiles {
    # -Force so a hidden-attribute episode is still enumerated (FIX1-verify:
    # otherwise a planted hidden *.json would evade integrity, quarantine,
    # and byte accounting).
    param([Parameter(Mandatory = $true)][string]$OperatorDir)
    $epDir = Join-Path $OperatorDir 'episodes'
    if (-not (Test-Path -LiteralPath $epDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $epDir -File -Filter '*.json' -Force | Sort-Object Name)
}

function Test-IbAppendOnlyRel {
    # FIX2 F3: the store's OWN classification of an append-only leaf,
    # derived from the relative path instead of trusted from caller
    # metadata. An episode document is append-only by store law
    # (store\v1\SCHEMA.md): once committed it is never rewritten. The
    # store-layer guard must not be reachable only when a caller
    # remembers to say so.
    param([Parameter(Mandatory = $true)][string]$Rel)
    return ($Rel -cmatch '^episodes\\[^\\]+\.json\z')
}

function Get-IbStoreUsage {
    # Total data bytes under the operator directory and the episode count.
    # -Force counts hidden files too (no accounting blind spot). Only the
    # single-writer lock at the operator-dir ROOT is excluded (operational
    # ephemera); the exclusion is anchored to that exact path, not any
    # leaf that merely shares the name (FIX1-verify).
    param([Parameter(Mandatory = $true)][string]$OperatorDir)
    $lockFull = [System.IO.Path]::GetFullPath((Join-Path $OperatorDir $IbLockFileName))
    $files = @(Get-ChildItem -LiteralPath $OperatorDir -Recurse -File -Force | Where-Object { $_.FullName -cne $lockFull })
    $total = 0
    foreach ($f in $files) { $total += $f.Length }
    return @{
        TotalBytes   = [long]$total
        EpisodeCount = @(Get-IbEpisodeFiles -OperatorDir $OperatorDir).Count
    }
}

function Get-IbTextPin {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join ''
    return @{ Sha256 = $hash; Bytes = [long]$bytes.Length }
}

function Get-IbEolHint {
    # FIX2-verify diagnostic. The repository normalizes text in history
    # (`.gitattributes`: `* text=auto`), so a checkout on a platform whose
    # line-ending convention differs from the one that produced the
    # manifest lands every attested document on a DIFFERENT byte count and
    # hash -- indistinguishable, from the checksum alone, from real
    # corruption. This says which one it is instead of leaving an operator
    # to guess. Diagnostic ONLY: it never relaxes the comparison, and a
    # store in this state is still frozen. Returns '' when the bytes do
    # not match under any line-ending convention (i.e. real corruption).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes
    )
    try {
        $raw  = [System.IO.File]::ReadAllText($Path)
        $lf   = $raw.Replace("`r`n", "`n")
        $crlf = $lf.Replace("`n", "`r`n")
        foreach ($cand in @($lf, $crlf)) {
            $p = Get-IbTextPin -Text $cand
            if (($p.Sha256 -ceq $ExpectedSha256) -and ($p.Bytes -eq $ExpectedBytes)) {
                return ' -- DIAGNOSTIC: these bytes DO match the manifest once line endings are normalized, so this is a CRLF/LF checkout difference, NOT data corruption. This repository normalizes text in history (.gitattributes "* text=auto"), so a manifest baseline pinned on one convention will not verify on a checkout that produced the other. Re-pin the baseline for this checkout, or exclude store/v1 from normalization.'
            }
        }
    } catch { }
    return ''
}

function Read-IbStoreDoc {
    param(
        [Parameter(Mandatory = $true)][string]$OperatorDir,
        [Parameter(Mandatory = $true)][string]$RelPath
    )
    $p = Join-Path $OperatorDir $RelPath
    $read = Read-IbJsonStrict -Path $p
    if (-not $read.Ok) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("{0}: {1}" -f $RelPath, $read.Error)) }
    }
    $doc = $read.Value
    if (-not (Test-IbJsonObject $doc)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("{0}: top level is not a JSON object" -f $RelPath)) }
    }
    $names = Get-IbPropertyNames -Object $doc
    if (-not ($names -ccontains 'schemaVersion')) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("{0}: schemaVersion absent" -f $RelPath)) }
    }
    if (-not (Test-IbJsonInteger $doc.schemaVersion)) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("{0}: schemaVersion not an integer" -f $RelPath)) }
    }
    if ([long]$doc.schemaVersion -gt 1) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_SCHEMA_FUTURE' -Message ("{0}: schemaVersion {1} is newer than this build (v1); store frozen read-only" -f $RelPath, $doc.schemaVersion)) }
    }
    return @{ Ok = $true; Doc = $doc }
}

function Get-IbManifestTracked {
    param([Parameter(Mandatory = $true)]$Manifest)
    $tracked = @{}
    $mNames = Get-IbPropertyNames -Object $Manifest
    if (($mNames -ccontains 'lastKnownGood') -and ($null -ne $Manifest.lastKnownGood) -and (Test-IbJsonObject $Manifest.lastKnownGood)) {
        foreach ($p in $Manifest.lastKnownGood.PSObject.Properties) { $tracked[$p.Name] = $p.Value }
    }
    return $tracked
}

function Test-IbManifestBaseline {
    # FIX2 F1 (HIGH): the manifest must ATTEST every required document.
    #
    # A null, absent, or incomplete lastKnownGood is NOT "an empty trust
    # map" -- it is a store with NO RECOVERY ANCHOR, and it must FREEZE
    # rather than be silently accepted as integral. Without this guard,
    # Get-IbManifestTracked returns an empty hashtable and EVERY
    # downstream loop (rollback-from-.lkg, orphan quarantine, checksum
    # verification) iterates zero entries and reports success over
    # documents nothing attests. That is what let a first-generation hard
    # crash between the state File.Replace and the manifest File.Replace
    # promote an UNATTESTED state transition and still pass the sweep.
    #
    # Episodes are deliberately NOT required: they accrue over time and an
    # episode absent from the manifest is handled as an orphan
    # (quarantined, never deleted). Only the three always-present
    # documents form the baseline.
    param([Parameter(Mandatory = $true)]$Manifest)

    $required = @('profile.json','state.json','summary-current.json')
    $mNames = Get-IbPropertyNames -Object $Manifest

    # FIX2-verify: the manifest ENVELOPE, not just its lastKnownGood.
    # Invoke-IbStoreCommit reads these four fields unguarded to build the
    # next generation, and that read sits OUTSIDE the rollback envelope --
    # so a manifest missing one passes the sweep, reports the store
    # healthy, and then faults every write with a StrictMode property
    # error reported as E_INTERNAL "tool fault". A hand-reseeded manifest
    # that carries only schemaVersion + lastKnownGood (the only fields the
    # freeze message and the contracts name) hits exactly that. Validate
    # here, where the failure is a clean, actionable E_STORE_CORRUPT.
    foreach ($field in @('operatorId','storeVersion','createdUtc','checksumAlgo')) {
        if (-not ($mNames -ccontains $field)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json is missing the required identity field {0}; a manifest must carry schemaVersion, operatorId, storeVersion, createdUtc, checksumAlgo and lastKnownGood. Store frozen read-only." -f $field)) }
        }
    }

    if (-not ($mNames -ccontains 'lastKnownGood')) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message 'manifest.json carries no lastKnownGood map, so it attests nothing and offers no recovery anchor; store frozen read-only. Restore manifest.json from manifest.json.lkg by hand, or reseed the baseline attestation for profile.json, state.json and summary-current.json.') }
    }
    if (($null -eq $Manifest.lastKnownGood) -or (-not (Test-IbJsonObject $Manifest.lastKnownGood))) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message 'manifest.json lastKnownGood is null or not a JSON object; an unattested store has no recovery anchor and is NOT treated as an empty trust map (FIX2 F1). Store frozen read-only until a baseline attestation is restored.') }
    }

    $tracked = Get-IbManifestTracked -Manifest $Manifest
    foreach ($rel in $required) {
        if (-not $tracked.ContainsKey($rel)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json does not attest the required document {0}; an untracked required document cannot be verified or recovered, so the store is frozen read-only rather than accepted as integral (FIX2 F1)" -f $rel)) }
        }
    }

    # FIX2-verify: shape-validate EVERY tracked entry, not only the three
    # required ones. Episodes are exempt from being REQUIRED (they accrue
    # over time); they are NOT exempt from being WELL-FORMED. The repair
    # loop and the commit's carry-forward both dereference entry.sha256 /
    # .bytes / .updatedUtc unguarded, so one malformed episode entry
    # raises a StrictMode property fault mid-sweep -- after staging
    # residue has been deleted and orphans quarantined -- and surfaces as
    # E_INTERNAL instead of the E_STORE_CORRUPT the store actually needs.
    foreach ($rel in @($tracked.Keys)) {
        $entry = $tracked[$rel]
        if (-not (Test-IbJsonObject $entry)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json entry for {0} is not a JSON object" -f $rel)) }
        }
        $eNames = Get-IbPropertyNames -Object $entry
        foreach ($field in @('sha256','bytes','updatedUtc')) {
            if (-not ($eNames -ccontains $field)) {
                return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json entry for {0} is missing the {1} field" -f $rel, $field)) }
            }
        }
        if (-not ($entry.sha256 -is [string]) -or -not ($entry.sha256 -cmatch '^[0-9A-F]{64}\z')) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json entry for {0} carries a sha256 that is not 64 upper-case hex characters" -f $rel)) }
        }
        if (-not (Test-IbJsonInteger $entry.bytes)) {
            return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json entry for {0} carries a non-integer bytes value" -f $rel)) }
        }
    }
    return @{ Ok = $true }
}

function Repair-IbStoreResidue {
    # Reconciles non-authoritative residue to the manifest-attested state.
    # Assumes Test-IbStoreShape has already frozen on foreign topology, so
    # every path here is an ordinary in-store file. Returns
    # @{ Ok; Healed=[...] } or a freeze failure it must not heal.
    param([Parameter(Mandatory = $true)][string]$OperatorDir)
    $healed = New-Object System.Collections.ArrayList

    $manifestPath = Join-Path $OperatorDir 'manifest.json'
    $manifestNew  = $manifestPath + '.new'

    # 0. FORWARD-RECOVERY: a manifest lost inside the (now atomic) replace
    #    window -- absent on disk but present and valid as a verified
    #    staged copy -- is completed forward, because the manifest is the
    #    LAST commit and its .new attests the already-committed documents.
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $manifestNew -PathType Leaf) {
            $mnRead = Read-IbJsonStrict -Path $manifestNew
            if ($mnRead.Ok -and (Test-IbJsonObject $mnRead.Value)) {
                # FIX2-verify: forward-completion is lawful ONLY when the
                # staged manifest actually describes what is ON DISK.
                #
                # The manifest is the LAST commit, so one lost inside its
                # replace window attests documents that already landed --
                # every attestation must therefore match live bytes. A
                # staged manifest that does NOT match is not a lost
                # commit. It is residue from a transaction that was ROLLED
                # BACK and whose staging cleanup failed (the rollback path
                # tolerates that, on the ground that the next sweep
                # removes it -- true only while manifest.json still
                # exists), or it is a plant. Promoting it would install a
                # root of trust for a generation that was explicitly
                # reverted, after which step 4 below would overwrite live
                # documents from their .lkg to "restore" a state that was
                # never authoritative -- silently destroying a committed
                # generation. Verifying closes that, and it also converts
                # the ordering invariant SCHEMA.md asserts about this path
                # from a comment into a checked precondition.
                $fcOk = $true; $fcWhy = ''
                $fcBase = Test-IbManifestBaseline -Manifest $mnRead.Value
                if (-not $fcBase.Ok) {
                    $fcOk = $false; $fcWhy = 'it does not carry a valid required baseline'
                } else {
                    $fcTracked = Get-IbManifestTracked -Manifest $mnRead.Value
                    foreach ($fcRel in @($fcTracked.Keys)) {
                        $fcPath = Join-Path $OperatorDir $fcRel
                        if (-not (Test-Path -LiteralPath $fcPath -PathType Leaf)) {
                            $fcOk = $false; $fcWhy = ("it attests {0}, which is not on disk" -f $fcRel); break
                        }
                        try { $fcPin = Get-IbPin -Path $fcPath }
                        catch { $fcOk = $false; $fcWhy = ("{0} could not be read back to check it" -f $fcRel); break }
                        if (($fcPin.Sha256 -cne $fcTracked[$fcRel].sha256) -or ($fcPin.Bytes -ne [long]$fcTracked[$fcRel].bytes)) {
                            $fcOk = $false; $fcWhy = ("its attestation of {0} does not match the bytes on disk, so it describes a generation that is not the one committed" -f $fcRel); break
                        }
                    }
                }
                if (-not $fcOk) {
                    return @{ Ok = $false; Healed = @($healed); Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("manifest.json is absent and the staged copy was NOT forward-completed because {0}. A staged manifest is promoted only when it matches the documents on disk; this one does not, so it is stale or planted rather than a commit lost in the replace window. Restore manifest.json from manifest.json.lkg by hand." -f $fcWhy)) }
                }
                Move-Item -LiteralPath $manifestNew -Destination $manifestPath -Force
                [void]$healed.Add('healed: forward-completed manifest.json from staged copy verified against the documents on disk (crash in replace window)')
            } else {
                return @{ Ok = $false; Healed = @($healed); Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ('manifest.json absent and its staged copy is unusable; restore manifest.json from manifest.json.lkg by hand')) }
            }
        } else {
            return @{ Ok = $false; Healed = @($healed); Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ('manifest.json absent with no staged copy; restore from manifest.json.lkg by hand') ) }
        }
    }

    # 1. Staging residue: .new FILES never became authoritative. (Foreign
    #    directories at any path were already frozen by Test-IbStoreShape.)
    $residue = @(Get-ChildItem -LiteralPath $OperatorDir -Recurse -File -Force | Where-Object { $_.Name -clike '*.new' })
    foreach ($n in $residue) {
        [System.IO.File]::Delete($n.FullName)
        [void]$healed.Add(('healed: removed staging-residue file {0}' -f $n.Name))
    }

    # 2. Manifest is the root of trust; never auto-healed beyond step 0.
    $mr = Read-IbStoreDoc -OperatorDir $OperatorDir -RelPath 'manifest.json'
    if (-not $mr.Ok) { return @{ Ok = $false; Healed = @($healed); Failure = $mr.Failure } }

    # 2b. REQUIRED-BASELINE GUARD (FIX2 F1). This runs BEFORE any
    #     manifest-driven healing below, because with an unattested
    #     manifest step 3 would quarantine every episode as an orphan and
    #     step 4 would roll back nothing -- healing decisions must never be
    #     taken from a trust map that attests nothing.
    $baseline = Test-IbManifestBaseline -Manifest $mr.Doc
    if (-not $baseline.Ok) { return @{ Ok = $false; Healed = @($healed); Failure = $baseline.Failure } }

    $tracked = Get-IbManifestTracked -Manifest $mr.Doc

    # 3. Orphan episodes (on disk, absent from the manifest) are
    #    QUARANTINED, never deleted -- an interrupted append's episode is
    #    real data, and a manifest-lkg restore must not destroy the newer
    #    generation. Rename to <name>.orphan (excluded from *.json
    #    enumeration); collisions get a unique suffix.
    foreach ($ep in @(Get-IbEpisodeFiles -OperatorDir $OperatorDir)) {
        $rel = 'episodes\' + $ep.Name
        if (-not $tracked.ContainsKey($rel)) {
            $q = $ep.FullName + '.orphan'
            if (Test-Path -LiteralPath $q) { $q = $q + '.' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) }
            Move-Item -LiteralPath $ep.FullName -Destination $q -Force
            [void]$healed.Add(('healed: quarantined orphan episode {0} (absent from manifest; preserved, not deleted)' -f $ep.Name))
        }
    }

    # 4. A tracked document mismatching the manifest whose .lkg MATCHES
    #    the manifest is an interrupted commit -- rolled back from .lkg.
    foreach ($rel in @($tracked.Keys)) {
        $entry = $tracked[$rel]
        $p = Join-Path $OperatorDir $rel
        $liveOk = $false
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $pin = Get-IbPin -Path $p
            $liveOk = (($pin.Sha256 -ceq $entry.sha256) -and ($pin.Bytes -eq [long]$entry.bytes))
        }
        if (-not $liveOk) {
            $lkg = $p + '.lkg'
            if (Test-Path -LiteralPath $lkg -PathType Leaf) {
                $lpin = Get-IbPin -Path $lkg
                if (($lpin.Sha256 -ceq $entry.sha256) -and ($lpin.Bytes -eq [long]$entry.bytes)) {
                    Copy-Item -LiteralPath $lkg -Destination $p -Force
                    [void]$healed.Add(('healed: rolled back {0} from .lkg to the manifest-attested state' -f $rel))
                }
            }
        }
    }

    return @{ Ok = $true; Healed = @($healed) }
}

function Test-IbStoreIntegrity {
    # Shape guard first (freezes on foreign topology without following),
    # then self-healing repair, then the fail-closed sweep.
    param([Parameter(Mandatory = $true)][string]$OperatorDir)

    $shape = Test-IbStoreShape -OperatorDir $OperatorDir
    if (-not $shape.Ok) { return $shape }

    $repair = Repair-IbStoreResidue -OperatorDir $OperatorDir
    if (-not $repair.Ok) { return $repair }
    $healed = @($repair.Healed)

    foreach ($rel in @('manifest.json','profile.json','state.json','summary-current.json')) {
        $r = Read-IbStoreDoc -OperatorDir $OperatorDir -RelPath $rel
        if (-not $r.Ok) { return @{ Ok = $false; Healed = $healed; Failure = $r.Failure } }
    }
    foreach ($ep in @(Get-IbEpisodeFiles -OperatorDir $OperatorDir)) {
        $r = Read-IbStoreDoc -OperatorDir $OperatorDir -RelPath ('episodes\' + $ep.Name)
        if (-not $r.Ok) { return @{ Ok = $false; Healed = $healed; Failure = $r.Failure } }
    }

    $mr = Read-IbStoreDoc -OperatorDir $OperatorDir -RelPath 'manifest.json'
    $tracked = Get-IbManifestTracked -Manifest $mr.Doc
    foreach ($rel in @($tracked.Keys)) {
        $entry = $tracked[$rel]
        $p = Join-Path $OperatorDir $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            return @{ Ok = $false; Healed = $healed; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("tracked document missing: {0}" -f $rel)) }
        }
        $pin = Get-IbPin -Path $p
        if (($pin.Sha256 -ne $entry.sha256) -or ($pin.Bytes -ne [long]$entry.bytes)) {
            $eolHint = Get-IbEolHint -Path $p -ExpectedSha256 ([string]$entry.sha256) -ExpectedBytes ([long]$entry.bytes)
            return @{ Ok = $false; Healed = $healed; Failure = (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ("checksum mismatch on {0}: live {1} B / {2}, manifest {3} B / {4}; store frozen read-only until repaired from last-known-good{5}" -f $rel, $pin.Bytes, $pin.Sha256, $entry.bytes, $entry.sha256, $eolHint)) }
        }
    }
    return @{ Ok = $true; Healed = $healed }
}

function Resolve-IbToolFault {
    # FIX2 F2: translate a caught tool fault into an HONEST failure code.
    #
    # A commit that rolled back cleanly leaves authoritative state
    # unchanged, so the failure-codes catch-all E_INTERNAL is truthful.
    # A commit whose rollback did NOT fully restore leaves a store that is
    # not known-good, so it reports E_STORE_CORRUPT -- which the contract
    # already defines as "frozen read-only until repaired from
    # last-known-good". Reporting that second case as E_INTERNAL would
    # assert "authoritative state unchanged" over a store that may have
    # changed, which is the dishonesty FIX2 F2 removes.
    param([Parameter(Mandatory = $true)][string]$Message)
    if ($Message -clike ($IbUnrecoveredMarker + '*')) {
        return (New-IbFailure -Code 'E_STORE_CORRUPT' -Message ('store recovery required -- {0}' -f $Message))
    }
    return (New-IbFailure -Code 'E_INTERNAL' -Message ('tool fault: {0}' -f $Message))
}

function Add-IbHealedEvidence {
    # FIX2 F5: a refusal is not always physically inert. The pre-op sweep
    # may already have deleted staging residue or quarantined an orphan
    # before an UNRELATED refusal (e.g. "session already open"). The
    # contract now says AUTHORITATIVE state is unchanged, not that nothing
    # on disk moved -- so the healing that did happen is reported on the
    # refusal too, instead of being visible only on success.
    param($Failure, $Healed)
    $notes = @($Healed)
    if ($notes.Count -gt 0) {
        Add-Member -InputObject $Failure -NotePropertyName 'healed' -NotePropertyValue $notes -Force
    }
    return $Failure
}

function Invoke-IbStoreCommit {
    # The ONLY write path. Stages every document, gates the projected
    # post-commit byte total (F3), commits with atomic [IO.File]::Replace
    # (manifest LAST as the commit point), and rolls back on any throw --
    # verification included (FIX1-verify F2). Returns
    #   @{ Ok=$true; Pins=<rel -> 'N B / SHA'>; ManifestPin='...' }
    #   @{ Ok=$false; Failure=<failure object> }   (nothing committed)
    # Throws only if a rollback was performed; callers report E_INTERNAL
    # truthfully -- authoritative (manifest-attested) state is unchanged.
    param(
        [Parameter(Mandatory = $true)][string]$OperatorDir,
        [Parameter(Mandatory = $true)][array]$Writes,   # @{ Rel; Document; AppendOnly }
        [Parameter(Mandatory = $true)][long]$MaxTotalBytes
    )

    # Re-assert topology at the last moment (narrows any TOCTOU between the
    # opening sweep and here).
    $shape = Test-IbStoreShape -OperatorDir $OperatorDir
    if (-not $shape.Ok) { return @{ Ok = $false; Failure = $shape.Failure } }

    $mr = Read-IbStoreDoc -OperatorDir $OperatorDir -RelPath 'manifest.json'
    if (-not $mr.Ok) { return @{ Ok = $false; Failure = $mr.Failure } }
    # Defense in depth (FIX2 F1): every lifecycle caller sweeps first, but
    # the write path must not depend on that. An unattested manifest here
    # would silently carry an empty lastKnownGood forward into the new
    # manifest, re-creating the untracked-store hole one generation later.
    $mBase = Test-IbManifestBaseline -Manifest $mr.Doc
    if (-not $mBase.Ok) { return @{ Ok = $false; Failure = $mBase.Failure } }
    $manifest = $mr.Doc

    # ---- serialize + pin all staged content (no filesystem writes yet)
    $staged = New-Object System.Collections.ArrayList
    foreach ($w in @($Writes)) {
        $text = ConvertTo-IbJsonText -Value $w.Document -Depth 8
        $tp = Get-IbTextPin -Text $text
        [void]$staged.Add(@{
            Rel = $w.Rel; Text = $text; Sha256 = $tp.Sha256; Bytes = $tp.Bytes
            # FIX2 F3: append-only status is DERIVED from the leaf, not
            # merely taken from caller metadata. Every episodes\*.json is
            # append-only by the store's own law (store\v1\SCHEMA.md), so a
            # caller that forgets the flag -- or supplies $false -- can no
            # longer talk the store into overwriting a committed episode.
            # The caller flag is still honoured as an ADDITIONAL assertion
            # for non-episode leaves; it can only ever tighten, never relax.
            AppendOnly = ([bool]$w.AppendOnly -or (Test-IbAppendOnlyRel -Rel $w.Rel))
            Target = (Join-Path $OperatorDir $w.Rel)
            IsManifest = $false
        })
    }

    # ---- new manifest from staged pins (manifest = commit point)
    $lkgMap = [ordered]@{}
    $tracked = Get-IbManifestTracked -Manifest $manifest
    foreach ($rel in @($tracked.Keys)) {
        $lkgMap[$rel] = [ordered]@{
            sha256     = $tracked[$rel].sha256
            bytes      = [long]$tracked[$rel].bytes
            updatedUtc = $tracked[$rel].updatedUtc
        }
    }
    $now = Get-IbUtcNow
    foreach ($s in $staged) {
        $lkgMap[$s.Rel] = [ordered]@{ sha256 = $s.Sha256; bytes = $s.Bytes; updatedUtc = $now }
    }
    $newManifest = [ordered]@{
        schemaVersion = 1
        operatorId    = $manifest.operatorId
        storeVersion  = $manifest.storeVersion
        createdUtc    = $manifest.createdUtc
        checksumAlgo  = $manifest.checksumAlgo
        lastKnownGood = $lkgMap
    }
    $mText = ConvertTo-IbJsonText -Value $newManifest -Depth 8
    $mp = Get-IbTextPin -Text $mText
    [void]$staged.Add(@{
        Rel = 'manifest.json'; Text = $mText; Sha256 = $mp.Sha256; Bytes = $mp.Bytes
        AppendOnly = $false
        Target = (Join-Path $OperatorDir 'manifest.json')
        IsManifest = $true
    })

    # ---- F3 gate: projected post-commit total, before any byte lands.
    $usage = Get-IbStoreUsage -OperatorDir $OperatorDir
    $delta = [long]0
    foreach ($s in $staged) {
        $oldDoc = [long]0
        $hadDoc = (Test-Path -LiteralPath $s.Target -PathType Leaf)
        if ($hadDoc) { $oldDoc = (Get-Item -LiteralPath $s.Target).Length }
        $oldLkg = [long]0
        $lkgPath = $s.Target + '.lkg'
        if (Test-Path -LiteralPath $lkgPath -PathType Leaf) { $oldLkg = (Get-Item -LiteralPath $lkgPath).Length }
        $delta += ($s.Bytes - $oldDoc)
        if ($hadDoc) { $delta += ($oldDoc - $oldLkg) }
    }
    $projected = $usage.TotalBytes + $delta
    if ($projected -gt $MaxTotalBytes) {
        return @{ Ok = $false; Failure = (New-IbFailure -Code 'E_LIMIT' -Message ("projected post-commit store size {0} B exceeds maxTotalBytesPerOperator {1} B (counting rule: documents + .lkg generations + manifest); nothing written, never silently truncated" -f $projected, $MaxTotalBytes)) }
    }

    # ---- STAGE then COMMIT, with rollback (verification included) on
    #      any throw.
    $committed = New-Object System.Collections.ArrayList
    try {
        foreach ($s in $staged) {
            # A foreign directory at the target or .lkg path would make a
            # move corrupt the store (Move-Item copies INTO a directory).
            # Refuse and roll back. (Shape guard already froze most; this
            # is the last-moment TOCTOU backstop.)
            if (Test-Path -LiteralPath $s.Target -PathType Container) {
                throw ("foreign directory at commit target {0}; commit refused" -f $s.Rel)
            }
            if (Test-Path -LiteralPath ($s.Target + '.lkg') -PathType Container) {
                throw ("foreign directory at generation path {0}.lkg; commit refused" -f $s.Rel)
            }
            # Store-layer half of the append-only law (FIX1-verify): an
            # append-only target must never overwrite an existing file,
            # independent of the caller's own pre-check.
            if ($s.AppendOnly -and (Test-Path -LiteralPath $s.Target -PathType Leaf)) {
                throw ("append-only violation: {0} already exists; refusing to overwrite" -f $s.Rel)
            }
            Write-IbTextFile -Path ($s.Target + '.new') -Content $s.Text
            $back = Get-IbPin -Path ($s.Target + '.new')
            if (($back.Sha256 -ne $s.Sha256) -or ($back.Bytes -ne $s.Bytes)) {
                throw ("staging readback mismatch on {0}" -f $s.Rel)
            }
            $reparse = Read-IbJsonStrict -Path ($s.Target + '.new')
            if (-not $reparse.Ok) { throw ("staging re-parse failed on {0}: {1}" -f $s.Rel, $reparse.Error) }
        }
        foreach ($s in $staged) {
            $hadPrevious = (Test-Path -LiteralPath $s.Target -PathType Leaf)
            if ($hadPrevious) {
                # Atomic replace + backup in a single op: no delete-then-
                # move window (FIX1-verify F2). Clear read-only so Replace
                # can overwrite the backup.
                if (Test-Path -LiteralPath ($s.Target + '.lkg') -PathType Leaf) {
                    [System.IO.File]::SetAttributes(($s.Target + '.lkg'), [System.IO.FileAttributes]::Normal)
                }
                [System.IO.File]::SetAttributes($s.Target, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Replace(($s.Target + '.new'), $s.Target, ($s.Target + '.lkg'))
            } else {
                [System.IO.File]::Move(($s.Target + '.new'), $s.Target)
            }
            [void]$committed.Add(@{ Staged = $s; HadPrevious = $hadPrevious })
            # Verify each committed document IN the rollback envelope.
            $pin = Get-IbPin -Path $s.Target
            if (($pin.Sha256 -ne $s.Sha256) -or ($pin.Bytes -ne $s.Bytes)) {
                throw ("post-commit verification mismatch on {0}" -f $s.Rel)
            }
        }
    } catch {
        $fault = $_.Exception.Message
        $rollbackNotes = New-Object System.Collections.ArrayList
        $failedLeaves  = New-Object System.Collections.ArrayList
        # committed docs are reverted in REVERSE (manifest, if it landed,
        # first) to the manifest-attested prior state.
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
            } catch {
                # FIX2 F2: a restoration subfailure is NO LONGER just a
                # note. It is named, and it disqualifies the "rolled back"
                # claim below.
                [void]$failedLeaves.Add($c.Staged.Rel)
                [void]$rollbackNotes.Add(('RESTORATION FAILED for {0}: {1}' -f $c.Staged.Rel, $_.Exception.Message))
            }
        }
        foreach ($s in $staged) {
            try {
                if (Test-Path -LiteralPath ($s.Target + '.new') -PathType Leaf) { [System.IO.File]::Delete($s.Target + '.new') }
            } catch {
                # Staging cleanup is NOT authority-bearing: a leftover .new
                # never became authoritative and the next sweep removes it.
                # It is reported, but it does not by itself make the
                # rollback dishonest.
                [void]$rollbackNotes.Add(('staging cleanup of {0}.new failed: {1} (non-authoritative; removed by the next sweep)' -f $s.Rel, $_.Exception.Message))
            }
        }

        # FIX2 F2: VERIFY THE CLAIM BEFORE MAKING IT. The old code threw
        # "was rolled back to the manifest-attested state" unconditionally,
        # even when the loop above had just recorded a failed restoration --
        # and every caller mapped that to E_INTERNAL, which the failure
        # contract defines as "authoritative state unchanged". A failed
        # manifest restoration can leave a NEW manifest authoritative over
        # OLD leaves, which is the opposite of unchanged. So the store is
        # re-read against the manifest and the outcome is reported as it
        # actually is.
        # $unrestored  = POSITIVELY VERIFIED not to match the manifest.
        # $unverifiable = could not be checked at all. FIX2-verify keeps
        # these apart: "I checked and it is wrong" and "I could not check"
        # are different claims, and collapsing them would repeat, in the
        # opposite direction, exactly the dishonesty F2 was raised about.
        # Both still fail closed -- an unverifiable store is not a
        # known-good store -- but the message says which one happened.
        $unrestored   = New-Object System.Collections.ArrayList
        $unverifiable = New-Object System.Collections.ArrayList
        try {
            $vm = Read-IbStoreDoc -OperatorDir $OperatorDir -RelPath 'manifest.json'
            if (-not $vm.Ok) {
                [void]$unrestored.Add('manifest.json (unreadable after rollback)')
            } else {
                # FIX2-verify: this is the THIRD manifest-driven loop, and
                # it needs the same baseline guard as the other two. An
                # unattested manifest here would make the loop below
                # iterate zero entries and report a clean rollback having
                # verified nothing -- the precise vacuous-success shape
                # Test-IbManifestBaseline exists to stop.
                $vBase = Test-IbManifestBaseline -Manifest $vm.Doc
                if (-not $vBase.Ok) {
                    [void]$unrestored.Add('manifest.json (after rollback it no longer attests the required baseline: ' + $vBase.Failure.message + ')')
                } else {
                    $vTracked = Get-IbManifestTracked -Manifest $vm.Doc
                    foreach ($vRel in @($vTracked.Keys)) {
                        $vPath = Join-Path $OperatorDir $vRel
                        if (-not (Test-Path -LiteralPath $vPath -PathType Leaf)) {
                            [void]$unrestored.Add($vRel + ' (missing)')
                            continue
                        }
                        try {
                            $vPin = Get-IbPin -Path $vPath
                        } catch {
                            [void]$unverifiable.Add($vRel + ' (could not be read back: ' + $_.Exception.Message + ')')
                            continue
                        }
                        if (($vPin.Sha256 -cne $vTracked[$vRel].sha256) -or ($vPin.Bytes -ne [long]$vTracked[$vRel].bytes)) {
                            [void]$unrestored.Add($vRel + ' (on disk does not match what manifest.json attests)')
                        }
                    }
                }
            }
        } catch {
            [void]$unverifiable.Add('post-rollback verification itself failed: ' + $_.Exception.Message)
        }

        if (($failedLeaves.Count -gt 0) -or ($unrestored.Count -gt 0)) {
            throw ('{0} commit failed AND the rollback did NOT fully restore the manifest-attested state. The store is NOT known-good and authoritative state MAY have changed; repair by hand from the .lkg generations before the next operation. fault: {1}; failed restorations: [{2}]; still not matching the manifest: [{3}]; could not be verified: [{4}]; rollback log: {5}' -f $IbUnrecoveredMarker, $fault, (@($failedLeaves) -join ', '), (@($unrestored) -join ', '), (@($unverifiable) -join ', '), ($rollbackNotes -join '; '))
        }
        if ($unverifiable.Count -gt 0) {
            throw ('{0} commit failed and every rollback step reported success, but the rolled-back state COULD NOT BE VERIFIED against the manifest, so it is not claimed as restored. No document was observed to mismatch. fault: {1}; could not be verified: [{2}]; rollback log: {3}' -f $IbUnrecoveredMarker, $fault, (@($unverifiable) -join ', '), ($rollbackNotes -join '; '))
        }
        throw ("commit failed and was rolled back to the manifest-attested state -- fault: {0}; rollback: {1}" -f $fault, ($rollbackNotes -join '; '))
    }

    # Report the STAGED pins (already confirmed on disk by the in-try
    # post-commit verification). Re-reading disk here would be a throw
    # source OUTSIDE the rollback envelope -- a transient handle on a
    # just-committed file could then make the tool report E_INTERNAL
    # "nothing changed" after the commit fully landed, inviting a
    # double-commit on retry (FIX1-verify). No disk read after the commit.
    $pins = @{}
    foreach ($s in $staged) {
        if ($s.IsManifest) { continue }
        $pins[$s.Rel] = ('{0} B / {1}' -f $s.Bytes, $s.Sha256)
    }
    return @{
        Ok          = $true
        Pins        = $pins
        ManifestPin = ('{0} B / {1}' -f $mp.Bytes, $mp.Sha256)
    }
}
