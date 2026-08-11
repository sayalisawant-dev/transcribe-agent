# =============================================================================
# AWS Audio Transcription Pipeline - End-to-End Manual Deployment Script
# =============================================================================
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - An AWS account with permissions to create IAM, S3, Lambda, CloudFormation
#   - PowerShell 5.1+ or PowerShell Core
#
# Usage:
#   .\deploy.ps1 -BucketName "your-unique-bucket-name"
#
# To tear down everything:
#   .\deploy.ps1 -BucketName "your-unique-bucket-name" -Destroy
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$BucketName,

    [Parameter(Mandatory = $false)]
    [string]$Region = "us-east-1",

    [Parameter(Mandatory = $false)]
    [string]$StackName = "transcribe-two-trigger-stack",

    [Parameter(Mandatory = $false)]
    [switch]$Destroy
)

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-OK   { param([string]$m) Write-Host "[OK]   $m" -ForegroundColor Green }
function Write-WARN { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-FAIL { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

function Exit-OnError {
    param([string]$Message)
    Write-FAIL $Message
    exit 1
}

# Paths relative to this script
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $ScriptDir "Transcribe\transcribe-two-trigger-stack.yaml"
$FnStandard   = Join-Path $ScriptDir "Transcribe\TranscribeFunction"
$FnAnalytics  = Join-Path $ScriptDir "Transcribe\TranscribeAnalyticsFunction"

$TranscribeRoleName = "AmazonTranscribeServiceRole-cloudagetranscriberole"
$LambdaRoleName     = "cloudage"

# =============================================================================
# DESTROY MODE
# =============================================================================
if ($Destroy) {
    Write-Step "DESTROY MODE — Deleting stack and resources"

    aws cloudformation delete-stack --stack-name $StackName --region $Region
    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to initiate stack deletion." }

    Write-Host "Waiting for stack deletion (2-5 min)..."
    aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region
    if ($LASTEXITCODE -ne 0) {
        Write-WARN "Stack deletion wait timed out. Check the AWS Console."
    } else {
        Write-OK "Stack deleted."
    }

    Write-Host ""
    Write-WARN "Bucket '$BucketName' was NOT deleted (data preserved)."
    Write-WARN "To delete it manually:"
    Write-Host "  aws s3 rm s3://$BucketName --recursive" -ForegroundColor Yellow
    Write-Host "  aws s3api delete-bucket --bucket $BucketName --region $Region" -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# STEP 1 — Verify prerequisites
# =============================================================================
Write-Step "STEP 1 — Verify prerequisites"

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Exit-OnError "AWS CLI not found. Install it from https://aws.amazon.com/cli/"
}
Write-OK "AWS CLI found"

$AccountId = aws sts get-caller-identity --query Account --output text 2>&1
if ($LASTEXITCODE -ne 0) {
    Exit-OnError "AWS credentials not working. Run: aws configure"
}
Write-OK "AWS credentials valid — Account ID: $AccountId"

if (-not (Test-Path $TemplatePath)) {
    Exit-OnError "CloudFormation template not found at: $TemplatePath"
}
Write-OK "CloudFormation template found"

if (-not (Test-Path $FnStandard)) {
    Exit-OnError "TranscribeFunction source not found at: $FnStandard"
}
if (-not (Test-Path $FnAnalytics)) {
    Exit-OnError "TranscribeAnalyticsFunction source not found at: $FnAnalytics"
}
Write-OK "Lambda source files found"

# =============================================================================
# STEP 2 — Create the Transcribe service role (needed for Call Analytics)
# =============================================================================
Write-Step "STEP 2 — Transcribe service role for Call Analytics"

$ExistingRole = aws iam get-role --role-name $TranscribeRoleName --query "Role.RoleName" --output text 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Role already exists: $TranscribeRoleName"
} else {
    Write-Host "Creating role: $TranscribeRoleName ..."

    $TrustPolicyFile = Join-Path $env:TEMP "transcribe-trust-policy.json"
    @"
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "transcribe.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
"@ | Out-File -Encoding utf8 -FilePath $TrustPolicyFile

    aws iam create-role `
        --role-name $TranscribeRoleName `
        --assume-role-policy-document "file://$TrustPolicyFile" `
        --description "Allows Amazon Transcribe Call Analytics to access S3" `
        --path "/service-role/"

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create Transcribe service role." }
    Remove-Item $TrustPolicyFile -ErrorAction SilentlyContinue
    Write-OK "Role created."
}

# Ensure S3FullAccess is attached (idempotent)
aws iam attach-role-policy `
    --role-name $TranscribeRoleName `
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>&1 | Out-Null
Write-OK "AmazonS3FullAccess attached to Transcribe service role."

# =============================================================================
# STEP 3 — Create S3 bucket (skip if exists)
# =============================================================================
Write-Step "STEP 3 — S3 bucket: $BucketName"

aws s3api head-bucket --bucket $BucketName 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-OK "Bucket already exists: $BucketName"
} else {
    Write-Host "Creating bucket $BucketName in $Region ..."
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $BucketName --region $Region
    } else {
        aws s3api create-bucket `
            --bucket $BucketName --region $Region `
            --create-bucket-configuration LocationConstraint=$Region
    }
    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create S3 bucket." }

    aws s3api put-public-access-block `
        --bucket $BucketName `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    Write-OK "Bucket created with public access blocked."
}

# =============================================================================
# STEP 4 — Validate CloudFormation template
# =============================================================================
Write-Step "STEP 4 — Validate CloudFormation template"

aws cloudformation validate-template `
    --template-body "file://$TemplatePath" `
    --region $Region | Out-Null

if ($LASTEXITCODE -ne 0) { Exit-OnError "Template validation failed." }
Write-OK "Template is valid."

# =============================================================================
# STEP 5 — Deploy the CloudFormation stack
# =============================================================================
Write-Step "STEP 5 — Deploy CloudFormation stack: $StackName"

Write-Host "  ExistingBucketName           = $BucketName"
Write-Host "  LambdaExecutionRoleName      = $LambdaRoleName"
Write-Host "  TranscribeDataAccessRoleName = $TranscribeRoleName"
Write-Host ""
Write-Host "Deploying... (3-5 minutes)" -ForegroundColor Yellow

aws cloudformation deploy `
    --template-file $TemplatePath `
    --stack-name $StackName `
    --region $Region `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        ExistingBucketName=$BucketName `
        LambdaExecutionRoleName=$LambdaRoleName `
        TranscribeDataAccessRoleName=$TranscribeRoleName

if ($LASTEXITCODE -ne 0) { Exit-OnError "CloudFormation deploy failed. Check AWS Console > CloudFormation > Events." }
Write-OK "Stack deployed."

# =============================================================================
# STEP 6 — Fix IAM: attach AmazonTranscribeFullAccess + inline PassRole
#           (CloudFormation policy uses resource-scoped Transcribe ARNs which
#            StartCallAnalyticsJob does not honour — needs wildcard resource)
# =============================================================================
Write-Step "STEP 6 — Fix IAM permissions on Lambda execution role"

# Attach AmazonTranscribeFullAccess (wildcard resource, needed for Call Analytics)
aws iam attach-role-policy `
    --role-name $LambdaRoleName `
    --policy-arn arn:aws:iam::aws:policy/AmazonTranscribeFullAccess 2>&1 | Out-Null
Write-OK "AmazonTranscribeFullAccess attached to $LambdaRoleName."

# Add inline PassRole policy without Condition (the managed policy PassRole
# has iam:PassedToService condition which Transcribe Call Analytics ignores)
$PassRoleDoc = @"
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "iam:PassRole",
    "Resource": "arn:aws:iam::${AccountId}:role/service-role/${TranscribeRoleName}"
  }]
}
"@
$PassRoleFile = Join-Path $env:TEMP "passrole-inline.json"
$PassRoleDoc | Out-File -Encoding utf8 -FilePath $PassRoleFile

aws iam put-role-policy `
    --role-name $LambdaRoleName `
    --policy-name PassRoleToTranscribeInline `
    --policy-document "file://$PassRoleFile"

if ($LASTEXITCODE -ne 0) { Write-WARN "Could not set inline PassRole policy — check manually." }
else { Write-OK "Inline PassRole policy applied to $LambdaRoleName." }
Remove-Item $PassRoleFile -ErrorAction SilentlyContinue

# =============================================================================
# STEP 7 — Redeploy Lambda functions from the fixed source files
#           (ensures no hardcoded ARNs — everything reads from env vars)
# =============================================================================
Write-Step "STEP 7 — Redeploy Lambda functions from source files"

function Deploy-Lambda {
    param([string]$FunctionName, [string]$SourceFile)

    $ZipPath = Join-Path $env:TEMP "$FunctionName.zip"
    $IdxPath = Join-Path $env:TEMP "index.py"

    Copy-Item $SourceFile $IdxPath -Force
    Compress-Archive -Path $IdxPath -DestinationPath $ZipPath -Force

    aws lambda update-function-code `
        --function-name $FunctionName `
        --zip-file "fileb://$ZipPath" `
        --region $Region | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-WARN "Failed to update $FunctionName — it may not exist yet (CloudFormation manages it)."
        return
    }

    # Wait for update to finish
    $retries = 0
    do {
        Start-Sleep -Seconds 3
        $updateStatus = aws lambda get-function-configuration `
            --function-name $FunctionName `
            --region $Region `
            --query "LastUpdateStatus" `
            --output text 2>&1
        $retries++
    } while ($updateStatus -eq "InProgress" -and $retries -lt 10)

    if ($updateStatus -eq "Successful") {
        Write-OK "$FunctionName updated successfully."
    } else {
        Write-WARN "$FunctionName update status: $updateStatus"
    }

    Remove-Item $ZipPath -ErrorAction SilentlyContinue
    Remove-Item $IdxPath -ErrorAction SilentlyContinue
}

Deploy-Lambda -FunctionName "$StackName-transcribe-trigger"           -SourceFile $FnStandard
Deploy-Lambda -FunctionName "$StackName-transcribe-analytics-trigger" -SourceFile $FnAnalytics

# =============================================================================
# STEP 8 — Verify S3 folders
# =============================================================================
Write-Step "STEP 8 — Verify S3 folder structure"

aws s3 ls "s3://$BucketName/"
if ($LASTEXITCODE -ne 0) { Write-WARN "Could not list bucket. Check permissions." }
else { Write-OK "Bucket listing above — input/, analytics/, output/ should be present." }

# =============================================================================
# STEP 9 — Verify Lambda functions are Active
# =============================================================================
Write-Step "STEP 9 — Verify Lambda functions"

$Functions = @(
    "$StackName-transcribe-trigger",
    "$StackName-transcribe-analytics-trigger",
    "$StackName-bucket-notification-manager",
    "$StackName-create-s3-folders"
)

foreach ($Fn in $Functions) {
    $State = aws lambda get-function-configuration `
        --function-name $Fn --region $Region --query "State" --output text 2>&1
    if ($LASTEXITCODE -eq 0 -and $State -eq "Active") {
        Write-OK "Active: $Fn"
    } else {
        Write-WARN "Not found or not active: $Fn (State: $State)"
    }
}

# =============================================================================
# STEP 10 — Smoke test: invoke standard Lambda
# =============================================================================
Write-Step "STEP 10 — Smoke test: invoke standard Transcribe Lambda"

$TestPayload   = '{"Records":[{"s3":{"bucket":{"name":"' + $BucketName + '"},"object":{"key":"input/smoke-test.mp3"}}}]}'
$PayloadBytes  = [System.Text.Encoding]::UTF8.GetBytes($TestPayload)
$PayloadBase64 = [Convert]::ToBase64String($PayloadBytes)
$ResponseFile  = Join-Path $env:TEMP "smoke-test-response.json"

aws lambda invoke `
    --function-name "$StackName-transcribe-trigger" `
    --region $Region `
    --payload $PayloadBase64 `
    --cli-binary-format raw-in-base64-out `
    $ResponseFile | Out-Null

if ($LASTEXITCODE -eq 0) {
    $Response = Get-Content $ResponseFile -Raw
    Write-Host "Lambda response: $Response"
    Write-OK "Lambda invoked. A 'file not found' error from Transcribe is expected for smoke-test.mp3."
} else {
    Write-WARN "Lambda invocation failed — check the function exists and is Active."
}
Remove-Item $ResponseFile -ErrorAction SilentlyContinue

# =============================================================================
# STEP 11 — Glue + Athena setup for querying output data
# =============================================================================
Write-Step "STEP 11 — Set up Glue database, crawler, and Athena workgroup"

$GlueDatabase    = "transcribe_pipeline_db"
$AthenaWorkgroup = "transcribe-workgroup"
$GlueCrawlerRole = "GlueTranscribeCrawlerRole"

# ── S3 folder for Athena query results ──────────────────────
aws s3api put-object --bucket $BucketName --key "athena-results/" 2>&1 | Out-Null
Write-OK "Athena results folder created: s3://$BucketName/athena-results/"

# ── Glue database ────────────────────────────────────────────
$DbExists = aws glue get-database --name $GlueDatabase --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Glue database already exists: $GlueDatabase"
} else {
    aws glue create-database `
        --region $Region `
        --database-input "{`"Name`":`"$GlueDatabase`",`"Description`":`"Glue database for Amazon Transcribe output data`"}"
    if ($LASTEXITCODE -ne 0) { Write-WARN "Could not create Glue database." }
    else { Write-OK "Glue database created: $GlueDatabase" }
}

# ── IAM role for Glue crawler ────────────────────────────────
$GlueRoleExists = aws iam get-role --role-name $GlueCrawlerRole 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Glue crawler role already exists: $GlueCrawlerRole"
} else {
    $GlueTrustFile = Join-Path $env:TEMP "glue-trust.json"
    @"
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "glue.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
"@ | Out-File -Encoding utf8 -FilePath $GlueTrustFile

    aws iam create-role `
        --role-name $GlueCrawlerRole `
        --assume-role-policy-document "file://$GlueTrustFile" `
        --description "Glue crawler role for Transcribe output" | Out-Null

    aws iam attach-role-policy --role-name $GlueCrawlerRole `
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole | Out-Null
    aws iam attach-role-policy --role-name $GlueCrawlerRole `
        --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess | Out-Null

    Remove-Item $GlueTrustFile -ErrorAction SilentlyContinue
    Write-OK "Glue crawler role created with AWSGlueServiceRole + AmazonS3FullAccess."
}

# ── Glue crawler for call analytics output ───────────────────
$CrawlerExists = aws glue get-crawler --name "analytics-transcripts-crawler" --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Analytics crawler already exists — running it to refresh schema..."
} else {
    aws glue create-crawler `
        --region $Region `
        --name "analytics-transcripts-crawler" `
        --role $GlueCrawlerRole `
        --database-name $GlueDatabase `
        --targets "{`"S3Targets`":[{`"Path`":`"s3://$BucketName/output/results/analytics/`",`"Exclusions`":[`"*.temp`"]}]}" `
        --table-prefix "cal_" `
        --configuration "{`"Version`":1.0,`"Grouping`":{`"TableGroupingPolicy`":`"CombineCompatibleSchemas`"}}" `
        --schema-change-policy "{`"UpdateBehavior`":`"UPDATE_IN_DATABASE`",`"DeleteBehavior`":`"LOG`"}" | Out-Null
    Write-OK "Analytics crawler created."
}

aws glue start-crawler --name "analytics-transcripts-crawler" --region $Region 2>&1 | Out-Null
Write-OK "Analytics crawler started."

# ── Athena workgroup ─────────────────────────────────────────
$WgExists = aws athena get-work-group --work-group $AthenaWorkgroup --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Athena workgroup already exists: $AthenaWorkgroup"
} else {
    $WgConfig = "{`"ResultConfiguration`":{`"OutputLocation`":`"s3://$BucketName/athena-results/`"},`"EnforceWorkGroupConfiguration`":true,`"PublishCloudWatchMetricsEnabled`":false}"
    aws athena create-work-group `
        --region $Region `
        --name $AthenaWorkgroup `
        --configuration $WgConfig `
        --description "Workgroup for querying Transcribe output" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-WARN "Could not create Athena workgroup." }
    else { Write-OK "Athena workgroup created: $AthenaWorkgroup" }
}

# ── Create std_transcripts table via Athena DDL ───────────────
Write-Host "Creating std_transcripts table via DDL (skipped if exists)..."
$DdlSql = "CREATE EXTERNAL TABLE IF NOT EXISTS ${GlueDatabase}.std_transcripts (jobName string, accountId string, status string, results struct<language_code:string,transcripts:array<struct<transcript:string>>,items:array<struct<id:int,type:string,start_time:string,end_time:string,alternatives:array<struct<content:string,confidence:string>>>>,audio_segments:array<struct<id:int,transcript:string,start_time:string,end_time:string>>>) ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe' WITH SERDEPROPERTIES ('ignore.malformed.json'='true') STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat' OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat' LOCATION 's3://$BucketName/output/results/' TBLPROPERTIES ('skip.header.line.count'='0')"

$DdlId = aws athena start-query-execution `
    --region $Region `
    --work-group $AthenaWorkgroup `
    --query-string $DdlSql `
    --query "QueryExecutionId" --output text 2>&1

if ($LASTEXITCODE -eq 0) {
    Start-Sleep -Seconds 10
    $DdlState = aws athena get-query-execution `
        --query-execution-id $DdlId `
        --region $Region `
        --query "QueryExecution.Status.State" --output text 2>&1
    if ($DdlState -eq "SUCCEEDED") {
        Write-OK "std_transcripts table created in Glue catalog."
    } else {
        Write-WARN "DDL query state: $DdlState — check Athena console if table is missing."
    }
} else {
    Write-WARN "Could not submit DDL query — create std_transcripts table manually in Athena."
}

# ── Wait for analytics crawler to finish ─────────────────────
Write-Host "Waiting 90s for analytics crawler to finish..."
Start-Sleep -Seconds 90
$CrawlerState = aws glue get-crawler --name "analytics-transcripts-crawler" --region $Region `
    --query "Crawler.LastCrawl.Status" --output text 2>&1
Write-OK "Analytics crawler last status: $CrawlerState"

# Verify both tables exist
Write-Host ""
Write-Host "Glue catalog tables:" -ForegroundColor Cyan
aws glue get-tables --database-name $GlueDatabase --region $Region `
    --query "TableList[*].{Table:Name,Location:StorageDescriptor.Location}" --output table

# =============================================================================
# STEP 12 — Upload sample files and verify end-to-end
# =============================================================================
Write-Step "STEP 12 — Upload sample audio files to test the full pipeline"

Write-Host @"
Run these to trigger a real transcription:

  Standard transcription (mono -> input/):
    aws s3 cp "Transcribe\On_Mono_Channel\transcribe_1.mp3" s3://$BucketName/input/transcribe_1.mp3

  Call Analytics (stereo -> analytics/):
    aws s3 cp "Transcribe\On_2_Channels\InboundCall.mp3" s3://$BucketName/analytics/InboundCall.mp3

Then check job status (jobs complete in 1-3 min):
  aws transcribe list-transcription-jobs  --region $Region
  aws transcribe list-call-analytics-jobs --region $Region

Results appear in:
  s3://$BucketName/output/results/            (standard)
  s3://$BucketName/output/results/analytics/  (call analytics)

View results in the Streamlit UI:
  streamlit run app.py
"@ -ForegroundColor White

# =============================================================================
# DONE
# =============================================================================
Write-Step "DEPLOYMENT COMPLETE"
Write-Host @"
Summary
-------
  Stack      : $StackName
  Region     : $Region
  S3 Bucket  : $BucketName
  Account ID : $AccountId

  Lambda execution role : $LambdaRoleName
    Policies: AWSLambdaBasicExecutionRole
              AmazonTranscribeFullAccess
              transcribe-two-trigger-stack-transcribe-access-policy
              PassRoleToTranscribeInline (inline)

  Transcribe service role : $TranscribeRoleName
    Policies: AmazonS3FullAccess

  Lambdas:
    $StackName-transcribe-trigger           (input/  -> standard transcription)
    $StackName-transcribe-analytics-trigger (analytics/ -> call analytics)

  Glue / Athena:
    Database  : $GlueDatabase
    Tables    : std_transcripts (standard output)
                cal_analytics   (call analytics output)
    Workgroup : $AthenaWorkgroup
    Results   : s3://$BucketName/athena-results/

  Streamlit UI:
    streamlit run app.py
    Open http://localhost:8501 → Athena Query tab

  To destroy all resources:
    .\deploy.ps1 -BucketName "$BucketName" -Destroy
"@ -ForegroundColor Green
