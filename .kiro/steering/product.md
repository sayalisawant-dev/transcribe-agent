# Product Overview

This project is an **AWS-based audio transcription pipeline** built for the CloudAge course. It automatically transcribes audio files uploaded to S3 using Amazon Transcribe, supports call analytics (sentiment, speaker roles, talk time, interruptions) for stereo/two-channel recordings, and provides a Streamlit UI to upload files, monitor jobs, view transcripts, and query output data interactively using Amazon Athena.

## Two Processing Modes

- **Standard Transcription**: Handles mono audio files dropped into the `input/` S3 prefix. Uses `StartTranscriptionJob` with automatic language detection. Supports mp3, mp4, wav, flac, ogg, amr, webm. Output lands in `output/results/`.
- **Call Analytics**: Handles stereo/two-channel call recordings dropped into the `analytics/` S3 prefix. Uses `StartCallAnalyticsJob` with defined channel roles (Channel 0 = CUSTOMER, Channel 1 = AGENT). Output lands in `output/results/analytics/`.

## Key Behaviors

- S3 `ObjectCreated` events trigger Lambda functions automatically — no manual invocation needed.
- Transcription results (JSON) are written back to the same S3 bucket (`transcribe-2027`) under `output/results/` or `output/results/analytics/`.
- Duplicate job names (`ConflictException`) are silently skipped rather than errored.
- All Lambda configuration (prefixes, bucket name, role ARN) is passed via environment variables — nothing hardcoded.
- File extension is parsed with `rsplit(".", 1)` to handle filenames with multiple dots correctly.

## Streamlit UI (`app.py`)

Four tabs:

| Tab | Purpose |
|-----|---------|
| **Upload & Trigger** | Upload audio files directly to S3 `input/` or `analytics/` prefix to trigger Lambda |
| **Monitor Jobs** | Check status of standard and call analytics jobs, list recent jobs |
| **View Transcripts** | Browse and read completed output JSON files; download as `.txt` |
| **Athena Query** | Run SQL queries against Glue-catalogued output data using Amazon Athena |

## Athena Query Tab

- Preset queries for: all transcripts, word-level timing, sentiment overview, talk time breakdown, interruptions, conversation turns
- Custom SQL editor for any Presto/Athena query
- Live polling progress bar, results as DataFrame, CSV download
- Auto-renders bar charts for sentiment and talk time queries
- Shows data scanned and estimated cost per query
- Recent query history (last 5 executions)

## Deployment

- One command: `.\deploy.ps1 -BucketName "transcribe-2027"` — handles all 12 steps end-to-end
- Tear down: `.\deploy.ps1 -BucketName "transcribe-2027" -Destroy`
- Run UI: `streamlit run app.py` → http://localhost:8501

## AWS Resources Created

### CloudFormation Stack (destroyed on `deploy.ps1 -Destroy`)
| Resource | Name |
|----------|------|
| CloudFormation Stack | `transcribe-two-trigger-stack` |
| Lambda — standard | `transcribe-two-trigger-stack-transcribe-trigger` |
| Lambda — analytics | `transcribe-two-trigger-stack-transcribe-analytics-trigger` |
| Lambda — notification manager | `transcribe-two-trigger-stack-bucket-notification-manager` |
| Lambda — folder creator | `transcribe-two-trigger-stack-create-s3-folders` |
| Lambda execution role | `cloudage` |
| IAM policy | `transcribe-two-trigger-stack-transcribe-access-policy` |
| S3 notifications | Configured on `transcribe-2027` for `input/` and `analytics/` prefixes |
| S3 folders | `input/`, `analytics/`, `output/`, `output/results/`, `output/results/analytics/` |

### Persistent Resources (survive stack destroy — created by `deploy.ps1` Steps 2–3 and 11)
| Resource | Name | Created in Step |
|----------|------|----------------|
| S3 Bucket | `transcribe-2027` | Pre-existing / Step 3 |
| Transcribe service role | `AmazonTranscribeServiceRole-cloudagetranscriberole` (path: `/service-role/`) | Step 2 |
| Inline PassRole policy | `PassRoleToTranscribeInline` on `cloudage` role | Step 6 |
| `AmazonTranscribeFullAccess` | Attached to `cloudage` role | Step 6 |
| Glue database | `transcribe_pipeline_db` | Step 11 |
| Glue table — standard | `std_transcripts` → `s3://transcribe-2027/output/results/` | Step 11 |
| Glue table — analytics | `cal_analytics` → `s3://transcribe-2027/output/results/analytics/` | Step 11 |
| Glue crawler | `analytics-transcripts-crawler` (prefix: `cal_`) | Step 11 |
| Glue crawler role | `GlueTranscribeCrawlerRole` | Step 11 |
| Athena workgroup | `transcribe-workgroup` → results at `s3://transcribe-2027/athena-results/` | Step 11 |
| S3 folder — Athena results | `athena-results/` in `transcribe-2027` | Step 11 |
