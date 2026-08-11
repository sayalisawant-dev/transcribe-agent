# Tech Stack

## Runtime & Language
- **Python 3.12** — all Lambda functions and Streamlit UI
- **boto3** — AWS SDK for Python (S3, Transcribe, Athena, Glue clients)
- **botocore** — used for `ClientError` exception handling
- **streamlit >= 1.35.0** — web UI framework
- **pandas >= 1.4.0** — Athena query result rendering and CSV export

## AWS Services

| Service | Usage |
|---------|-------|
| **AWS Lambda** | Event-driven compute for standard and analytics transcription triggers |
| **Amazon S3** | Audio file ingestion (`input/`, `analytics/`), transcription output (`output/results/`), Athena query results (`athena-results/`) |
| **Amazon Transcribe** | `StartTranscriptionJob` (standard mono) and `StartCallAnalyticsJob` (stereo call analytics) |
| **AWS IAM** | Lambda execution role (`cloudage`), Transcribe service role, Glue crawler role |
| **AWS CloudFormation** | IaC deployment of Lambda functions, S3 notifications, S3 folders, IAM role |
| **AWS Glue** | Data catalog — database `transcribe_pipeline_db`, DDL table `std_transcripts`, crawler-created table `cal_analytics`, crawler `analytics-transcripts-crawler` |
| **Amazon Athena** | SQL queries via workgroup `transcribe-workgroup` against `transcribe_pipeline_db` tables; results in `s3://transcribe-2027/athena-results/` |

## Glue Tables Detail

| Table | Location | Created By | SerDe |
|-------|----------|------------|-------|
| `std_transcripts` | `s3://transcribe-2027/output/results/` | Athena DDL (`CREATE EXTERNAL TABLE IF NOT EXISTS`) | `org.openx.data.jsonserde.JsonSerDe` with `ignore.malformed.json=true` |
| `cal_analytics` | `s3://transcribe-2027/output/results/analytics/` | Glue crawler `analytics-transcripts-crawler` | `org.openx.data.jsonserde.JsonSerDe` |

## Athena Preset Queries (in `app.py`)

| Query Name | Table | What it returns |
|------------|-------|----------------|
| Standard — All transcripts | `std_transcripts` | jobName, status, language, full transcript text |
| Standard — Word-level timing | `std_transcripts` | word, start/end time, confidence per word |
| Analytics — Sentiment overview | `cal_analytics` | agent + customer sentiment scores, call duration |
| Analytics — Talk time breakdown | `cal_analytics` | agent/customer talk time and words-per-minute |
| Analytics — Interruptions | `cal_analytics` | total interruption count and duration |
| Analytics — Conversation turns | `cal_analytics` | role, sentiment, content, timestamps per turn |

## IAM Roles

### `cloudage` — Lambda Execution Role
| Policy | Type | Purpose |
|--------|------|---------|
| `AWSLambdaBasicExecutionRole` | Managed | CloudWatch Logs |
| `AmazonTranscribeFullAccess` | Managed | `StartTranscriptionJob` + `StartCallAnalyticsJob` with wildcard resource (required for Call Analytics) |
| `transcribe-two-trigger-stack-transcribe-access-policy` | Customer Managed | Scoped S3 read/write on `transcribe-2027` |
| `PassRoleToTranscribeInline` | Inline | `iam:PassRole` to Transcribe service role — no `iam:PassedToService` condition (required for `StartCallAnalyticsJob`) |

### `AmazonTranscribeServiceRole-cloudagetranscriberole` — Transcribe Data Access Role
| Policy | Purpose |
|--------|---------|
| `AmazonS3FullAccess` | Allows Transcribe Call Analytics to read audio and write output to S3 |

### `GlueTranscribeCrawlerRole` — Glue Crawler Role
| Policy | Purpose |
|--------|---------|
| `AWSGlueServiceRole` | Core Glue permissions |
| `AmazonS3FullAccess` | Read output JSON from S3 to build Glue catalog |

## Infrastructure
- Deployed via **CloudFormation** (`Transcribe/transcribe-two-trigger-stack.yaml`)
- Custom CloudFormation resources (backed by Lambda) handle:
  - S3 bucket notification configuration (merges with existing, non-destructive)
  - S3 folder creation on stack deploy
- **Glue tables** — `std_transcripts` created via Athena DDL; `cal_analytics` created by Glue crawler
- **Athena SerDe** — `org.openx.data.jsonserde.JsonSerDe` with `ignore.malformed.json=true`
- No CDK, SAM, or Terraform — plain CloudFormation with inline Lambda `ZipFile` code

## Supported Audio Formats
`mp3`, `mp4`, `wav`, `flac`, `ogg`, `amr`, `webm`

## Common Commands

### Deploy the full stack (first time or fresh account)
```powershell
.\deploy.ps1 -BucketName "transcribe-2027"
```

### Run the Streamlit UI
```powershell
streamlit run app.py
# Open http://localhost:8501
```

### Tear down the CloudFormation stack
```powershell
.\deploy.ps1 -BucketName "transcribe-2027" -Destroy
# or directly:
aws cloudformation delete-stack --stack-name transcribe-two-trigger-stack --region us-east-1
```

### Check stack tear-down status
```powershell
aws cloudformation describe-stacks --stack-name transcribe-two-trigger-stack --region us-east-1 --query "Stacks[0].{Status:StackStatus,Reason:StackStatusReason}" --output table
# Wait until complete:
aws cloudformation wait stack-delete-complete --stack-name transcribe-two-trigger-stack --region us-east-1
```

### Upload sample files and trigger the pipeline
```powershell
# Standard transcription
aws s3 cp "Transcribe\On_Mono_Channel\transcribe_1.mp3" s3://transcribe-2027/input/transcribe_1.mp3

# Call analytics
aws s3 cp "Transcribe\On_2_Channels\InboundCall.mp3" s3://transcribe-2027/analytics/InboundCall.mp3
```

### Check job status
```powershell
aws transcribe list-transcription-jobs --region us-east-1 --query "TranscriptionJobSummaries[*].{Job:TranscriptionJobName,Status:TranscriptionJobStatus}" --output table
aws transcribe list-call-analytics-jobs --region us-east-1 --query "CallAnalyticsJobSummaries[*].{Job:CallAnalyticsJobName,Status:CallAnalyticsJobStatus}" --output table
```

### Run Athena query from CLI
```powershell
$QueryId = aws athena start-query-execution `
  --region us-east-1 `
  --work-group "transcribe-workgroup" `
  --query-string "SELECT jobName, status, results.language_code FROM transcribe_pipeline_db.std_transcripts LIMIT 5" `
  --query "QueryExecutionId" --output text
Start-Sleep -Seconds 10
aws athena get-query-execution --query-execution-id $QueryId --region us-east-1 --query "QueryExecution.Status.State"
```

### Re-run Glue crawler to pick up new analytics output files
```powershell
aws glue start-crawler --name "analytics-transcripts-crawler" --region us-east-1
```
