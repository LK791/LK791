[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host "[PATH-MIGRATION] $Message"
}

function Test-Port([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Count-ByteSequence([byte[]]$Data, [byte[]]$Needle) {
    if ($Needle.Length -eq 0 -or $Data.Length -lt $Needle.Length) {
        return 0
    }

    $count = 0
    for ($i = 0; $i -le $Data.Length - $Needle.Length; $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Data[$i + $j] -ne $Needle[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            $count++
            $i += $Needle.Length - 1
        }
    }
    return $count
}

function Replace-ByteSequence([byte[]]$Data, [byte[]]$OldBytes, [byte[]]$NewBytes) {
    $stream = New-Object IO.MemoryStream
    try {
        for ($i = 0; $i -lt $Data.Length;) {
            $matched = $false
            if ($i -le $Data.Length - $OldBytes.Length) {
                $matched = $true
                for ($j = 0; $j -lt $OldBytes.Length; $j++) {
                    if ($Data[$i + $j] -ne $OldBytes[$j]) {
                        $matched = $false
                        break
                    }
                }
            }

            if ($matched) {
                $stream.Write($NewBytes, 0, $NewBytes.Length)
                $i += $OldBytes.Length
            }
            else {
                $stream.WriteByte($Data[$i])
                $i++
            }
        }
        return ,$stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Normalize-Root([string]$Path) {
    return [IO.Path]::GetFullPath($Path.Replace('/', '\')).TrimEnd('\')
}

$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$localRoot = Join-Path $root 'local8848'
$metadataDir = Join-Path $localRoot 'storage\CHUNK_METADATA'
$utf8 = New-Object Text.UTF8Encoding($false)

Write-Step "Current program root: $root"

if ($root -match '[^\x20-\x7E]') {
    throw 'DolphinDB V3.00.6 or its plugins cannot reliably start from a non-ASCII program path. Use English letters, digits, spaces, underscores, or hyphens in the full path.'
}

if (Get-Process dolphindb -ErrorAction SilentlyContinue) {
    throw 'DolphinDB is running. Run the safe-shutdown BAT first, then retry.'
}
if (Test-Port 8848) {
    throw 'Port 8848 is in use. Stop the program using that port before migrating paths.'
}

if (-not (Test-Path -LiteralPath $localRoot -PathType Container)) {
    Write-Step 'local8848 does not exist. This is a fresh environment; no migration is required.'
    exit 0
}
if (-not (Test-Path -LiteralPath $metadataDir -PathType Container)) {
    throw "Metadata directory does not exist: $metadataDir"
}

$metadataFiles = @(Get-ChildItem -LiteralPath $metadataDir -File -Recurse -Force)
if ($metadataFiles.Count -eq 0) {
    Write-Step 'No CHUNK_METADATA files were found. No migration is required.'
    exit 0
}

# Paths are stored as UTF-8 strings inside binary metadata records. This scan is
# only for discovering roots; binary files are never rewritten as text.
$rootPattern = '(?i)((?:[A-Z]:|\\\\[^\\/\x00\r\n]+[\\/][^\\/\x00\r\n]+)[\\/][^\x00\r\n]*?)[\\/]local8848[\\/]storage[\\/](?:CHUNKS|DATABASE)[\\/]'
$discovered = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $metadataFiles) {
    $data = [IO.File]::ReadAllBytes($file.FullName)
    $text = $utf8.GetString($data)
    foreach ($match in [regex]::Matches($text, $rootPattern)) {
        $candidate = $match.Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $discovered.Add($candidate)
        }
    }
}

if ($discovered.Count -eq 0) {
    throw 'No stored DolphinDB root path was found in CHUNK_METADATA. Nothing was changed.'
}

$normalizedMap = @{}
foreach ($candidate in $discovered) {
    try {
        $normalized = Normalize-Root $candidate
        if (-not $normalizedMap.ContainsKey($normalized)) {
            $normalizedMap[$normalized] = New-Object 'System.Collections.Generic.List[string]'
        }
        if (-not $normalizedMap[$normalized].Contains($candidate)) {
            $normalizedMap[$normalized].Add($candidate)
        }
    }
    catch {
        # Ignore byte strings that only happened to resemble a Windows path.
    }
}

$oldNormalizedRoots = @($normalizedMap.Keys | Where-Object {
    -not [string]::Equals($_, $root, [StringComparison]::OrdinalIgnoreCase)
})

if ($oldNormalizedRoots.Count -eq 0) {
    Write-Step 'Stored metadata already uses the current program root. No replacement is required.'
    exit 0
}
if ($oldNormalizedRoots.Count -gt 1) {
    Write-Host 'Detected more than one old storage root:'
    $oldNormalizedRoots | ForEach-Object { Write-Host "  $_" }
    throw 'Migration stopped to avoid rewriting a multi-volume database incorrectly.'
}

$oldRoot = $oldNormalizedRoots[0]
$actualOldRoots = @($normalizedMap[$oldRoot])
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupParent = Join-Path $root '_path_migration_backup'
$backupDir = Join-Path $backupParent "${timestamp}_CHUNK_METADATA"
$reportPath = Join-Path $backupParent "${timestamp}_migration_report.txt"

New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
Copy-Item -LiteralPath $metadataDir -Destination $backupDir -Recurse -Force

Write-Step "Old program root: $oldRoot"
Write-Step "Backup created: $backupDir"

$changedFiles = New-Object 'System.Collections.Generic.List[string]'
$replacementCount = 0
$report = New-Object 'System.Collections.Generic.List[string]'
$report.Add("Time=$timestamp")
$report.Add("OldRoot=$oldRoot")
$report.Add("NewRoot=$root")
$report.Add("Backup=$backupDir")

try {
    foreach ($file in $metadataFiles) {
        [byte[]]$original = [IO.File]::ReadAllBytes($file.FullName)
        [byte[]]$updated = $original
        $fileCount = 0

        foreach ($actualOldRoot in $actualOldRoots) {
            [byte[]]$oldBytes = $utf8.GetBytes($actualOldRoot)
            [byte[]]$newBytes = $utf8.GetBytes($root)
            $count = Count-ByteSequence $updated $oldBytes
            if ($count -gt 0) {
                [byte[]]$updated = Replace-ByteSequence $updated $oldBytes $newBytes
                $fileCount += $count
            }
        }

        if ($fileCount -gt 0) {
            $tempFile = "$($file.FullName).path-migration.tmp"
            [IO.File]::WriteAllBytes($tempFile, $updated)

            foreach ($actualOldRoot in $actualOldRoots) {
                if ((Count-ByteSequence $updated $utf8.GetBytes($actualOldRoot)) -ne 0) {
                    throw "Old path remained after rebuilding $($file.FullName)"
                }
            }

            $replaceBackup = "$($file.FullName).path-migration.replace.bak"
            [IO.File]::Replace($tempFile, $file.FullName, $replaceBackup, $true)
            Remove-Item -LiteralPath $replaceBackup -Force
            $changedFiles.Add($file.FullName)
            $replacementCount += $fileCount
            $report.Add("ChangedFile=$($file.FullName); Replacements=$fileCount; OldBytes=$($original.Length); NewBytes=$($updated.Length)")
        }
    }

    if ($replacementCount -eq 0) {
        throw 'The old root was detected but no exact UTF-8 byte sequence could be replaced.'
    }

    foreach ($file in $metadataFiles) {
        [byte[]]$verified = [IO.File]::ReadAllBytes($file.FullName)
        foreach ($actualOldRoot in $actualOldRoots) {
            if ((Count-ByteSequence $verified $utf8.GetBytes($actualOldRoot)) -ne 0) {
                throw "Final verification found an old path in $($file.FullName)"
            }
        }
    }

    $report.Add("Result=SUCCESS")
    $report.Add("ChangedFiles=$($changedFiles.Count)")
    $report.Add("TotalReplacements=$replacementCount")
    [IO.File]::WriteAllLines($reportPath, $report, $utf8)

    Write-Step "Migration succeeded. Changed files: $($changedFiles.Count); replacements: $replacementCount"
    Write-Step "Report: $reportPath"
    exit 0
}
catch {
    foreach ($backupFile in Get-ChildItem -LiteralPath $backupDir -File -Recurse -Force) {
        $relative = $backupFile.FullName.Substring($backupDir.Length).TrimStart('\')
        $destination = Join-Path $metadataDir $relative
        $destinationParent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $backupFile.FullName -Destination $destination -Force
    }
    Get-ChildItem -LiteralPath $metadataDir -Filter '*.path-migration.tmp' -File -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $report.Add("Result=ROLLED_BACK")
    $report.Add("Error=$($_.Exception.Message)")
    [IO.File]::WriteAllLines($reportPath, $report, $utf8)
    throw "Migration failed and metadata was restored from backup. $($_.Exception.Message)"
}
