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

function Get-FFUDataPartitionAssignmentMode {
	param(
		[Parameter(Mandatory = $true)]
		[object]$ManifestEntry
	)

	$assignmentMode = 'Configured'
	if ($ManifestEntry.PSObject.Properties.Name -contains 'AssignmentMode') {
		$assignmentMode = ([string]$ManifestEntry.AssignmentMode).Trim()
	}
	if ($assignmentMode -notin @('Configured', 'Automatic')) {
		throw "Partition '$($ManifestEntry.Name)' uses unsupported assignment mode '$assignmentMode'."
	}

	return $assignmentMode
}

function Get-FFUDeploymentMediaDiskNumbers {
	$deploymentMediaDiskNumbers = [System.Collections.Generic.HashSet[int]]::new()
	$deploymentVolumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { ([string]$_.FileSystemLabel).Trim() -ieq 'Deploy' })
	foreach ($deploymentVolume in $deploymentVolumes) {
		$driveLetter = ([string]$deploymentVolume.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($driveLetter -notmatch '^[A-Z]$') {
			continue
		}

		$deploymentPartitions = @(Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue)
		foreach ($deploymentPartition in $deploymentPartitions) {
			$deploymentDisk = Get-Disk -Number $deploymentPartition.DiskNumber -ErrorAction SilentlyContinue
			if ($null -ne $deploymentDisk -and (([string]$deploymentDisk.BusType -ieq 'USB') -or ([string]$deploymentVolume.DriveType -ieq 'Removable'))) {
				$null = $deploymentMediaDiskNumbers.Add([int]$deploymentPartition.DiskNumber)
			}
		}
	}

	return @($deploymentMediaDiskNumbers | Sort-Object)
}

function Get-FFUNextAvailableDriveLetter {
	param(
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[System.Collections.Generic.HashSet[string]]$ReservedDriveLetters
	)

	foreach ($driveLetterCode in ([int][char]'D')..([int][char]'Z')) {
		$candidateDriveLetter = [string][char]$driveLetterCode
		if ($ReservedDriveLetters.Add($candidateDriveLetter)) {
			return $candidateDriveLetter
		}
	}

	throw 'No drive letter from D through Z is available.'
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
	$targetPartitionKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($manifestEntry in @($Manifest.Partitions)) {
		$requestedDriveLetter = ([string]$manifestEntry.RequestedDriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($requestedDriveLetter -notmatch '^[D-Z]$') {
			throw "Partition '$($manifestEntry.Name)' requests invalid drive letter '$requestedDriveLetter'."
		}

		$resolvedPartition = Resolve-FFUDataPartition -ManifestEntry $manifestEntry -DataPartitions $dataPartitions
		$assignmentMode = Get-FFUDataPartitionAssignmentMode -ManifestEntry $manifestEntry
		$targetPartitionKey = "$($resolvedPartition.Partition.DiskNumber):$($resolvedPartition.Partition.PartitionNumber)"
		if (-not $targetPartitionKeys.Add($targetPartitionKey)) {
			throw "Partition '$($manifestEntry.Name)' resolves to a data partition already targeted by another manifest entry."
		}
		$resolvedEntries.Add([pscustomobject]@{
				ManifestEntry       = $resolvedPartition.ManifestEntry
				Partition           = $resolvedPartition.Partition
				Volume              = $resolvedPartition.Volume
				AssignmentMode      = $assignmentMode
				RequestedDriveLetter = $requestedDriveLetter
			})
	}

	$deploymentMediaDiskNumbers = @(Get-FFUDeploymentMediaDiskNumbers)
	$deploymentMediaDiskNumberSet = [System.Collections.Generic.HashSet[int]]::new()
	foreach ($deploymentMediaDiskNumber in $deploymentMediaDiskNumbers) {
		$null = $deploymentMediaDiskNumberSet.Add([int]$deploymentMediaDiskNumber)
	}

	$reservedDriveLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($resolvedEntry in $resolvedEntries) {
		if ($resolvedEntry.AssignmentMode -eq 'Configured') {
			$null = $reservedDriveLetters.Add([string]$resolvedEntry.RequestedDriveLetter)
		}
	}

	foreach ($driveLetterCode in ([int][char]'D')..([int][char]'Z')) {
		$driveLetter = [string][char]$driveLetterCode
		$letterOwners = @(Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue)
		$hasProtectedOwner = $false
		foreach ($letterOwner in $letterOwners) {
			$ownerKey = "$($letterOwner.DiskNumber):$($letterOwner.PartitionNumber)"
			if (-not $targetPartitionKeys.Contains($ownerKey) -and -not $deploymentMediaDiskNumberSet.Contains([int]$letterOwner.DiskNumber)) {
				$hasProtectedOwner = $true
				break
			}
		}

		if ($hasProtectedOwner -or ($letterOwners.Count -eq 0 -and $null -ne (Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue))) {
			$null = $reservedDriveLetters.Add($driveLetter)
		}
	}

	foreach ($resolvedEntry in $resolvedEntries) {
		if ($resolvedEntry.AssignmentMode -ne 'Automatic') {
			continue
		}

		$resolvedEntry.RequestedDriveLetter = Get-FFUNextAvailableDriveLetter -ReservedDriveLetters $reservedDriveLetters
		Write-FFUDataPartitionDriveLetterLog "Selected next available drive $($resolvedEntry.RequestedDriveLetter): for '$($resolvedEntry.ManifestEntry.Name)'."
	}

	$requestedDriveLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($resolvedEntry in $resolvedEntries) {
		if (-not $requestedDriveLetters.Add([string]$resolvedEntry.RequestedDriveLetter)) {
			throw "Drive letter $($resolvedEntry.RequestedDriveLetter): is requested by more than one data partition."
		}
	}

	$deploymentMediaDisksToRelocate = [System.Collections.Generic.HashSet[int]]::new()
	foreach ($resolvedEntry in $resolvedEntries) {
		$requestedDriveLetter = [string]$resolvedEntry.RequestedDriveLetter
		$currentDriveLetter = ([string]$resolvedEntry.Partition.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($currentDriveLetter -eq $requestedDriveLetter) {
			continue
		}

		$requestedOwners = @(Get-Partition -DriveLetter $requestedDriveLetter -ErrorAction SilentlyContinue)
		foreach ($requestedOwner in $requestedOwners) {
			$ownerKey = "$($requestedOwner.DiskNumber):$($requestedOwner.PartitionNumber)"
			if ($targetPartitionKeys.Contains($ownerKey)) {
				continue
			}
			if ($deploymentMediaDiskNumberSet.Contains([int]$requestedOwner.DiskNumber)) {
				$null = $deploymentMediaDisksToRelocate.Add([int]$requestedOwner.DiskNumber)
				continue
			}

			$requestedVolume = @($requestedOwner | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1)
			$ownerDescription = if ($requestedVolume.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$requestedVolume[0].FileSystemLabel)) {
				"volume '$($requestedVolume[0].FileSystemLabel)' on disk $($requestedOwner.DiskNumber), partition $($requestedOwner.PartitionNumber)"
			}
			else {
				"disk $($requestedOwner.DiskNumber), partition $($requestedOwner.PartitionNumber)"
			}
			throw "Cannot assign drive ${requestedDriveLetter}: to partition '$($resolvedEntry.ManifestEntry.Name)' because the letter is owned by $ownerDescription."
		}

		if ($requestedOwners.Count -eq 0) {
			$existingFileSystemDrive = Get-PSDrive -Name $requestedDriveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
			if ($null -ne $existingFileSystemDrive) {
				throw "Cannot assign drive ${requestedDriveLetter}: to partition '$($resolvedEntry.ManifestEntry.Name)' because it is mapped to '$($existingFileSystemDrive.Root)'."
			}
		}
	}

	$deploymentMediaPartitionsToRelocate = [System.Collections.Generic.List[pscustomobject]]::new()
	foreach ($deploymentMediaDiskNumber in @($deploymentMediaDisksToRelocate | Sort-Object)) {
		$deploymentMediaPartitions = @(Get-Partition -DiskNumber $deploymentMediaDiskNumber -ErrorAction Stop | Sort-Object -Property PartitionNumber)
		foreach ($deploymentMediaPartition in $deploymentMediaPartitions) {
			$currentDriveLetter = ([string]$deploymentMediaPartition.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
			if ($currentDriveLetter -notmatch '^[D-Z]$') {
				continue
			}

			$deploymentMediaVolume = @($deploymentMediaPartition | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1)
			$volumeLabel = if ($deploymentMediaVolume.Count -gt 0) { [string]$deploymentMediaVolume[0].FileSystemLabel } else { '' }
			$deploymentMediaPartitionsToRelocate.Add([pscustomobject]@{
					Partition   = $deploymentMediaPartition
					DriveLetter = $currentDriveLetter
					VolumeLabel = $volumeLabel
				})
		}
	}

	$finalReservedDriveLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($driveLetterCode in ([int][char]'D')..([int][char]'Z')) {
		$driveLetter = [string][char]$driveLetterCode
		$letterOwners = @(Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue)
		$hasRemainingOwner = $false
		foreach ($letterOwner in $letterOwners) {
			$ownerKey = "$($letterOwner.DiskNumber):$($letterOwner.PartitionNumber)"
			if (-not $targetPartitionKeys.Contains($ownerKey) -and -not $deploymentMediaDisksToRelocate.Contains([int]$letterOwner.DiskNumber)) {
				$hasRemainingOwner = $true
				break
			}
		}

		if ($hasRemainingOwner -or ($letterOwners.Count -eq 0 -and $null -ne (Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue))) {
			$null = $finalReservedDriveLetters.Add($driveLetter)
		}
	}
	foreach ($resolvedEntry in $resolvedEntries) {
		$null = $finalReservedDriveLetters.Add([string]$resolvedEntry.RequestedDriveLetter)
	}
	$availableMediaDriveLetterCount = 0
	foreach ($driveLetterCode in ([int][char]'D')..([int][char]'Z')) {
		if (-not $finalReservedDriveLetters.Contains([string][char]$driveLetterCode)) {
			$availableMediaDriveLetterCount++
		}
	}
	if ($availableMediaDriveLetterCount -lt $deploymentMediaPartitionsToRelocate.Count) {
		throw 'There are not enough available drive letters to relocate the FFU deployment media.'
	}

	# Remove affected access paths first so internal and deployment-media letters can be reordered safely.
	foreach ($resolvedEntry in $resolvedEntries) {
		$currentDriveLetter = ([string]$resolvedEntry.Partition.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant()
		if ($currentDriveLetter -match '^[D-Z]$' -and $currentDriveLetter -ne [string]$resolvedEntry.RequestedDriveLetter) {
			Write-FFUDataPartitionDriveLetterLog "Removing drive ${currentDriveLetter}: from '$($resolvedEntry.ManifestEntry.Name)' before reassignment."
			Remove-PartitionAccessPath -DiskNumber $resolvedEntry.Partition.DiskNumber -PartitionNumber $resolvedEntry.Partition.PartitionNumber -AccessPath "${currentDriveLetter}:\" -ErrorAction Stop
		}
	}
	foreach ($deploymentMediaEntry in $deploymentMediaPartitionsToRelocate) {
		Write-FFUDataPartitionDriveLetterLog "Removing drive $($deploymentMediaEntry.DriveLetter): from FFU deployment media '$($deploymentMediaEntry.VolumeLabel)' before reassignment."
		Remove-PartitionAccessPath -DiskNumber $deploymentMediaEntry.Partition.DiskNumber -PartitionNumber $deploymentMediaEntry.Partition.PartitionNumber -AccessPath "$($deploymentMediaEntry.DriveLetter):\" -ErrorAction Stop
	}

	foreach ($resolvedEntry in $resolvedEntries) {
		$requestedDriveLetter = [string]$resolvedEntry.RequestedDriveLetter
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

	$mediaReservedDriveLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($driveLetterCode in ([int][char]'D')..([int][char]'Z')) {
		$driveLetter = [string][char]$driveLetterCode
		$letterOwners = @(Get-Partition -DriveLetter $driveLetter -ErrorAction SilentlyContinue)
		if ($letterOwners.Count -gt 0 -or $null -ne (Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
			$null = $mediaReservedDriveLetters.Add($driveLetter)
		}
	}
	foreach ($deploymentMediaEntry in $deploymentMediaPartitionsToRelocate) {
		$newDriveLetter = Get-FFUNextAvailableDriveLetter -ReservedDriveLetters $mediaReservedDriveLetters
		Write-FFUDataPartitionDriveLetterLog "Assigning drive ${newDriveLetter}: to FFU deployment media '$($deploymentMediaEntry.VolumeLabel)'."
		Set-Partition -DiskNumber $deploymentMediaEntry.Partition.DiskNumber -PartitionNumber $deploymentMediaEntry.Partition.PartitionNumber -NewDriveLetter $newDriveLetter -ErrorAction Stop
		$verifiedMediaPartition = Get-Partition -DiskNumber $deploymentMediaEntry.Partition.DiskNumber -PartitionNumber $deploymentMediaEntry.Partition.PartitionNumber -ErrorAction Stop
		if (([string]$verifiedMediaPartition.DriveLetter).Trim().TrimEnd(':').ToUpperInvariant() -ne $newDriveLetter) {
			throw "Drive letter verification failed for FFU deployment media '$($deploymentMediaEntry.VolumeLabel)'."
		}
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
