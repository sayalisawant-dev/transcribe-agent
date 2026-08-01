"""
Streamlit UI — AWS Transcribe Pipeline Tester
Upload audio → trigger Lambda via S3 → monitor job → view transcript
"""

import time
import boto3
import streamlit as st
from botocore.exceptions import ClientError

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
BUCKET_NAME = "transcribeagent2026"
STANDARD_PREFIX = "input/"
ANALYTICS_PREFIX = "analytics/"
OUTPUT_PREFIX = "output/results/"
ANALYTICS_OUTPUT_PREFIX = "output/results/analytics/"
REGION = "us-east-1"
SUPPORTED_FORMATS = ["mp3", "mp4", "wav", "flac", "ogg", "amr", "webm"]

# ─────────────────────────────────────────────
# AWS clients (uses local AWS credentials / IAM role)
# ─────────────────────────────────────────────
@st.cache_resource
def get_clients():
    s3 = boto3.client("s3", region_name=REGION)
    transcribe = boto3.client("transcribe", region_name=REGION)
    return s3, transcribe

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
def upload_to_s3(s3, file_bytes, filename, prefix):
    key = f"{prefix}{filename}"
    s3.put_object(Bucket=BUCKET_NAME, Key=key, Body=file_bytes)
    return key


def get_job_status(transcribe, job_name, analytics=False):
    try:
        if analytics:
            resp = transcribe.get_call_analytics_job(CallAnalyticsJobName=job_name)
            return resp["CallAnalyticsJob"]["CallAnalyticsJobStatus"]
        else:
            resp = transcribe.get_transcription_job(TranscriptionJobName=job_name)
            return resp["TranscriptionJob"]["TranscriptionJobStatus"]
    except ClientError:
        return "NOT_FOUND"


def fetch_transcript_from_s3(s3, job_name, analytics=False):
    prefix = ANALYTICS_OUTPUT_PREFIX if analytics else OUTPUT_PREFIX
    key = f"{prefix}{job_name}.json"
    try:
        obj = s3.get_object(Bucket=BUCKET_NAME, Key=key)
        import json
        data = json.loads(obj["Body"].read())
        if analytics:
            # Call analytics transcript is nested differently
            segments = data.get("Transcript", [])
            return "\n".join(
                f"[{seg.get('ParticipantRole','?')}] {seg.get('Content','')}"
                for seg in segments
            )
        else:
            return data["results"]["transcripts"][0]["transcript"]
    except Exception as e:
        return f"Could not fetch transcript: {e}"


def list_output_files(s3, prefix):
    try:
        resp = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=prefix)
        return [obj["Key"] for obj in resp.get("Contents", []) if obj["Key"].endswith(".json")]
    except Exception:
        return []


# ─────────────────────────────────────────────
# Page setup
# ─────────────────────────────────────────────
st.set_page_config(
    page_title="Transcribe Pipeline Tester",
    page_icon="🎙️",
    layout="wide",
)

st.title("🎙️ AWS Transcribe Pipeline Tester")
st.caption(f"Bucket: `{BUCKET_NAME}` · Region: `{REGION}`")
st.divider()

s3, transcribe = get_clients()

# ─────────────────────────────────────────────
# Tabs
# ─────────────────────────────────────────────
tab_upload, tab_monitor, tab_results = st.tabs(
    ["📤 Upload & Trigger", "📊 Monitor Jobs", "📄 View Transcripts"]
)

# ═══════════════════════════════════════════════
# TAB 1 — Upload & Trigger
# ═══════════════════════════════════════════════
with tab_upload:
    st.subheader("Upload Audio File")
    st.write("Choose a mode, upload a file, and the S3 event will automatically trigger the Lambda.")

    mode = st.radio(
        "Processing mode",
        ["Standard Transcription (mono)", "Call Analytics (stereo/2-channel)"],
        horizontal=True,
    )
    is_analytics = mode.startswith("Call")

    uploaded_file = st.file_uploader(
        "Choose an audio file",
        type=SUPPORTED_FORMATS,
        help=f"Supported: {', '.join(SUPPORTED_FORMATS)}",
    )

    if uploaded_file:
        st.audio(uploaded_file)
        prefix = ANALYTICS_PREFIX if is_analytics else STANDARD_PREFIX

        col1, col2 = st.columns([1, 3])
        with col1:
            upload_btn = st.button("🚀 Upload to S3", type="primary", use_container_width=True)

        if upload_btn:
            with st.spinner(f"Uploading `{uploaded_file.name}` to `s3://{BUCKET_NAME}/{prefix}`..."):
                try:
                    key = upload_to_s3(s3, uploaded_file.read(), uploaded_file.name, prefix)
                    st.success(f"Uploaded → `{key}`")
                    st.info("Lambda will be triggered automatically by the S3 event. Switch to the **Monitor Jobs** tab to track progress.")
                except Exception as e:
                    st.error(f"Upload failed: {e}")

    st.divider()
    st.subheader("S3 Bucket Contents")
    col_a, col_b = st.columns(2)

    with col_a:
        st.markdown("**input/ (standard)**")
        try:
            resp = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=STANDARD_PREFIX)
            files = [o["Key"] for o in resp.get("Contents", []) if not o["Key"].endswith("/")]
            if files:
                for f in files:
                    st.code(f, language=None)
            else:
                st.caption("No files")
        except Exception as e:
            st.warning(str(e))

    with col_b:
        st.markdown("**analytics/ (call analytics)**")
        try:
            resp = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=ANALYTICS_PREFIX)
            files = [o["Key"] for o in resp.get("Contents", []) if not o["Key"].endswith("/")]
            if files:
                for f in files:
                    st.code(f, language=None)
            else:
                st.caption("No files")
        except Exception as e:
            st.warning(str(e))


# ═══════════════════════════════════════════════
# TAB 2 — Monitor Jobs
# ═══════════════════════════════════════════════
with tab_monitor:
    st.subheader("Transcription Job Monitor")

    job_type = st.radio("Job type", ["Standard", "Call Analytics"], horizontal=True)
    analytics_mode = job_type == "Call Analytics"

    col1, col2 = st.columns([2, 1])
    with col1:
        job_name_input = st.text_input(
            "Job name (leave blank to list recent jobs)",
            placeholder="e.g. job_transcribe_1.mp3",
        )
    with col2:
        st.markdown("<br>", unsafe_allow_html=True)
        check_btn = st.button("🔍 Check Status", use_container_width=True)

    if check_btn:
        if job_name_input.strip():
            status = get_job_status(transcribe, job_name_input.strip(), analytics=analytics_mode)
            color = {"COMPLETED": "✅", "IN_PROGRESS": "⏳", "FAILED": "❌", "NOT_FOUND": "❓"}.get(status, "ℹ️")
            st.metric("Job Status", f"{color} {status}")
        else:
            st.info("Fetching recent jobs...")

    st.divider()
    st.subheader("Recent Jobs")

    col_r1, col_r2 = st.columns(2)

    with col_r1:
        st.markdown("**Standard Transcription**")
        if st.button("🔄 Refresh Standard Jobs"):
            try:
                resp = transcribe.list_transcription_jobs(MaxResults=10)
                jobs = resp.get("TranscriptionJobSummaries", [])
                if jobs:
                    for j in jobs:
                        status = j["TranscriptionJobStatus"]
                        icon = {"COMPLETED": "✅", "IN_PROGRESS": "⏳", "FAILED": "❌"}.get(status, "ℹ️")
                        st.write(f"{icon} `{j['TranscriptionJobName']}` — {status}")
                else:
                    st.caption("No jobs found")
            except Exception as e:
                st.error(str(e))

    with col_r2:
        st.markdown("**Call Analytics**")
        if st.button("🔄 Refresh Analytics Jobs"):
            try:
                resp = transcribe.list_call_analytics_jobs(MaxResults=10)
                jobs = resp.get("CallAnalyticsJobSummaries", [])
                if jobs:
                    for j in jobs:
                        status = j["CallAnalyticsJobStatus"]
                        icon = {"COMPLETED": "✅", "IN_PROGRESS": "⏳", "FAILED": "❌"}.get(status, "ℹ️")
                        st.write(f"{icon} `{j['CallAnalyticsJobName']}` — {status}")
                else:
                    st.caption("No jobs found")
            except Exception as e:
                st.error(str(e))


# ═══════════════════════════════════════════════
# TAB 3 — View Transcripts
# ═══════════════════════════════════════════════
with tab_results:
    st.subheader("View Transcript Output")

    result_type = st.radio("Output type", ["Standard", "Call Analytics"], horizontal=True)
    is_analytics_result = result_type == "Call Analytics"
    prefix = ANALYTICS_OUTPUT_PREFIX if is_analytics_result else OUTPUT_PREFIX

    output_files = list_output_files(s3, prefix)

    if output_files:
        selected_file = st.selectbox(
            "Select output file — transcript loads instantly",
            options=output_files,
            format_func=lambda x: x.split("/")[-1],
        )

        # Auto-load transcript on selection — no button needed
        job_name = selected_file.split("/")[-1].replace(".json", "")
        with st.spinner("Loading transcript..."):
            transcript = fetch_transcript_from_s3(s3, job_name, analytics=is_analytics_result)

        if transcript.startswith("Could not fetch"):
            st.error(transcript)
        else:
            st.success(f"✅ Transcript for `{job_name}`")
            st.text_area("Transcript", value=transcript, height=300, label_visibility="collapsed")
            st.download_button(
                label="⬇️ Download as .txt",
                data=transcript,
                file_name=f"{job_name}.txt",
                mime="text/plain",
            )
    else:
        st.info(f"No output files found in `{prefix}`. Upload and process a file first.")

    st.divider()
    st.subheader("Raw S3 Output Files")
    if st.button("🔄 Refresh output list"):
        st.rerun()

    all_output = list_output_files(s3, OUTPUT_PREFIX) + list_output_files(s3, ANALYTICS_OUTPUT_PREFIX)
    if all_output:
        for f in all_output:
            st.code(f, language=None)
    else:
        st.caption("No output files yet")
