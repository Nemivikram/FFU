[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$ManifestPath,
	[Parameter(Mandatory = $true)]
	[ValidateSet('Audit', 'Specialize')]
	[string]$Phase
)

$ErrorActionPreference = 'Stop'
$logPath = 'C:\Windows\Temp\FFUDataPartitionDriveLetters.log'
$runtimeDirectory = Split-Path -Path $ManifestPath -Parent
$successMarkerPath = Join-Path -Path $runtimeDirectory -ChildPath "$Phase.success"
$failureMarkerPath = Join-Path -Path $runtimeDirectory -ChildPath "$Phase.failure"

function Write-FFUDataPartitionDriveLetterLog {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	$logDirectory = Split-Path -Path $logPath -Parent
	if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
		New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
	}

	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
	Add-Content -LiteralPath $logPath -Value "[$timestamp] [$Phase] $Message" -Encoding UTF8
}

function ConvertTo-NormalizedPartitionGuid {
	param(
		[object]$Value
	)

	return ([string]$Value).Trim().Trim('{', '}').ToLowerInvariant()
}

function Resolve-FFUDataPartition {
	param(
		[Parameter(Mandatory = $true)]
		[object]$ManifestEntry,
		[Parameter(Mandatory = $true)]
		[object[]]$DataPartitions
	)

	$partition = $null
	$manifestGuid = ConvertTo-NormalizedPartitionGuid -Value $ManifestEntry.PartitionGuid
	if (-not [string]::IsNullOrWhiteSpace($manifestGuid)) {
		$guidMatches = @($DataPartitions | Where-Object { (ConvertTo-NormalizedPartitionGuid -Value $_.Guid) -eq $manifestGuid })
		if ($guidMatches.Count -gt 1) {
			throw "Partition '$($ManifestEntry.Name)' matched more than one GPT partition GUID."
		}
		if ($guidMatches.Count -eq 1) {
			$partition = $guidMatches[0]
			Write-FFUDataPartitionDriveLetterLog "Resolved '$($ManifestEntry.Name)' by GPT partition GUID."
		}
	}

	if ($null -eq $partition) {
		$dataOrdinal = [int]$ManifestEntry.DataOrdinal
		if ($dataOrdinal -lt 1 -or $dataOrdinal -gt $DataPartitions.Count) {
			throw "Partition '$($ManifestEntry.Name)' data ordinal $dataOrdinal is outside the applied disk layout."
		}
		$partition = $DataPartitions[$dataOrdinal - 1]
		Write-FFUDataPartitionDriveLetterLog "Resolved '$($ManifestEntry.Name)' by strict data partition order fallback."
	}

	if ([int]$partition.PartitionNumber -ne [int]$ManifestEntry.PartitionNumber) {
		throw "Partition '$($ManifestEntry.Name)' partition number mismatch. Expected $($ManifestEntry.PartitionNumber), found $($partition.PartitionNumber)."
	}
	$allowSizeChange = $false
	if ($ManifestEntry.PSObject.Properties.Name -contains 'AllowSizeChange') {
		$allowSizeChange = [System.Convert]::ToBoolean($ManifestEntry.AllowSizeChange)
	}
	if (-not $allowSizeChange -and [uint64]$partition.Size -ne [uint64]$ManifestEntry.SizeBytes) {
		throw "Partition '$($ManifestEntry.Name)' size mismatch. Expected $($ManifestEntry.SizeBytes), found $($partition.Size)."
	}
	if ($allowSizeChange -and [uint64]$partition.Size -ne [uint64]$ManifestEntry.SizeBytes) {
		Write-FFUDataPartitionDriveLetterLog "Accepted optimized FFU size change for '$($ManifestEntry.Name)'. Captured $($ManifestEntry.SizeBytes), deployed $($partition.Size)."
	}

	$volumes = @($partition | Get-Volume -ErrorAction SilentlyContinue)
	if ($volumes.Count -ne 1) {
		throw "Partition '$($ManifestEntry.Name)' does not resolve to exactly one volume."
	}
	$volume = $volumes[0]
	if (([string]$volume.FileSystemLabel).Trim() -ine ([string]$ManifestEntry.Label).Trim()) {
		throw "Partition '$($ManifestEntry.Name)' volume label mismatch. Expected '$($ManifestEntry.Label)', found '$($volume.FileSystemLabel)'."
	}
	if (([string]$volume.FileSystem).Trim() -ine ([string]$ManifestEntry.FileSystem).Trim()) {
		throw "Partition '$($ManifestEntry.Name)' file system mismatch. Expected '$($ManifestEntry.FileSystem)', found '$($volume.FileSystem)'."
	}

	return [pscustomobject]@{
		ManifestEntry = $ManifestEntry
		Partition     = $partition
		Volume        = $volume
	}
}

function Set-FFUDataPartitionDriveLetters {
	param(
		[Parameter(Mandatory = $true)]
		[object]$Manifest
	)

	if ($env:SystemDrive -ine 'C:') {
		throw "Windows must be running from C:. Current SystemDrive is '$env:SystemDrive'."
	}

	$windowsPartitions = @(Get-Partition -DriveLetter C -ErrorAction SilentlyContinue)
	if ($windowsPartitions.Count -ne 1) {
		throw "Unable to resolve exactly one Windows C: partition. Found $($windowsPartitions.Count)."
	}
	$windowsPartition = $windowsPartitions[0]
	$diskNumber = [int]$windowsPartition.DiskNumber
	$basicDataGptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
	$dataPartitions = @(Get-Partition -DiskNumber $diskNumber -ErrorAction Stop |
		Where-Object { ([string]$_.GptType).ToLowerInvariant() -eq $basicDataGptType -and $_.PartitionNumber -ne $windowsPartition.PartitionNumber } |
		Sort-Object -Property PartitionNumber)

	$resolvedEntries = [System.Collections.Generic.List[pscustomobject]]::new()
	foreach ($manifestEntry in @($Manifest.Partitions)) {
		$requestedDriveLetter = ([string]$manifestEntry.RequestedDriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($requestedDriveLetter -notmatch '^[D-Z]$') {
			throw "Partition '$($manifestEntry.Name)' requests invalid drive letter '$requestedDriveLetter'."
		}
		$manifestEntry.RequestedDriveLetter = $requestedDriveLetter
		$resolvedEntries.Add((Resolve-FFUDataPartition -ManifestEntry $manifestEntry -DataPartitions $dataPartitions))
	}

	foreach ($resolvedEntry in $resolvedEntries) {
		$requestedDriveLetter = [string]$resolvedEntry.ManifestEntry.RequestedDriveLetter
		$currentDriveLetter = ([string]$resolvedEntry.Partition.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($currentDriveLetter -eq $requestedDriveLetter) {
			continue
		}

		$requestedVolumes = @(Get-Volume -DriveLetter $requestedDriveLetter -ErrorAction SilentlyContinue)
		if ($requestedVolumes.Count -gt 0) {
			$requestedOwner = @(Get-Partition -DriveLetter $requestedDriveLetter -ErrorAction SilentlyContinue | Select-Object -First 1)
			$ownerDescription = if ($requestedOwner.Count -gt 0) {
				"disk $($requestedOwner[0].DiskNumber), partition $($requestedOwner[0].PartitionNumber)"
			}
			else {
				"volume '$($requestedVolumes[0].FileSystemLabel)'"
			}
			throw "Cannot assign drive ${requestedDriveLetter}: to partition '$($resolvedEntry.ManifestEntry.Name)' because the letter is owned by $ownerDescription."
		}
	}

	foreach ($resolvedEntry in $resolvedEntries) {
		$requestedDriveLetter = [string]$resolvedEntry.ManifestEntry.RequestedDriveLetter
		$currentDriveLetter = ([string]$resolvedEntry.Partition.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($currentDriveLetter -ne $requestedDriveLetter) {
			$currentDriveLetterText = if ([string]::IsNullOrWhiteSpace($currentDriveLetter)) { 'no drive letter' } else { "drive ${currentDriveLetter}:" }
			Write-FFUDataPartitionDriveLetterLog "Assigning drive ${requestedDriveLetter}: to '$($resolvedEntry.ManifestEntry.Name)', currently $currentDriveLetterText."
			Set-Partition -DiskNumber $resolvedEntry.Partition.DiskNumber -PartitionNumber $resolvedEntry.Partition.PartitionNumber -NewDriveLetter $requestedDriveLetter -ErrorAction Stop
		}

		$verifiedPartitions = @(Get-Partition -DiskNumber $resolvedEntry.Partition.DiskNumber -PartitionNumber $resolvedEntry.Partition.PartitionNumber -ErrorAction Stop)
		if ($verifiedPartitions.Count -ne 1 -or ([string]$verifiedPartitions[0].DriveLetter).Trim().TrimEnd(':').ToUpperInvariant() -ne $requestedDriveLetter) {
			throw "Drive letter verification failed for partition '$($resolvedEntry.ManifestEntry.Name)'."
		}
		Write-FFUDataPartitionDriveLetterLog "Verified '$($resolvedEntry.ManifestEntry.Name)' at drive ${requestedDriveLetter}:."
	}
}

function Remove-FFUDataPartitionDriveLetterArtifacts {
	if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
		return
	}

	Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force -ErrorAction Stop
}

try {
	Write-FFUDataPartitionDriveLetterLog 'Starting data partition drive-letter enforcement.'
	if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
		throw "Drive-letter manifest was not found at '$ManifestPath'."
	}

	$manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
	if ([int]$manifest.SchemaVersion -ne 1) {
		throw "Unsupported drive-letter manifest schema version '$($manifest.SchemaVersion)'."
	}
	if (@($manifest.Partitions).Count -eq 0) {
		throw 'Drive-letter manifest does not contain any partitions.'
	}

	Remove-Item -LiteralPath $successMarkerPath, $failureMarkerPath -Force -ErrorAction SilentlyContinue
	Set-FFUDataPartitionDriveLetters -Manifest $manifest

	if ($Phase -eq 'Audit') {
		Set-Content -LiteralPath $successMarkerPath -Value (Get-Date -Format 'o') -Encoding ASCII -Force
		Write-FFUDataPartitionDriveLetterLog 'Audit enforcement completed successfully.'
	}
	else {
		Write-FFUDataPartitionDriveLetterLog 'Specialize enforcement completed successfully. Removing runtime artifacts.'
		Remove-FFUDataPartitionDriveLetterArtifacts
		Write-FFUDataPartitionDriveLetterLog 'Runtime artifact cleanup completed successfully.'
	}

	exit 0
}
catch {
	$errorMessage = $_.Exception.Message
	Write-FFUDataPartitionDriveLetterLog "ERROR: $errorMessage"
	if (Test-Path -LiteralPath $runtimeDirectory -PathType Container) {
		Set-Content -LiteralPath $failureMarkerPath -Value $errorMessage -Encoding UTF8 -Force -ErrorAction SilentlyContinue
	}
	exit 3
}
