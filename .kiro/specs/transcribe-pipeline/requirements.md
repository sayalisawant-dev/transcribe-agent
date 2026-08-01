# Requirements Document

## Introduction

This document defines the requirements for an AWS-based audio transcription pipeline that automatically processes audio files uploaded to Amazon S3. The pipeline supports two distinct processing modes: standard transcription for mono audio and call analytics for stereo two-channel call recordings. Both flows are triggered by S3 `ObjectCreated` events, executed by AWS Lambda functions (Python 3.12), and output results as JSON back to the same S3 bucket. The full infrastructure is deployed via AWS CloudFormation.

---

## Glossary

- **Pipeline**: The end-to-end audio transcription system consisting of S3 storage, Lambda triggers, and Amazon Transcribe jobs.
- **TranscribeFunction**: The Lambda function that handles standard mono transcription using `StartTranscriptionJob`.
- **TranscribeAnalyticsFunction**: The Lambda function that handles call analytics for stereo recordings using `StartCallAnalyticsJob`.
- **BucketNotificationManagerFunction**: The custom CloudFormation Lambda resource that configures S3 event notifications non-destructively.
- **CreateS3FoldersFunction**: The custom CloudFormation Lambda resource that creates required S3 folder prefixes on stack deployment.
- **S3_Bucket**: The single shared Amazon S3 bucket used for all input and output operations.
- **Input_Prefix**: The S3 key prefix `input/` where mono audio files are deposited for standard transcription.
- **Analytics_Prefix**: The S3 key prefix `analytics/` where stereo call recordings are deposited for call analytics processing.
- **Output_Prefix**: The S3 key prefix `output/results/` where standard transcription JSON output is written.
- **Analytics_Output_Prefix**: The S3 key prefix `output/results/analytics/` where call analytics JSON output is written.
- **Transcription_Job**: An Amazon Transcribe job submitted via `StartTranscriptionJob` for standard mono audio.
- **Analytics_Job**: An Amazon Transcribe job submitted via `StartCallAnalyticsJob` for stereo call recordings.
- **Job_Name**: The sanitized, unique identifier used when submitting a transcription or analytics job to Amazon Transcribe.
- **Supported_Formats**: The set of audio file extensions accepted by the Pipeline: `mp3`, `mp4`, `wav`, `flac`, `ogg`, `amr`, `webm`.
- **ConflictException**: The AWS error raised when a Transcription_Job with the same Job_Name already exists.
- **CloudFormation_Stack**: The AWS CloudFormation stack (`transcribe-two-trigger-stack.yaml`) that provisions all Pipeline resources.
- **Lambda_Execution_Role**: The IAM role assumed by Lambda functions, granting scoped S3, Transcribe, and PassRole permissions.
- **Data_Access_Role**: The IAM role passed to Amazon Transcribe for Call Analytics, granting Transcribe service access to the S3_Bucket.
- **Channel_Definition**: The mapping of audio channel IDs to participant roles (`CUSTOMER` on channel 0, `AGENT` on channel 1) used in Analytics_Jobs.
- **Environment_Variable**: A Lambda configuration value injected at runtime for bucket name, prefixes, and role ARNs.

---

## CloudFormation Stack Parameters

All parameters are defined in `Transcribe/transcribe-two-trigger-stack.yaml`. Each can be overridden at deploy time via `--parameter-overrides`.

| Parameter | Default Value | Description |
|---|---|---|
| `ExistingBucketName` | `cloudage-transcribe-2013` | Existing S3 bucket that receives audio files. Must exist before stack deploy. |
| `LambdaExecutionRoleName` | `cloudage` | IAM role name created for all Lambda functions in the stack. |
| `StandardInputPrefix` | `input/` | S3 key prefix that triggers the standard Transcribe Lambda on `ObjectCreated`. |
| `StandardOutputPrefix` | `output/results/` | S3 key prefix where standard transcription JSON output is written. |
| `AnalyticsInputPrefix` | `analytics/` | S3 key prefix that triggers the Call Analytics Lambda on `ObjectCreated`. |
| `AnalyticsOutputPrefix` | `output/results/` | Output location passed to `StartCallAnalyticsJob`. Transcribe automatically appends `analytics/` subfolder — final output lands at `output/results/analytics/<job>.json`. |
| `TranscribeDataAccessRoleName` | `AmazonTranscribeServiceRole-cloudagetranscriberole` | IAM role name for Amazon Transcribe Call Analytics data access. Constructed as `arn:aws:iam::<AccountId>:role/service-role/<name>`. |

### Active Deployment Values (transcribeagent2026)

```bash
aws cloudformation deploy \
  --template-file Transcribe/transcribe-two-trigger-stack.yaml \
  --stack-name transcribe-two-trigger-stack \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ExistingBucketName=transcribeagent2026 \
    LambdaExecutionRoleName=cloudage \
    TranscribeDataAccessRoleName=AmazonTranscribeServiceRole-cloudagetranscriberole
```

---

## Lambda Functions

### TranscribeFunction

| Property | Value |
|---|---|
| Function name | `transcribe-two-trigger-stack-transcribe-trigger` |
| Runtime | Python 3.12 |
| Handler | `index.lambda_handler` |
| Timeout | 180 seconds |
| Memory | 256 MB |
| Trigger | S3 `ObjectCreated` on `input/` prefix (`.mp3`, `.mp4`, `.wav`) |

**Environment Variables:**

| Variable | Value |
|---|---|
| `BUCKET_NAME` | Value of `ExistingBucketName` parameter |
| `INPUT_PREFIX` | Value of `StandardInputPrefix` parameter (default: `input/`) |
| `OUTPUT_PREFIX` | Value of `StandardOutputPrefix` parameter (default: `output/results/`) |

---

### TranscribeAnalyticsFunction

| Property | Value |
|---|---|
| Function name | `transcribe-two-trigger-stack-transcribe-analytics-trigger` |
| Runtime | Python 3.12 |
| Handler | `index.lambda_handler` |
| Timeout | 180 seconds |
| Memory | 256 MB |
| Trigger | S3 `ObjectCreated` on `analytics/` prefix (`.mp3`) |

**Environment Variables:**

| Variable | Value |
|---|---|
| `BUCKET_NAME` | Value of `ExistingBucketName` parameter |
| `INPUT_PREFIX` | Value of `AnalyticsInputPrefix` parameter (default: `analytics/`) |
| `OUTPUT_PREFIX` | Value of `AnalyticsOutputPrefix` parameter (default: `output/results/`) — Transcribe appends `analytics/` automatically, so output lands at `output/results/analytics/` |
| `DATA_ACCESS_ROLE_ARN` | Constructed as `arn:aws:iam::<AccountId>:role/service-role/<TranscribeDataAccessRoleName>` |

---

### BucketNotificationManagerFunction

| Property | Value |
|---|---|
| Function name | `transcribe-two-trigger-stack-bucket-notification-manager` |
| Runtime | Python 3.12 |
| Handler | `index.lambda_handler` |
| Timeout | 180 seconds |
| Memory | 128 MB |
| Invocation | CloudFormation Custom Resource only (not S3 triggered) |

---

### CreateS3FoldersFunction

| Property | Value |
|---|---|
| Function name | `transcribe-two-trigger-stack-create-s3-folders` |
| Runtime | Python 3.12 |
| Handler | `index.lambda_handler` |
| Timeout | 60 seconds |
| Memory | 128 MB |
| Invocation | CloudFormation Custom Resource only — creates `input/`, `output/`, `analytics/` on deploy |

---

## IAM Resources

### Lambda Execution Role (`LambdaExecutionRoleName`)

| Permission | Resource Scope |
|---|---|
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<bucket>/*` |
| `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetBucketNotification`, `s3:PutBucketNotification` | `arn:aws:s3:::<bucket>` |
| `transcribe:StartTranscriptionJob` | `arn:aws:transcribe:<region>:<account>:transcription-job/*` |
| `transcribe:StartCallAnalyticsJob` | `arn:aws:transcribe:<region>:<account>:call-analytics-job/*` and `arn:aws:transcribe:<region>:<account>:analytics/*` |
| `iam:PassRole` (conditioned on `iam:PassedToService: transcribe.amazonaws.com`) | `arn:aws:iam::<account>:role/service-role/<TranscribeDataAccessRoleName>` |
| `AWSLambdaBasicExecutionRole` (managed) | CloudWatch Logs |

### Transcribe Data Access Role (`TranscribeDataAccessRoleName`)

| Property | Value |
|---|---|
| Trust policy | `transcribe.amazonaws.com` |
| Path | `/service-role/` |
| Attached policy | `AmazonS3FullAccess` |
| Purpose | Passed to `StartCallAnalyticsJob` so Transcribe can read from and write to S3 |

---

## S3 Bucket Layout

```
transcribeagent2026/
├── input/                        # Drop mono audio → triggers TranscribeFunction
├── analytics/                    # Drop stereo audio → triggers TranscribeAnalyticsFunction
└── output/
    └── results/
        ├── job_<filename>.json                          # Standard transcription output
        └── analytics/                                   # Transcribe appends this subfolder automatically
            └── analytics_<filename>_<timestamp>.json   # Call analytics output
```

---

## CloudFormation Stack Outputs

| Output Key | Description |
|---|---|
| `SharedRoleName` | IAM role name shared by all Lambda functions |
| `StandardTranscribeLambdaArn` | ARN of `TranscribeFunction` |
| `AnalyticsTranscribeLambdaArn` | ARN of `TranscribeAnalyticsFunction` |
| `BucketName` | S3 bucket configured with event notifications |

---

## Streamlit UI Parameters (`app.py`)

| Constant | Value | Purpose |
|---|---|---|
| `BUCKET_NAME` | `transcribeagent2026` | S3 bucket for all uploads and output reads |
| `STANDARD_PREFIX` | `input/` | Upload prefix for standard transcription |
| `ANALYTICS_PREFIX` | `analytics/` | Upload prefix for call analytics |
| `OUTPUT_PREFIX` | `output/results/` | S3 prefix to list/read standard output JSON |
| `ANALYTICS_OUTPUT_PREFIX` | `output/results/analytics/` | S3 prefix to list/read analytics output JSON |
| `REGION` | `us-east-1` | AWS region for all boto3 clients |
| `SUPPORTED_FORMATS` | `mp3, mp4, wav, flac, ogg, amr, webm` | File types accepted by the upload widget |

---

## Requirements

### Requirement 1: S3 Event-Driven Trigger for Standard Transcription

**User Story:** As a developer, I want audio files uploaded to the `input/` S3 prefix to automatically trigger transcription, so that I do not need to manually invoke the transcription process.

#### Acceptance Criteria

1. WHEN an `ObjectCreated` event is received for an object under `Input_Prefix`, THE `TranscribeFunction` SHALL invoke the transcription workflow for that object.
2. WHEN an `ObjectCreated` event contains a key that does not start with `Input_Prefix`, THE `TranscribeFunction` SHALL skip that record without error.
3. THE `TranscribeFunction` SHALL read `INPUT_PREFIX`, `OUTPUT_PREFIX`, and `BUCKET_NAME` from Environment_Variables rather than using hardcoded values.
4. WHEN an S3 event record contains a URL-encoded object key, THE `TranscribeFunction` SHALL decode the key before processing.

---

### Requirement 2: S3 Event-Driven Trigger for Call Analytics

**User Story:** As a developer, I want stereo call recordings uploaded to the `analytics/` S3 prefix to automatically trigger call analytics processing, so that sentiment and speaker-role analysis is applied without manual intervention.

#### Acceptance Criteria

1. WHEN an `ObjectCreated` event is received for an object under `Analytics_Prefix`, THE `TranscribeAnalyticsFunction` SHALL invoke the call analytics workflow for that object.
2. WHEN an `ObjectCreated` event contains a key that does not start with `Analytics_Prefix`, THE `TranscribeAnalyticsFunction` SHALL skip that record without error.
3. THE `TranscribeAnalyticsFunction` SHALL read `INPUT_PREFIX`, `OUTPUT_PREFIX`, `DATA_ACCESS_ROLE_ARN`, and `BUCKET_NAME` from Environment_Variables rather than using hardcoded values.
4. WHEN an S3 event record contains a URL-encoded object key, THE `TranscribeAnalyticsFunction` SHALL decode the key before processing.
5. WHEN the event contains no records, THE `TranscribeAnalyticsFunction` SHALL return a skipped status response without invoking any Transcribe API.

---

### Requirement 3: Supported Audio Format Validation

**User Story:** As a developer, I want the pipeline to reject unsupported file types silently, so that only valid audio formats are submitted to Amazon Transcribe.

#### Acceptance Criteria

1. WHEN an object key contains a file extension in Supported_Formats (`mp3`, `mp4`, `wav`, `flac`, `ogg`, `amr`, `webm`), THE `TranscribeFunction` SHALL submit a Transcription_Job for that file.
2. WHEN an object key contains a file extension not in Supported_Formats, THE `TranscribeFunction` SHALL skip that record without submitting a job or raising an error.
3. WHEN an object key contains no file extension (no `.` character), THE `TranscribeFunction` SHALL skip that record without submitting a job or raising an error.
4. THE `TranscribeFunction` SHALL evaluate file extensions in a case-insensitive manner.

---

### Requirement 4: Standard Transcription Job Submission

**User Story:** As a developer, I want each valid mono audio file to be submitted as a uniquely named transcription job with automatic language detection, so that transcription results are stored without naming collisions.

#### Acceptance Criteria

1. WHEN a valid audio file is identified under `Input_Prefix`, THE `TranscribeFunction` SHALL generate a Job_Name using the pattern `job_<sanitized-filename>` where the sanitized filename replaces all characters outside `[a-zA-Z0-9._-]` with hyphens and is truncated to 150 characters.
2. WHEN submitting a Transcription_Job, THE `TranscribeFunction` SHALL set `IdentifyLanguage` to `True` so that Amazon Transcribe detects the spoken language automatically.
3. WHEN submitting a Transcription_Job, THE `TranscribeFunction` SHALL set `OutputBucketName` to the value of the `BUCKET_NAME` Environment_Variable and `OutputKey` to `<OUTPUT_PREFIX><job_name>.json`.
4. WHEN a ConflictException is raised for a Transcription_Job, THE `TranscribeFunction` SHALL log the conflict and skip the record without propagating the error.
5. WHEN any non-ConflictException `ClientError` is raised during job submission, THE `TranscribeFunction` SHALL re-raise the exception.

---

### Requirement 5: Call Analytics Job Submission

**User Story:** As a developer, I want each stereo call recording to be submitted as a uniquely named analytics job with defined channel roles, so that speaker-separated transcription and call analytics results are stored per file.

#### Acceptance Criteria

1. WHEN a valid audio file is identified under `Analytics_Prefix`, THE `TranscribeAnalyticsFunction` SHALL generate a Job_Name using the pattern `analytics_<sanitized-filename>_<UTC-timestamp>` where the UTC timestamp has the format `YYYYMMDDHHmmss`.
2. WHEN submitting an Analytics_Job, THE `TranscribeAnalyticsFunction` SHALL set `ChannelDefinitions` to assign channel 0 to `CUSTOMER` role and channel 1 to `AGENT` role.
3. WHEN submitting an Analytics_Job, THE `TranscribeAnalyticsFunction` SHALL set `OutputLocation` to `s3://<BUCKET_NAME>/<OUTPUT_PREFIX>` using the `BUCKET_NAME` and `OUTPUT_PREFIX` Environment_Variables.
4. WHEN submitting an Analytics_Job, THE `TranscribeAnalyticsFunction` SHALL pass `DATA_ACCESS_ROLE_ARN` from Environment_Variables as the `DataAccessRoleArn` parameter.
5. WHEN submitting an Analytics_Job, THE `TranscribeAnalyticsFunction` SHALL set `LanguageOptions` to `['en-US', 'en-GB', 'es-US', 'fr-FR']` within the `Settings` block.

---

### Requirement 6: Per-Record Error Isolation

**User Story:** As a developer, I want errors on individual S3 records to be isolated, so that one failed file does not prevent other files in the same batch from being processed.

#### Acceptance Criteria

1. WHEN processing a batch of S3 event records and one record raises an exception, THE `TranscribeFunction` SHALL log the exception and continue processing remaining records.
2. WHEN processing a batch of S3 event records and one record raises an exception, THE `TranscribeAnalyticsFunction` SHALL log the exception, append a `FAILED` status entry to the results, and continue processing remaining records.
3. WHEN all records in a batch have been processed, THE `TranscribeFunction` SHALL return a response with `{"status": "complete"}`.
4. WHEN all records in a batch have been processed, THE `TranscribeAnalyticsFunction` SHALL return a response containing the `processed_results` array with a status entry per processed record.

---

### Requirement 7: IAM Permissions and Security

**User Story:** As a security-conscious developer, I want the Lambda execution role to have least-privilege permissions, so that the pipeline cannot access resources beyond what is strictly required.

#### Acceptance Criteria

1. THE `Lambda_Execution_Role` SHALL grant `s3:GetObject` and `s3:PutObject` on all objects within the S3_Bucket only.
2. THE `Lambda_Execution_Role` SHALL grant `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetBucketNotification`, and `s3:PutBucketNotification` on the S3_Bucket resource only.
3. THE `Lambda_Execution_Role` SHALL grant `transcribe:StartTranscriptionJob` and `transcribe:StartCallAnalyticsJob` scoped to transcription job and call analytics job resources within the same AWS account and region.
4. THE `Lambda_Execution_Role` SHALL grant `iam:PassRole` to the `Data_Access_Role` only, conditioned on `iam:PassedToService: transcribe.amazonaws.com`.
5. THE `Lambda_Execution_Role` SHALL grant `AWSLambdaBasicExecutionRole` managed policy for CloudWatch Logs access.

---

### Requirement 8: Infrastructure Deployment via CloudFormation

**User Story:** As a developer, I want the entire pipeline to be provisioned through a single CloudFormation stack, so that all resources are created, configured, and torn down consistently.

#### Acceptance Criteria

1. THE `CloudFormation_Stack` SHALL accept `ExistingBucketName`, `StandardInputPrefix`, `StandardOutputPrefix`, `AnalyticsInputPrefix`, `AnalyticsOutputPrefix`, `LambdaExecutionRoleName`, and `TranscribeDataAccessRoleName` as configurable parameters with sensible defaults.
2. WHEN the `CloudFormation_Stack` is deployed, THE `CreateS3FoldersFunction` SHALL create the `input/`, `output/`, and `analytics/` folder prefixes in the S3_Bucket.
3. WHEN the `CloudFormation_Stack` is deployed, THE `BucketNotificationManagerFunction` SHALL configure S3 event notifications for `Input_Prefix` and `Analytics_Prefix` without removing any pre-existing notification configurations on the S3_Bucket.
4. WHEN the `CloudFormation_Stack` is deleted, THE `CreateS3FoldersFunction` SHALL preserve existing S3 folder prefixes and their contents rather than deleting them.
5. THE `CloudFormation_Stack` SHALL output the ARNs of both Lambda functions and the configured S3_Bucket name.

---

### Requirement 9: Non-Destructive S3 Notification Management

**User Story:** As a developer, I want adding pipeline notifications to an existing S3 bucket to preserve all pre-existing notification configurations, so that other workloads using the same bucket are not disrupted.

#### Acceptance Criteria

1. WHEN the `BucketNotificationManagerFunction` is invoked on a Create or Update CloudFormation event, THE `BucketNotificationManagerFunction` SHALL read the current notification configuration from the S3_Bucket before writing any changes.
2. WHEN merging notification configurations, THE `BucketNotificationManagerFunction` SHALL retain all existing `LambdaFunctionConfigurations` whose `Id` and `LambdaFunctionArn` do not match the managed configurations being applied.
3. WHEN the `BucketNotificationManagerFunction` is invoked on a Delete CloudFormation event, THE `BucketNotificationManagerFunction` SHALL remove only the managed notification configurations from the S3_Bucket and leave all others intact.
4. IF the `BucketNotificationManagerFunction` encounters any error during S3 notification update, THEN THE `BucketNotificationManagerFunction` SHALL signal `FAILED` to CloudFormation with a descriptive reason string.

---

### Requirement 10: Job Name Sanitization

**User Story:** As a developer, I want job names to be derived deterministically from the audio filename, so that job names are valid for the Amazon Transcribe API and traceable back to the source file.

#### Acceptance Criteria

1. WHEN constructing a Job_Name, THE `TranscribeFunction` SHALL replace all characters in the filename that are not alphanumeric, dots, underscores, or hyphens with a hyphen character.
2. WHEN constructing a Job_Name for standard transcription, THE `TranscribeFunction` SHALL prefix the sanitized filename with `job_` and truncate the combined result so the sanitized filename portion does not exceed 150 characters.
3. WHEN constructing a Job_Name for analytics, THE `TranscribeAnalyticsFunction` SHALL prefix the sanitized filename with `analytics_`, append a UTC timestamp suffix in `YYYYMMDDHHmmss` format, and truncate the sanitized filename portion to 100 characters.
4. THE `TranscribeFunction` SHALL derive the filename using `os.path.basename` from the S3 object key to exclude any folder prefix from the sanitized name.
