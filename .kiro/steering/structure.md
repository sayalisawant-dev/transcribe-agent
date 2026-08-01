# Project Structure

```
Transcribe/
├── Transcribe/                         # Main project source
│   ├── TranscribeFunction              # Lambda: standard transcription trigger (Python, no .py extension)
│   ├── TranscribeAnalyticsFunction     # Lambda: call analytics trigger (Python, no .py extension)
│   ├── transcribe-two-trigger-stack.yaml  # CloudFormation stack (full IaC deployment)
│   ├── Create inline policy            # IAM inline policy JSON for iam:PassRole permission
│   ├── Test_Sniffet                    # Sample S3 event payload for Lambda manual testing
│   ├── ReadersAreTheLeaders            # Setup notes / course instructions (plain text)
│   ├── On_2_Channels/                  # Sample stereo audio files for analytics pipeline
│   │   ├── InboundCall.mp3
│   │   └── InboundRecording.mp3
│   └── On_Mono_Channel/                # Sample mono audio files for standard transcription
│       ├── transcribe_1.mp3
│       ├── transcribe_2.mp4
│       └── transcribe_3.wav
└── .kiro/
    └── steering/                       # AI assistant steering rules
```

## S3 Bucket Layout (runtime)
```
<bucket>/
├── input/              # Drop mono audio here → triggers TranscribeFunction
├── analytics/          # Drop stereo/call audio here → triggers TranscribeAnalyticsFunction
└── output/
    └── results/
        ├── *.json              # Standard transcription output
        └── analytics/
            └── *.json          # Call analytics output
```

## Key Conventions

- **Lambda source files have no file extension** — `TranscribeFunction` and `TranscribeAnalyticsFunction` are plain Python scripts, not `.py` files. The canonical/deployed versions live inline in the CloudFormation `ZipFile` block.
- **Single shared S3 bucket** — all input and output flows through one bucket, differentiated by prefix.
- **Environment variables over hardcoded values** — bucket name, prefixes, and role ARNs are always injected via Lambda env vars, never hardcoded in function logic (except the standalone dev scripts which have a hardcoded role ARN as a known TODO).
- **Graceful per-record error handling** — Lambda handlers iterate `event['Records']` with individual try/except blocks so one bad record never fails the entire batch.
- **Non-destructive S3 notifications** — the `BucketNotificationManagerFunction` merges new notification configs with any existing ones rather than replacing them wholesale.
- **Job naming** — standard jobs use `job_<sanitized-filename>` prefix; analytics jobs use `analytics_<sanitized-filename>_<timestamp>` to avoid conflicts.
