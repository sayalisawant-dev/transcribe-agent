# Product Overview

This project is an **AWS-based audio transcription pipeline** built for the CloudAge course. It automatically transcribes audio files uploaded to S3 using Amazon Transcribe, and also supports call analytics (sentiment, speaker roles, etc.) for stereo/two-channel recordings.

## Two Processing Modes

- **Standard Transcription**: Handles mono audio files dropped into the `input/` S3 prefix. Uses `StartTranscriptionJob` with automatic language detection. Supports mp3, mp4, wav, flac, ogg, amr, webm.
- **Call Analytics**: Handles stereo/two-channel call recordings dropped into the `analytics/` S3 prefix. Uses `StartCallAnalyticsJob` with defined channel roles (Channel 0 = CUSTOMER, Channel 1 = AGENT).

## Key Behaviors

- S3 `ObjectCreated` events trigger Lambda functions automatically.
- Transcription results (JSON) are written back to the same S3 bucket under `output/results/` or `output/results/analytics/`.
- Duplicate job names (ConflictException) are silently skipped rather than errored.
- All configuration (prefixes, bucket name, role ARN) is passed via Lambda environment variables.
