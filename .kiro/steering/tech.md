# Tech Stack

## Runtime & Language
- **Python 3.12** — all Lambda functions
- **boto3** — AWS SDK for Python (Transcribe, S3 clients)
- **botocore** — used for `ClientError` exception handling

## AWS Services
- **AWS Lambda** — event-driven compute for both transcription triggers
- **Amazon S3** — audio file ingestion and output storage
- **Amazon Transcribe** — `StartTranscriptionJob` (standard) and `StartCallAnalyticsJob` (analytics)
- **AWS IAM** — Lambda execution role with scoped S3/Transcribe/PassRole permissions
- **AWS CloudFormation** — infrastructure-as-code for the full stack

## Infrastructure
- Deployed via **CloudFormation** (`transcribe-two-trigger-stack.yaml`)
- Custom CloudFormation resources (backed by Lambda) handle:
  - S3 bucket notification configuration (merges with existing notifications, non-destructive)
  - S3 folder creation on stack deploy
- No CDK, SAM, or Terraform — plain CloudFormation with inline Lambda `ZipFile` code

## Supported Audio Formats
`mp3`, `mp4`, `wav`, `flac`, `ogg`, `amr`, `webm`

## Common Commands

### Deploy the stack
```bash
aws cloudformation deploy \
  --template-file Transcribe/transcribe-two-trigger-stack.yaml \
  --stack-name transcribe-two-trigger-stack \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ExistingBucketName=<your-bucket-name>
```

### Delete the stack (clean up all resources)
```bash
aws cloudformation delete-stack --stack-name transcribe-two-trigger-stack
```

### Test a Lambda function locally via AWS CLI
Use the test event JSON from `Test_Sniffet`:
```bash
aws lambda invoke \
  --function-name transcribe-two-trigger-stack-transcribe-trigger \
  --payload '{"Records":[{"s3":{"bucket":{"name":"<bucket>"},"object":{"key":"input/file.mp3"}}}]}' \
  response.json
```

### Check transcription job status
```bash
aws transcribe get-transcription-job --transcription-job-name <job-name>
```
