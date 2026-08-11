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

function Write-OK   { param([string]$m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-WARN { param([string]$m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-FAIL { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

function Exit-OnError {
    param([string]$Message)
    Write-FAIL $Message
    exit 1
}

# Template path relative to this script
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $ScriptDir "Transcribe\transcribe-two-trigger-stack.yaml"

# =============================================================================
# DESTROY MODE - tear down everything cleanly
# =============================================================================
if ($Destroy) {
    Write-Step "DESTROY MODE — Deleting stack and resources"

    Write-Host "Deleting CloudFormation stack: $StackName ..."
    aws cloudformation delete-stack --stack-name $StackName --region $Region
    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to initiate stack deletion." }

    Write-Host "Waiting for stack to be deleted (this can take 2-5 min)..."
    aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region
    if ($LASTEXITCODE -ne 0) {
        Write-WARN "Stack deletion wait timed out or failed. Check the AWS Console for status."
    } else {
        Write-OK "Stack deleted successfully."
    }

    Write-Host ""
    Write-WARN "The S3 bucket '$BucketName' was NOT deleted automatically."
    Write-WARN "If you want to delete it, empty it first then run:"
    Write-Host "  aws s3 rm s3://$BucketName --recursive" -ForegroundColor Yellow
    Write-Host "  aws s3api delete-bucket --bucket $BucketName --region $Region" -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# STEP 1 — Verify prerequisites
# =============================================================================
Write-Step "STEP 1 — Verify prerequisites"

# Check AWS CLI
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Exit-OnError "AWS CLI not found. Install it from https://aws.amazon.com/cli/"
}
Write-OK "AWS CLI found"

# Check AWS credentials work
$AccountId = aws sts get-caller-identity --query Account --output text 2>&1
if ($LASTEXITCODE -ne 0) {
    Exit-OnError "AWS credentials not configured or not working. Run: aws configure"
}
Write-OK "AWS credentials valid — Account ID: $AccountId"

# Check template exists
if (-not (Test-Path $TemplatePath)) {
    Exit-OnError "CloudFormation template not found at: $TemplatePath"
}
Write-OK "CloudFormation template found: $TemplatePath"

# =============================================================================
# STEP 2 — Create the Transcribe service role (needed for Call Analytics)
# =============================================================================
Write-Step "STEP 2 — Create Amazon Transcribe service role for Call Analytics"

$TranscribeRoleName = "AmazonTranscribeServiceRole-cloudagetranscriberole"

# Check if role already exists
$ExistingRole = aws iam get-role --role-name $TranscribeRoleName --query "Role.RoleName" --output text 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Transcribe service role already exists: $TranscribeRoleName"
} else {
    Write-Host "Creating Transcribe service role: $TranscribeRoleName ..."

    # Trust policy for Amazon Transcribe
    $TrustPolicy = @{
        Version   = "2012-10-17"
        Statement = @(
            @{
                Effect    = "Allow"
                Principal = @{ Service = "transcribe.amazonaws.com" }
                Action    = "sts:AssumeRole"
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    # Write trust policy to a temp file (AWS CLI needs a file or JSON string)
    $TrustPolicyFile = Join-Path $env:TEMP "transcribe-trust-policy.json"
    $TrustPolicy | Out-File -Encoding utf8 -FilePath $TrustPolicyFile

    aws iam create-role `
        --role-name $TranscribeRoleName `
        --assume-role-policy-document "file://$TrustPolicyFile" `
        --description "Allows Amazon Transcribe to access S3 for Call Analytics" `
        --path "/service-role/"

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create Transcribe service role." }

    # Attach S3 full access to let Transcribe read/write your bucket
    aws iam attach-role-policy `
        --role-name $TranscribeRoleName `
        --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to attach S3 policy to Transcribe role." }

    Write-OK "Transcribe service role created and S3 policy attached."
    Remove-Item $TrustPolicyFile -ErrorAction SilentlyContinue
}

# =============================================================================
# STEP 3 — Create the S3 bucket (if it doesn't exist)
# =============================================================================
Write-Step "STEP 3 — Create S3 bucket: $BucketName"

$BucketCheck = aws s3api head-bucket --bucket $BucketName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Bucket already exists: $BucketName"
} else {
    Write-Host "Creating S3 bucket: $BucketName in region $Region ..."

    if ($Region -eq "us-east-1") {
        # us-east-1 does NOT use --create-bucket-configuration
        aws s3api create-bucket --bucket $BucketName --region $Region
    } else {
        aws s3api create-bucket `
            --bucket $BucketName `
            --region $Region `
            --create-bucket-configuration LocationConstraint=$Region
    }

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create S3 bucket." }

    # Block all public access (security best practice)
    aws s3api put-public-access-block `
        --bucket $BucketName `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    Write-OK "Bucket created with public access blocked."
}

# =============================================================================
# STEP 4 — Validate the CloudFormation template
# =============================================================================
Write-Step "STEP 4 — Validate CloudFormation template"

aws cloudformation validate-template `
    --template-body "file://$TemplatePath" `
    --region $Region | Out-Null

if ($LASTEXITCODE -ne 0) { Exit-OnError "Template validation failed. Fix the YAML before deploying." }
Write-OK "Template is valid."

# =============================================================================
# STEP 5 — Deploy (create or update) the CloudFormation stack
# =============================================================================
Write-Step "STEP 5 — Deploy CloudFormation stack: $StackName"

Write-Host "Parameters:"
Write-Host "  ExistingBucketName          = $BucketName"
Write-Host "  LambdaExecutionRoleName     = cloudage"
Write-Host "  TranscribeDataAccessRoleName= $TranscribeRoleName"
Write-Host "  StandardInputPrefix         = input/"
Write-Host "  AnalyticsInputPrefix        = analytics/"
Write-Host ""
Write-Host "Deploying... (this may take 3-5 minutes)" -ForegroundColor Yellow

aws cloudformation deploy `
    --template-file $TemplatePath `
    --stack-name $StackName `
    --region $Region `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        ExistingBucketName=$BucketName `
        LambdaExecutionRoleName=cloudage `
        TranscribeDataAccessRoleName=$TranscribeRoleName

if ($LASTEXITCODE -ne 0) { Exit-OnError "CloudFormation deploy failed. Check the AWS Console > CloudFormation > Events for details." }
Write-OK "Stack deployed successfully."

# =============================================================================
# STEP 6 — Verify stack outputs
# =============================================================================
Write-Step "STEP 6 — Verify stack outputs"

$Outputs = aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    --query "Stacks[0].Outputs" `
    --output table

Write-Host $Outputs
Write-OK "Stack outputs retrieved."

# =============================================================================
# STEP 7 — Verify S3 folders were created
# =============================================================================
Write-Step "STEP 7 — Verify S3 folders were created by the stack"

Write-Host "Listing top-level prefixes in s3://$BucketName ..."
aws s3 ls "s3://$BucketName/"

if ($LASTEXITCODE -ne 0) { Write-WARN "Could not list bucket contents. Check bucket permissions." }
else { Write-OK "Bucket contents listed above (input/, analytics/, output/ should be present)." }

# =============================================================================
# STEP 8 — Verify Lambda functions exist
# =============================================================================
Write-Step "STEP 8 — Verify Lambda functions"

$Functions = @(
    "$StackName-transcribe-trigger",
    "$StackName-transcribe-analytics-trigger",
    "$StackName-bucket-notification-manager",
    "$StackName-create-s3-folders"
)

foreach ($Fn in $Functions) {
    $State = aws lambda get-function-configuration `
        --function-name $Fn `
        --region $Region `
        --query "State" `
        --output text 2>&1

    if ($LASTEXITCODE -eq 0 -and $State -eq "Active") {
        Write-OK "Lambda active: $Fn"
    } else {
        Write-WARN "Lambda not found or not active: $Fn (State: $State)"
    }
}

# =============================================================================
# STEP 9 — Quick smoke test: invoke the standard Transcribe Lambda
# =============================================================================
Write-Step "STEP 9 — Smoke test: invoke standard Transcribe Lambda"

$TestPayload = @{
    Records = @(
        @{
            s3 = @{
                bucket = @{ name = $BucketName }
                object = @{ key  = "input/test-file.mp3" }
            }
        }
    )
} | ConvertTo-Json -Depth 5 -Compress

# Encode payload to base64 (required by AWS CLI on Windows)
$PayloadBytes  = [System.Text.Encoding]::UTF8.GetBytes($TestPayload)
$PayloadBase64 = [Convert]::ToBase64String($PayloadBytes)

$ResponseFile = Join-Path $env:TEMP "lambda-smoke-test-response.json"

aws lambda invoke `
    --function-name "$StackName-transcribe-trigger" `
    --region $Region `
    --payload $PayloadBase64 `
    --cli-binary-format raw-in-base64-out `
    $ResponseFile | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-WARN "Lambda invocation failed. The file 'test-file.mp3' doesn't exist in S3, so a 'not found' error from Transcribe is normal."
} else {
    $Response = Get-Content $ResponseFile -Raw
    Write-Host "Lambda response: $Response"
    Write-OK "Lambda invoked successfully (Transcribe may error because test-file.mp3 doesn't exist — that is expected)."
}
Remove-Item $ResponseFile -ErrorAction SilentlyContinue

# =============================================================================
# STEP 10 — Upload a real audio file and check results (optional)
# =============================================================================
Write-Step "STEP 10 — Upload sample audio files (optional manual step)"

Write-Host @"
To test the full pipeline, upload one of the sample audio files:

  Standard transcription (mono audio -> input/ folder):
    aws s3 cp "Transcribe\On_Mono_Channel\transcribe_1.mp3" s3://$BucketName/input/transcribe_1.mp3

  Call analytics (stereo audio -> analytics/ folder):
    aws s3 cp "Transcribe\On_2_Channels\InboundCall.mp3" s3://$BucketName/analytics/InboundCall.mp3

Then check job status:
  aws transcribe list-transcription-jobs --status IN_PROGRESS --region $Region
  aws transcribe list-call-analytics-jobs --status IN_PROGRESS --region $Region

Results will appear in:
  s3://$BucketName/output/results/         (standard)
  s3://$BucketName/output/results/analytics/  (analytics)
"@ -ForegroundColor White

# =============================================================================
# STEP 11 — Create Glue IAM Role
# =============================================================================
Write-Step "STEP 11 — Create Glue IAM Role"

$GlueRoleName = "AWSGlueServiceRole-transcribe"

$ExistingGlueRole = aws iam get-role --role-name $GlueRoleName --query "Role.RoleName" --output text 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Glue IAM role already exists: $GlueRoleName"
} else {
    Write-Host "Creating Glue IAM role: $GlueRoleName ..."

    $GlueTrustPolicy = @{
        Version   = "2012-10-17"
        Statement = @(
            @{
                Effect    = "Allow"
                Principal = @{ Service = "glue.amazonaws.com" }
                Action    = "sts:AssumeRole"
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    $GlueTrustFile = Join-Path $env:TEMP "glue-trust-policy.json"
    $GlueTrustPolicy | Out-File -Encoding utf8 -FilePath $GlueTrustFile

    aws iam create-role `
        --role-name $GlueRoleName `
        --assume-role-policy-document "file://$GlueTrustFile" `
        --description "Allows AWS Glue to access S3 Transcribe output"

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create Glue IAM role." }

    aws iam attach-role-policy `
        --role-name $GlueRoleName `
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to attach AWSGlueServiceRole policy." }

    aws iam attach-role-policy `
        --role-name $GlueRoleName `
        --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to attach AmazonS3ReadOnlyAccess policy." }

    Remove-Item $GlueTrustFile -ErrorAction SilentlyContinue
    Write-OK "Glue IAM role created with Glue + S3 read policies attached."
}

# =============================================================================
# STEP 12 — Create Glue Database
# =============================================================================
Write-Step "STEP 12 — Create Glue Database"

$GlueDb = "transcribe_output_db"

$ExistingDb = aws glue get-database --name $GlueDb --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Glue database already exists: $GlueDb"
} else {
    Write-Host "Creating Glue database: $GlueDb ..."

    aws glue create-database `
        --region $Region `
        --database-input "{`"Name`":`"$GlueDb`",`"Description`":`"Glue database for Amazon Transcribe JSON output`"}"

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create Glue database." }
    Write-OK "Glue database created: $GlueDb"
}

# =============================================================================
# STEP 13 — Create Glue Crawlers
# =============================================================================
Write-Step "STEP 13 — Create Glue Crawlers"

# --- Standard Transcription Crawler ---
$StandardCrawler = "transcribe-standard-crawler"

$ExistingStdCrawler = aws glue get-crawler --name $StandardCrawler --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Standard crawler already exists: $StandardCrawler"
} else {
    Write-Host "Creating standard transcription crawler: $StandardCrawler ..."

    $StdTargets = @{
        S3Targets = @(
            @{
                Path       = "s3://$BucketName/output/results/"
                Exclusions = @("analytics/**", "*.temp")
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    $StdTargetsFile = Join-Path $env:TEMP "std-crawler-targets.json"
    $StdTargets | Out-File -Encoding utf8 -FilePath $StdTargetsFile

    aws glue create-crawler `
        --region $Region `
        --name $StandardCrawler `
        --role $GlueRoleName `
        --database-name $GlueDb `
        --description "Crawls standard transcription JSON output" `
        --targets "file://$StdTargetsFile" `
        --schema-change-policy "{`"UpdateBehavior`":`"UPDATE_IN_DATABASE`",`"DeleteBehavior`":`"LOG`"}" `
        --recrawl-policy "{`"RecrawlBehavior`":`"CRAWL_NEW_FOLDERS_ONLY`"}"

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create standard crawler." }
    Remove-Item $StdTargetsFile -ErrorAction SilentlyContinue
    Write-OK "Standard crawler created: $StandardCrawler"
}

# --- Call Analytics Crawler ---
$AnalyticsCrawler = "transcribe-analytics-crawler"

$ExistingAnaCrawler = aws glue get-crawler --name $AnalyticsCrawler --region $Region 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "Analytics crawler already exists: $AnalyticsCrawler"
} else {
    Write-Host "Creating call analytics crawler: $AnalyticsCrawler ..."

    $AnaTargets = @{
        S3Targets = @(
            @{
                Path       = "s3://$BucketName/output/results/analytics/analytics/"
                Exclusions = @("*.temp")
            }
        )
    } | ConvertTo-Json -Depth 5 -Compress

    $AnaTargetsFile = Join-Path $env:TEMP "ana-crawler-targets.json"
    $AnaTargets | Out-File -Encoding utf8 -FilePath $AnaTargetsFile

    aws glue create-crawler `
        --region $Region `
        --name $AnalyticsCrawler `
        --role $GlueRoleName `
        --database-name $GlueDb `
        --description "Crawls call analytics JSON output" `
        --targets "file://$AnaTargetsFile" `
        --schema-change-policy "{`"UpdateBehavior`":`"UPDATE_IN_DATABASE`",`"DeleteBehavior`":`"LOG`"}" `
        --recrawl-policy "{`"RecrawlBehavior`":`"CRAWL_NEW_FOLDERS_ONLY`"}"

    if ($LASTEXITCODE -ne 0) { Exit-OnError "Failed to create analytics crawler." }
    Remove-Item $AnaTargetsFile -ErrorAction SilentlyContinue
    Write-OK "Analytics crawler created: $AnalyticsCrawler"
}

# =============================================================================
# STEP 14 — Run the Crawlers
# =============================================================================
Write-Step "STEP 14 — Run Glue Crawlers"

Write-Host "Starting standard crawler: $StandardCrawler ..."
aws glue start-crawler --name $StandardCrawler --region $Region
if ($LASTEXITCODE -ne 0) {
    Write-WARN "Could not start standard crawler — it may already be running."
} else {
    Write-OK "Standard crawler started."
}

Write-Host "Starting analytics crawler: $AnalyticsCrawler ..."
aws glue start-crawler --name $AnalyticsCrawler --region $Region
if ($LASTEXITCODE -ne 0) {
    Write-WARN "Could not start analytics crawler — it may already be running."
} else {
    Write-OK "Analytics crawler started."
}

# Poll until both crawlers finish (max 3 minutes)
Write-Host "Waiting for crawlers to finish (up to 3 minutes)..." -ForegroundColor Yellow
$MaxWait  = 180
$Interval = 15
$Elapsed  = 0

while ($Elapsed -lt $MaxWait) {
    Start-Sleep -Seconds $Interval
    $Elapsed += $Interval

    $StdState = aws glue get-crawler --name $StandardCrawler --region $Region `
        --query "Crawler.State" --output text 2>&1
    $AnaState = aws glue get-crawler --name $AnalyticsCrawler --region $Region `
        --query "Crawler.State" --output text 2>&1

    Write-Host "  [$Elapsed s] Standard: $StdState | Analytics: $AnaState"

    if ($StdState -eq "READY" -and $AnaState -eq "READY") {
        Write-OK "Both crawlers completed."
        break
    }
}

if ($StdState -ne "READY" -or $AnaState -ne "READY") {
    Write-WARN "Crawlers still running after $MaxWait seconds. Check AWS Console > Glue > Crawlers."
}

# =============================================================================
# STEP 15 — Verify Glue Tables and Set Up Athena
# =============================================================================
Write-Step "STEP 15 — Verify Glue Tables and Set Up Athena"

Write-Host "Glue tables created in database '$GlueDb':"
aws glue get-tables `
    --database-name $GlueDb `
    --region $Region `
    --query "TableList[].{Name:Name,Location:StorageDescriptor.Location}" `
    --output table

# Create Athena results folder
Write-Host "Creating Athena results prefix in S3..."
aws s3api put-object --bucket $BucketName --key "athena-results/" | Out-Null
Write-OK "Athena results folder ready: s3://$BucketName/athena-results/"

Write-Host ""
Write-Host "Sample Athena queries to run in the AWS Console (Athena > Query Editor):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  -- Standard transcription: get all transcript text" -ForegroundColor White
Write-Host "  SELECT results.transcripts FROM transcribe_output_db.results LIMIT 10;" -ForegroundColor Yellow
Write-Host ""
Write-Host "  -- Call analytics: get CUSTOMER utterances with negative sentiment" -ForegroundColor White
Write-Host "  SELECT item.content, item.sentiment" -ForegroundColor Yellow
Write-Host "  FROM transcribe_output_db.analytics_analytics" -ForegroundColor Yellow
Write-Host "  CROSS JOIN UNNEST(transcript) AS t(item)" -ForegroundColor Yellow
Write-Host "  WHERE item.participantrole = 'CUSTOMER'" -ForegroundColor Yellow
Write-Host "  AND item.sentiment = 'NEGATIVE';" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Set Athena output to: s3://$BucketName/athena-results/" -ForegroundColor Cyan

# =============================================================================
# DONE
# =============================================================================
Write-Step "DEPLOYMENT COMPLETE"
Write-Host @"
Summary
-------
  Stack name    : $StackName
  Region        : $Region
  S3 Bucket     : $BucketName
  Account ID    : $AccountId

  Lambdas deployed:
    - $StackName-transcribe-trigger            (mono audio  -> input/)
    - $StackName-transcribe-analytics-trigger  (stereo audio -> analytics/)

  Glue resources:
    - Database  : $GlueDb
    - Crawlers  : $StandardCrawler
                  $AnalyticsCrawler
    - Athena output : s3://$BucketName/athena-results/

  To delete everything later, run:
    .\deploy.ps1 -BucketName "$BucketName" -Destroy
"@ -ForegroundColor Green
