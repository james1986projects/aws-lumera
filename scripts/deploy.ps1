Param(
  [string]$Region = "eu-west-2",
  [string]$ProjectName = "lumera-demo",
  [string]$Environment = "dev",
  [string]$DBUsername = "appuser",
  [string]$SnsEmail,          # pass on the command line or via env var / prompt
  [securestring]$DBPassword,  # prefer secure prompt or env var, not hard-coded
  [bool]$DetailedMonitoring = $false,  # true => 60s alarm period; false => 300s
  [int]$CpuThreshold = 70
)

# Helpers

function ConvertTo-CFNParams {
  param([hashtable]$Map)
  $Map.GetEnumerator() | ForEach-Object {
    New-Object Amazon.CloudFormation.Model.Parameter -Property @{
      ParameterKey   = $_.Key
      ParameterValue = [string]$_.Value
    }
  }
}

function Get-PlainText {
  param([securestring]$Sec)
  if (-not $Sec) { return $null }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Sec)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
}

function Wait-Stack {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [string]$Region = $Region,
    [int]$PollSeconds = 10,
    [int]$MaxMinutes = 60
  )

  $start = Get-Date
  $terminalSuccess = @('CREATE_COMPLETE','UPDATE_COMPLETE')
  $terminalFailure = @(
    'ROLLBACK_COMPLETE','UPDATE_ROLLBACK_COMPLETE',
    'DELETE_COMPLETE','ROLLBACK_FAILED','CREATE_FAILED','UPDATE_ROLLBACK_FAILED'
  )
  $terminal = $terminalSuccess + $terminalFailure

  Write-Host "Waiting for stack $Name ..."
  while ($true) {
    $stack = Get-CFNStack -StackName $Name -Region $Region -ErrorAction SilentlyContinue
    if (-not $stack) { Start-Sleep -Seconds $PollSeconds; continue }

    $status = $stack.StackStatus
    $elapsed = (Get-Date) - $start
    Write-Host ("  {0}  [{1:mm\:ss}]" -f $status,$elapsed)

    if ($terminal -contains $status) {
      if ($terminalSuccess -contains $status) {
        Write-Host "✅ $Name reached $status"
        return
      } else {
        Write-Warning "❌ $Name ended in $status"
        Write-Host "Last few events:"
        Get-CFNStackEvents -StackName $Name -Region $Region |
          Select-Object -First 12 Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason |
          Format-Table -AutoSize
        throw "Stack $Name failed with status $status"
      }
    }

    if ($elapsed.TotalMinutes -ge $MaxMinutes) {
      Write-Warning "⏱️ Timed out after $([int]$elapsed.TotalMinutes)m waiting for $Name"
      Get-CFNStackEvents -StackName $Name -Region $Region |
        Select-Object -First 12 Timestamp,ResourceStatus,LogicalResourceId,ResourceStatusReason |
        Format-Table -AutoSize
      throw "Timeout waiting for $Name"
    }

    Start-Sleep -Seconds $PollSeconds
  }
}

function New-OrSkipStack {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$TemplatePath,
    [hashtable]$Parameters = @{},
    [string[]]$Capabilities = @()
  )

  # 1) Validate template
  Test-CFNTemplate -TemplateBody (Get-Content $TemplatePath -Raw) -Region $Region | Out-Null

  # 2) Lookup stack safely
  $existing = $null
  try { $existing = Get-CFNStack -StackName $Name -Region $Region -ErrorAction Stop } catch { $existing = $null }

  if ($existing) {
    $status = $existing.StackStatus
    if ($status -like '*IN_PROGRESS') {
      Write-Host "Stack $Name is in progress, waiting..."
      Wait-Stack -Name $Name -Region $Region
      return
    }
    if ($status -in @('CREATE_COMPLETE','UPDATE_COMPLETE')) {
      Write-Host "↪️  $Name already $status — skipping create"
      return
    }
    Write-Warning "Stack $Name exists with status $status. Delete it if you need to recreate."
    throw "Cannot proceed with $Name in state $status"
  }

  # 3) Create & wait
  Write-Host "Creating stack $Name ..."
  $cfArgs = @{
    StackName    = $Name
    Region       = $Region
    TemplateBody = (Get-Content $TemplatePath -Raw)
    Parameter    = (ConvertTo-CFNParams $Parameters)
    OnFailure    = "ROLLBACK"
  }
  if ($Capabilities -and $Capabilities.Count -gt 0) { $cfArgs.Capabilities = $Capabilities }

  New-CFNStack @cfArgs | Out-Null
  Wait-Stack -Name $Name -Region $Region
}

# Script Start

$ErrorActionPreference = "Stop"
Import-Module AWSPowerShell -ErrorAction Stop

# Fallbacks/prompts for inputs
if (-not $SnsEmail) { $SnsEmail = $env:LUMERA_SNS_EMAIL }
if (-not $SnsEmail) { $SnsEmail = Read-Host "Enter SNS email for alerts" }

if (-not $DBPassword) {
  $envPwd = $env:LUMERA_DB_PASSWORD
  if ($envPwd) {
    $DBPassword = (ConvertTo-SecureString $envPwd -AsPlainText -Force)
  } else {
    $DBPassword = Read-Host "Enter RDS master password (input hidden)" -AsSecureString
  }
}
$DBPasswordPlain = Get-PlainText $DBPassword

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $root "..")

# 1) VPC (no NAT; with VPC endpoints)
$vpcStack = "$ProjectName-$Environment-vpc"
New-OrSkipStack -Name $vpcStack -TemplatePath (Join-Path $repo "templates/vpc.yml") -Parameters @{
  ProjectName = $ProjectName; Environment = $Environment
}

# Read exports
$vpcId = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-VpcId"}).Value
$privateSubnetIds = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-PrivateSubnetIds"}).Value
$privateSubnetId = $privateSubnetIds.Split(',')[0]

# 2) S3 (artifacts/logs)
$s3Stack = "$ProjectName-$Environment-s3"
New-OrSkipStack -Name $s3Stack -TemplatePath (Join-Path $repo "templates/s3.yml") -Parameters @{
  ProjectName = $ProjectName; Environment = $Environment
}
$artifactBucket = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-ArtifactBucketName"}).Value

# 3) IAM (EC2 Instance Profile + Lambda role)
$iamStack = "$ProjectName-$Environment-iam"
New-OrSkipStack -Name $iamStack -TemplatePath (Join-Path $repo "templates/iam.yml") -Parameters @{
  ProjectName = $ProjectName; Environment = $Environment; ArtifactBucketName = $artifactBucket
} -Capabilities @("CAPABILITY_NAMED_IAM")
$instanceProfileName = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-EC2InstanceProfileName"}).Value
$lambdaRoleArn = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-LambdaRoleArn"}).Value

# 4) EC2 (private + SSM)  -- now exports InstanceId
$ec2Stack = "$ProjectName-$Environment-ec2"
$dmString = ($(if ($DetailedMonitoring) { 'true' } else { 'false' }))  # ec2.yml expects 'true'/'false'
New-OrSkipStack -Name $ec2Stack -TemplatePath (Join-Path $repo "templates/ec2.yml") -Parameters @{
  ProjectName=$ProjectName; Environment=$Environment; VpcId=$vpcId; PrivateSubnetId=$privateSubnetId; InstanceProfileName=$instanceProfileName;
  DetailedMonitoring=$dmString
}
$appInstanceId = (Get-CFNStack -StackName $ec2Stack -Region $Region).Outputs | Where-Object {$_.OutputKey -eq 'AppInstanceId'} | Select-Object -ExpandProperty OutputValue
$appSgId       = (Get-CFNStack -StackName $ec2Stack -Region $Region).Outputs | Where-Object {$_.OutputKey -eq 'AppSecurityGroupId'} | Select-Object -ExpandProperty OutputValue

# 5) RDS (private subnets; allow from app SG)
$rdsStack = "$ProjectName-$Environment-rds"
New-OrSkipStack -Name $rdsStack -TemplatePath (Join-Path $repo "templates/rds.yml") -Parameters @{
  ProjectName=$ProjectName; Environment=$Environment; VpcId=$vpcId; PrivateSubnetIds=$privateSubnetIds; AppSecurityGroupId=$appSgId;
  DBUsername=$DBUsername; DBPassword=$DBPasswordPlain
}

# Try to read DB identifier from stack outputs/exports (safe fallback if not present)
$dbId = $null
try {
  $dbId = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-DBInstanceIdentifier"}).Value
} catch {}
if (-not $dbId) {
  $dbId = (Get-CFNStack -StackName $rdsStack -Region $Region).Outputs |
    Where-Object { $_.OutputKey -match 'DBInstanceIdentifier|DbInstanceIdentifier' } |
    Select-Object -First 1 -ExpandProperty OutputValue
}

# 6) Package Lambda code and upload
$srcDir    = Join-Path $repo "lambda"
$lambdaZip = Join-Path $env:TEMP "ec2_status_logger.zip"

Remove-Item $lambdaZip -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $srcDir "ec2_status_logger.zip") -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $lambdaZip)

$lambdaKey = "lambda/ec2_status_logger.zip"
Write-S3Object -BucketName $artifactBucket -File $lambdaZip -Key $lambdaKey -Region $Region | Out-Null

# 7) Lambda function
$lambdaStack = "$ProjectName-$Environment-lambda"
New-OrSkipStack -Name $lambdaStack -TemplatePath (Join-Path $repo "templates/lambda.yml") -Parameters @{
  ProjectName=$ProjectName; Environment=$Environment; LambdaRoleArn=$lambdaRoleArn; ArtifactBucketName=$artifactBucket; LambdaZipKey=$lambdaKey
}
$lambdaArn = (Get-CFNExport -Region $Region | Where-Object {$_.Name -eq "$ProjectName-$Environment-LambdaArn"}).Value

# 8) CloudWatch alarm + SNS + schedule (imports InstanceId)
$cwStack = "$ProjectName-$Environment-cloudwatch"
$period = $(if ($DetailedMonitoring) { 60 } else { 300 })
New-OrSkipStack -Name $cwStack -TemplatePath (Join-Path $repo "templates/cloudwatch.yml") -Parameters @{
  ProjectName=$ProjectName; Environment=$Environment; LambdaArn=$lambdaArn; SnsEmail=$SnsEmail; CpuThreshold=$CpuThreshold; PeriodSeconds=$period
}

# 9) CloudWatch Dashboard
$dashboardStack = "$ProjectName-$Environment-dashboard"
if (-not $dbId) { Write-Warning "DBInstanceIdentifier not found in exports/outputs. Pass via manual parameter if widgets appear empty." }
New-OrSkipStack -Name $dashboardStack -TemplatePath (Join-Path $repo "templates/dashboard.yml") -Parameters @{
  ProjectName=$ProjectName; Environment=$Environment; DBInstanceIdentifier=$dbId; BucketName=$artifactBucket
}

Write-Host "`nDeployment complete!"
Write-Host "EC2 Instance ID (connect via SSM): $appInstanceId"
Write-Host "Artifacts bucket: $artifactBucket"
Write-Host "Dashboard: ${ProjectName}-${Environment}-service"
Write-Host "Reminder: confirm the SNS subscription email sent to $SnsEmail"
