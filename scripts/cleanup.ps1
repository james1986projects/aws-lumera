Param(
  [string]$Region = "eu-west-2",
  [string]$ProjectName = "lumera-demo",
  [string]$Environment = "dev"
)

$ErrorActionPreference = "Stop"

$prefix = "$ProjectName-$Environment"

# Consumers of EC2 exports (cloudwatch, dashboard) must delete BEFORE ec2.
$stacks = @(
  "$prefix-cloudwatch",
  "$prefix-dashboard",
  "$prefix-lambda",
  "$prefix-rds",
  "$prefix-ec2",
  "$prefix-s3",
  "$prefix-iam",
  "$prefix-vpc"
)

function StackExists($name) {
  try { Get-CFNStack -StackName $name -Region $Region | Out-Null; return $true }
  catch { return $false }
}

function Clear-S3Bucket {
  param([Parameter(Mandatory=$true)][string]$BucketName)

  Write-Host "  Emptying s3://${BucketName} ..."
  aws s3 rm "s3://$BucketName" --recursive --region $Region | Out-Null

  try {
    $hasMore = $true
    $keyMarker = $null
    $versionMarker = $null
    while ($hasMore) {
      $listArgs = @("s3api","list-object-versions","--bucket",$BucketName,"--region",$Region,"--output","json")
      if ($keyMarker)     { $listArgs += @("--key-marker",$keyMarker) }
      if ($versionMarker) { $listArgs += @("--version-id-marker",$versionMarker) }
      $respJson = (aws @listArgs) 2>$null
      if (-not $respJson) { break }
      $resp = $respJson | ConvertFrom-Json

      $objects = @()
      if ($resp.Versions) { foreach ($v in $resp.Versions) { $objects += @{ Key=$v.Key; VersionId=$v.VersionId } } }
      if ($resp.DeleteMarkers) { foreach ($m in $resp.DeleteMarkers) { $objects += @{ Key=$m.Key; VersionId=$m.VersionId } } }

      if ($objects.Count -gt 0) {
        for ($i=0; $i -lt $objects.Count; $i+=1000) {
          $batch = $objects[$i..([Math]::Min($i+999, $objects.Count-1))]
          $deleteSpec = @{ Objects = $batch }
          $json = $deleteSpec | ConvertTo-Json -Compress
          aws s3api delete-objects --bucket $BucketName --region $Region --delete $json | Out-Null
        }
      }

      $hasMore = $false
      if ($resp.IsTruncated -eq $true) {
        $hasMore = $true
        $keyMarker = $resp.NextKeyMarker
        $versionMarker = $resp.NextVersionIdMarker
      }
    }
  } catch {
    Write-Warning "  Couldn't purge versions for ${BucketName}: ${_}"
  }
}

function EmptyS3BucketsInStack {
  param([Parameter(Mandatory=$true)][string]$StackName)

  try {
    $resources = Get-CFNStackResourceList -StackName $StackName -Region $Region
    $buckets = $resources | Where-Object { $_.ResourceType -eq "AWS::S3::Bucket" }
    foreach ($b in $buckets) {
      $bucketName = $b.PhysicalResourceId
      if ($bucketName) { Clear-S3Bucket -BucketName $bucketName }
    }
  } catch {
    Write-Warning "  Couldn't list resources for ${StackName}: ${_}"
  }
}

foreach ($s in $stacks) {
  if (-not (StackExists $s)) {
    Write-Host "Skipping ${s} (not found)."
    continue
  }

  Write-Host "Pre-clean for ${s} ..."
  EmptyS3BucketsInStack -StackName $s

  try {
    Write-Host "Deleting ${s} ..."
    Remove-CFNStack -StackName $s -Region $Region -Confirm:$false

    while ($true) {
      Start-Sleep -Seconds 8
      try {
        $st = Get-CFNStack -StackName $s -Region $Region
        $status = $st.StackStatus
        Write-Host "  Status: $status"
        if ($status -eq "DELETE_COMPLETE") { break }
        if ($status -like "*FAILED") {
          Write-Warning "${s} delete failed. Recent events:"
          Get-CFNStackEvent -StackName $s -Region $Region | Select-Object -First 15
          break
        }
      } catch {
        Write-Host "${s} deleted (stack not found)."
        break
      }
    }
  } catch {
    Write-Warning "Failed to delete ${s}: ${_}"
    try { Get-CFNStackEvent -StackName $s -Region $Region | Select-Object -First 15 } catch {}
  }
}

# Orphan cleanup
Write-Host "Orphan cleanup with prefix '$prefix' ..."

try {
  $alarmsJson = aws cloudwatch describe-alarms --region $Region --output json
  $alarms = ($alarmsJson | ConvertFrom-Json).MetricAlarms | Where-Object {
    $_.AlarmName -like "*$prefix*"
  }
  if ($alarms) {
    $names = $alarms.AlarmName
    Write-Host "  Deleting CloudWatch alarms: $($names -join ', ')"
    aws cloudwatch delete-alarms --alarm-names $names --region $Region | Out-Null
  } else {
    Write-Host "  No matching CloudWatch alarms."
  }
} catch {
  Write-Warning "  Couldn't enumerate/delete CloudWatch alarms: ${_}"
}

try {
  $topicsJson = aws sns list-topics --region $Region --output json
  $topics = ($topicsJson | ConvertFrom-Json).Topics | Where-Object {
    $_.TopicArn -like "*$prefix*"
  }
  if ($topics) {
    foreach ($t in $topics) {
      Write-Host "  Deleting SNS topic: $($t.TopicArn)"
      aws sns delete-topic --topic-arn $t.TopicArn --region $Region | Out-Null
    }
  } else {
    Write-Host "  No matching SNS topics."
  }
} catch {
  Write-Warning "  Couldn't enumerate/delete SNS topics: ${_}"
}

try {
  $logPrefix = "/aws/lambda/$prefix"
  $nextToken = $null
  $logGroups = @()
  do {
    $awsArgs = @("logs","describe-log-groups","--region",$Region,"--log-group-name-prefix",$logPrefix,"--output","json")
    if ($nextToken) { $awsArgs += @("--next-token",$nextToken) }
    $respJson = aws @awsArgs
    $resp = $respJson | ConvertFrom-Json
    if ($resp.logGroups) { $logGroups += $resp.logGroups }
    $nextToken = $resp.nextToken
  } while ($nextToken)

  if ($logGroups.Count -gt 0) {
    foreach ($lg in $logGroups) {
      $name = $lg.logGroupName
      Write-Host "  Deleting Log Group: $name"
      aws logs delete-log-group --log-group-name $name --region $Region | Out-Null
    }
  } else {
    Write-Host "  No matching CloudWatch Log Groups."
  }
} catch {
  Write-Warning "  Couldn't enumerate/delete CloudWatch Log Groups: ${_}"
}

Write-Host "Cleanup complete."

