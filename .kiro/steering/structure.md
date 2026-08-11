# Project Structure

```
Transcribe/
├── Transcribe/                            # Main project source
│   ├── TranscribeFunction                 # Lambda: standard transcription trigger (Python, no .py extension)
│   ├── TranscribeAnalyticsFunction        # Lambda: call analytics trigger (Python, no .py extension)
│   ├── transcribe-two-trigger-stack.yaml  # CloudFormation stack (full IaC deployment)
│   ├── Create inline policy               # IAM inline policy JSON for iam:PassRole permission
│   ├── Test_Sniffet                       # Sample S3 event payload for Lambda manual testing
│   ├── ReadersAreTheLeaders               # Setup notes / course instructions (plain text)
│   ├── On_2_Channels/                     # Sample stereo audio files for analytics pipeline
│   │   ├── InboundCall.mp3
│   │   └── InboundRecording.mp3
│   └── On_Mono_Channel/                   # Sample mono audio files for standard transcription
│       ├── transcribe_1.mp3
│       ├── transcribe_2.mp4
│       └── transcribe_3.wav
├── app.py                                 # Streamlit UI — upload, monitor, view transcripts, Athena queries
├── deploy.ps1                             # End-to-end PowerShell deployment script (Steps 1–12)
├── requirements.txt                       # Python dependencies for the Streamlit UI
└── .kiro/
    ├── steering/                          # AI assistant steering rules
    │   ├── product.md
    │   ├── structure.md
    │   └── tech.md
    ├── specs/
    │   └── transcribe-pipeline/
    │       └── requirements.md
    └── hooks/
        └── cfn-deploy-on-task-complete.json
```

## S3 Bucket Layout (runtime)

```
transcribe-2027/
├── input/                        # Drop mono audio → triggers TranscribeFunction
├── analytics/                    # Drop stereo audio → triggers TranscribeAnalyticsFunction
├── output/
│   └── results/
│       ├── *.json                           # Standard transcription output
│       └── analytics/
│           └── *.json                       # Call analytics output
└── athena-results/               # Athena query result CSVs (auto-managed by Athena)
```

## AWS Glue / Athena Catalog (runtime)

```
Glue Database : transcribe_pipeline_db
  ├── std_transcripts    → s3://transcribe-2027/output/results/          (created via Athena DDL)
  └── cal_analytics      → s3://transcribe-2027/output/results/analytics/ (created by Glue crawler)

Glue Crawler  : analytics-transcripts-crawler
  ├── Role    : GlueTranscribeCrawlerRole
  ├── Prefix  : cal_
  └── Target  : s3://transcribe-2027/output/results/analytics/

Athena Workgroup : transcribe-workgroup
  └── Result location → s3://transcribe-2027/athena-results/
```

### Glue / Athena Lifecycle Notes

- These resources are **NOT part of the CloudFormation stack** — they survive a `deploy.ps1 -Destroy` and do not need to be recreated on redeploy.
- `deploy.ps1` Step 11 creates them idempotently — safe to re-run, skips if already present.
- After uploading new analytics files, re-run the crawler to update the `cal_analytics` schema:
  ```powershell
  aws glue start-crawler --name "analytics-transcripts-crawler" --region us-east-1
  ```
- `std_transcripts` is a folder-level DDL table — it picks up new `.json` files automatically with no crawler needed.
- `cal_analytics` uses `org.openx.data.jsonserde.JsonSerDe` with `CombineCompatibleSchemas` grouping policy.
- `std_transcripts` uses `org.openx.data.jsonserde.JsonSerDe` with `ignore.malformed.json=true`.

## Key Conventions

- **Lambda source files have no file extension** — `TranscribeFunction` and `TranscribeAnalyticsFunction` are plain Python scripts. The canonical deployed versions are repackaged from these files by `deploy.ps1` Step 7.
- **No hardcoded values in Lambda code** — bucket name, prefixes, and role ARNs are always read from Lambda environment variables (`BUCKET_NAME`, `INPUT_PREFIX`, `OUTPUT_PREFIX`, `DATA_ACCESS_ROLE_ARN`).
- **Single shared S3 bucket** — all input, output, and Athena results flow through `transcribe-2027`, differentiated by prefix.
- **Graceful per-record error handling** — Lambda handlers iterate `event['Records']` with individual try/except blocks so one bad record never fails the entire batch.
- **Non-destructive S3 notifications** — the `BucketNotificationManagerFunction` merges new notification configs with any existing ones rather than replacing them wholesale.
- **Job naming** — standard jobs use `job_<sanitized-filename>` prefix; analytics jobs use `analytics_<sanitized-filename>_<timestamp>` to avoid conflicts.
- **File extension parsing** — uses `rsplit(".", 1)` not `split(".")[-1]` to correctly handle filenames with multiple dots.
- **IAM PassRole** — the Lambda execution role has an inline policy (`PassRoleToTranscribeInline`) without a `iam:PassedToService` condition because `StartCallAnalyticsJob` does not honour that condition.
- **Athena tables** — `std_transcripts` is created via DDL (one table for all files in the folder); `cal_analytics` is created by the Glue crawler. Both use `org.openx.data.jsonserde.JsonSerDe`.
- **deploy.ps1 is idempotent** — every step checks for existing resources before creating them. Safe to re-run on an existing stack.
