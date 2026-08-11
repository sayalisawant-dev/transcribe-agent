"""
Streamlit UI — AWS Transcribe Pipeline Tester
Upload audio → trigger Lambda via S3 → monitor job → view transcript → query with Athena
"""

import json
import time
import boto3
import pandas as pd
import streamlit as st
from botocore.exceptions import ClientError

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
BUCKET_NAME             = "transcribe-2027"
STANDARD_PREFIX         = "input/"
ANALYTICS_PREFIX        = "analytics/"
OUTPUT_PREFIX           = "output/results/"
ANALYTICS_OUTPUT_PREFIX = "output/results/analytics/"
ATHENA_RESULTS_PREFIX   = "athena-results/"
REGION                  = "us-east-1"
SUPPORTED_FORMATS       = ["mp3", "mp4", "wav", "flac", "ogg", "amr", "webm"]

GLUE_DATABASE           = "transcribe_pipeline_db"
ATHENA_WORKGROUP        = "transcribe-workgroup"
TABLE_STANDARD          = "std_transcripts"       # created via DDL
TABLE_ANALYTICS         = "cal_analytics"          # created by Glue crawler

# Pre-built queries users can pick from
PRESET_QUERIES = {
    "Standard — All transcripts (job name + text)": f"""
SELECT
  jobName,
  status,
  results.language_code       AS language,
  results.transcripts[1].transcript AS transcript_text
FROM {GLUE_DATABASE}.{TABLE_STANDARD}
LIMIT 20
""".strip(),

    "Standard — Word-level timing (first 30 words)": f"""
SELECT
  jobName,
  word.start_time,
  word.end_time,
  word.alternatives[1].content AS word,
  word.alternatives[1].confidence AS confidence
FROM {GLUE_DATABASE}.{TABLE_STANDARD}
CROSS JOIN UNNEST(results.items) AS t(word)
WHERE word.type = 'pronunciation'
LIMIT 30
""".strip(),

    "Analytics — Sentiment overview per call": f"""
SELECT
  jobName,
  jobStatus,
  languageCode,
  ROUND(CAST(conversationcharacteristics.sentiment.OverallSentiment.AGENT    AS double), 3) AS agent_sentiment,
  ROUND(CAST(conversationcharacteristics.sentiment.OverallSentiment.CUSTOMER AS double), 3) AS customer_sentiment,
  conversationcharacteristics.TotalConversationDurationMillis / 1000 AS duration_sec
FROM {GLUE_DATABASE}.{TABLE_ANALYTICS}
LIMIT 20
""".strip(),

    "Analytics — Talk time breakdown": f"""
SELECT
  jobName,
  conversationcharacteristics.TalkTime.DetailsByParticipant.AGENT.TotalTimeMillis    / 1000 AS agent_talk_sec,
  conversationcharacteristics.TalkTime.DetailsByParticipant.CUSTOMER.TotalTimeMillis / 1000 AS customer_talk_sec,
  conversationcharacteristics.TalkSpeed.DetailsByParticipant.AGENT.AverageWordsPerMinute    AS agent_wpm,
  conversationcharacteristics.TalkSpeed.DetailsByParticipant.CUSTOMER.AverageWordsPerMinute AS customer_wpm
FROM {GLUE_DATABASE}.{TABLE_ANALYTICS}
LIMIT 20
""".strip(),

    "Analytics — Interruptions": f"""
SELECT
  jobName,
  conversationcharacteristics.Interruptions.TotalCount        AS total_interruptions,
  conversationcharacteristics.Interruptions.TotalTimeMillis   AS interruption_ms
FROM {GLUE_DATABASE}.{TABLE_ANALYTICS}
LIMIT 20
""".strip(),

    "Analytics — All conversation turns (role + sentiment + text)": f"""
SELECT
  jobName,
  turn.ParticipantRole  AS role,
  turn.Sentiment        AS sentiment,
  turn.Content          AS content,
  turn.BeginOffsetMillis / 1000 AS start_sec,
  turn.EndOffsetMillis   / 1000 AS end_sec
FROM {GLUE_DATABASE}.{TABLE_ANALYTICS}
CROSS JOIN UNNEST(transcript) AS t(turn)
ORDER BY jobName, start_sec
LIMIT 50
""".strip(),
}

# ─────────────────────────────────────────────
# AWS clients
# ─────────────────────────────────────────────
@st.cache_resource
def get_clients():
    s3         = boto3.client("s3",         region_name=REGION)
    transcribe = boto3.client("transcribe", region_name=REGION)
    athena     = boto3.client("athena",     region_name=REGION)
    return s3, transcribe, athena


# ─────────────────────────────────────────────
# Helpers — S3 / Transcribe
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


def fetch_transcript_from_s3(s3, key, analytics=False):
    try:
        obj  = s3.get_object(Bucket=BUCKET_NAME, Key=key)
        data = json.loads(obj["Body"].read())
        if analytics:
            segments = data.get("Transcript", [])
            if not segments:
                return "No transcript segments found."
            lines = []
            for seg in segments:
                role      = seg.get("ParticipantRole", "?")
                content   = seg.get("Content", "")
                sentiment = seg.get("Sentiment", "")
                sentiment_str = f" [{sentiment}]" if sentiment else ""
                lines.append(f"[{role}]{sentiment_str} {content}")
            return "\n".join(lines)
        else:
            return data["results"]["transcripts"][0]["transcript"]
    except Exception as e:
        return f"Could not fetch transcript: {e}"


def list_output_files(s3, prefix):
    try:
        resp = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=prefix)
        return [
            obj["Key"]
            for obj in resp.get("Contents", [])
            if obj["Key"].endswith(".json")
            and not obj["Key"].endswith(".temp")
            and ".write_access_check" not in obj["Key"]
        ]
    except Exception:
        return []


def status_icon(status):
    return {"COMPLETED": "✅", "IN_PROGRESS": "⏳", "FAILED": "❌", "QUEUED": "🕐"}.get(status, "ℹ️")


# ─────────────────────────────────────────────
# Helpers — Athena
# ─────────────────────────────────────────────
def run_athena_query(athena, sql: str) -> tuple[str, str]:
    """Submit query, return (execution_id, status)."""
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": GLUE_DATABASE},
        WorkGroup=ATHENA_WORKGROUP,
    )
    return resp["QueryExecutionId"], "SUBMITTED"


def poll_athena_query(athena, execution_id: str, timeout: int = 60) -> dict:
    """
    Poll until query finishes or timeout.
    Returns dict with keys: state, reason, execution_id
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp   = athena.get_query_execution(QueryExecutionId=execution_id)
        status = resp["QueryExecution"]["Status"]
        state  = status["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return {
                "state":        state,
                "reason":       status.get("StateChangeReason", ""),
                "execution_id": execution_id,
            }
        time.sleep(2)
    return {"state": "TIMEOUT", "reason": "Query exceeded timeout", "execution_id": execution_id}


def fetch_athena_results(athena, execution_id: str) -> pd.DataFrame:
    """Fetch paginated query results and return a DataFrame."""
    rows     = []
    headers  = []
    paginator = athena.get_paginator("get_query_results")

    for page_num, page in enumerate(paginator.paginate(QueryExecutionId=execution_id)):
        result_rows = page["ResultSet"]["Rows"]
        if page_num == 0:
            headers = [col["VarCharValue"] for col in result_rows[0]["Data"]]
            result_rows = result_rows[1:]
        for row in result_rows:
            rows.append([col.get("VarCharValue", "") for col in row["Data"]])

    return pd.DataFrame(rows, columns=headers) if rows else pd.DataFrame()


def get_athena_query_cost(athena, execution_id: str) -> str:
    """Return data scanned string for cost awareness."""
    try:
        resp  = athena.get_query_execution(QueryExecutionId=execution_id)
        stats = resp["QueryExecution"].get("Statistics", {})
        bytes_scanned = stats.get("DataScannedInBytes", 0)
        mb = bytes_scanned / (1024 * 1024)
        cost = (bytes_scanned / (1024 ** 4)) * 5  # $5 per TB
        return f"{mb:.2f} MB scanned · estimated cost ${cost:.6f}"
    except Exception:
        return ""


# ═══════════════════════════════════════════════
# Page layout
# ═══════════════════════════════════════════════
st.set_page_config(
    page_title="Transcribe Pipeline",
    page_icon="🎙️",
    layout="wide",
)

st.title("🎙️ AWS Transcribe Pipeline")
st.caption(f"Bucket: `{BUCKET_NAME}` · Region: `{REGION}` · Glue DB: `{GLUE_DATABASE}`")
st.divider()

s3, transcribe, athena = get_clients()

tab_upload, tab_monitor, tab_results, tab_athena = st.tabs(
    ["📤 Upload & Trigger", "📊 Monitor Jobs", "📄 View Transcripts", "🔍 Athena Query"]
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

    if is_analytics:
        st.info(
            "Call Analytics requires a **stereo (2-channel)** MP3 file. "
            "Channel 0 = CUSTOMER, Channel 1 = AGENT. "
            "Use the sample files in `On_2_Channels/`."
        )

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
            with st.spinner(f"Uploading to `s3://{BUCKET_NAME}/{prefix}`..."):
                try:
                    key = upload_to_s3(s3, uploaded_file.read(), uploaded_file.name, prefix)
                    st.success(f"Uploaded → `{key}`")
                    st.info("Lambda triggered. Switch to **Monitor Jobs** tab — jobs complete in 1-3 min.")
                except Exception as e:
                    st.error(f"Upload failed: {e}")

    st.divider()
    st.subheader("S3 Bucket Contents")
    if st.button("🔄 Refresh bucket view"):
        st.rerun()

    col_a, col_b = st.columns(2)
    with col_a:
        st.markdown("**`input/`** — standard transcription")
        try:
            resp  = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=STANDARD_PREFIX)
            files = [o["Key"] for o in resp.get("Contents", []) if not o["Key"].endswith("/")]
            for f in files:
                st.code(f, language=None)
            if not files:
                st.caption("No files yet")
        except Exception as e:
            st.warning(str(e))

    with col_b:
        st.markdown("**`analytics/`** — call analytics")
        try:
            resp  = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=ANALYTICS_PREFIX)
            files = [o["Key"] for o in resp.get("Contents", []) if not o["Key"].endswith("/")]
            for f in files:
                st.code(f, language=None)
            if not files:
                st.caption("No files yet")
        except Exception as e:
            st.warning(str(e))


# ═══════════════════════════════════════════════
# TAB 2 — Monitor Jobs
# ═══════════════════════════════════════════════
with tab_monitor:
    st.subheader("Transcription Job Monitor")
    job_type      = st.radio("Job type", ["Standard", "Call Analytics"], horizontal=True)
    analytics_mode = job_type == "Call Analytics"

    col1, col2 = st.columns([2, 1])
    with col1:
        job_name_input = st.text_input(
            "Job name (leave blank to list recent)",
            placeholder="e.g. job_transcribe_1.mp3  or  analytics_InboundCall.mp3_20260812...",
        )
    with col2:
        st.markdown("<br>", unsafe_allow_html=True)
        check_btn = st.button("🔍 Check Status", use_container_width=True)

    if check_btn and job_name_input.strip():
        s = get_job_status(transcribe, job_name_input.strip(), analytics=analytics_mode)
        st.metric("Job Status", f"{status_icon(s)} {s}")

    st.divider()
    st.subheader("Recent Jobs")
    col_r1, col_r2 = st.columns(2)

    with col_r1:
        st.markdown("**Standard Transcription**")
        if st.button("🔄 Refresh Standard Jobs"):
            try:
                resp = transcribe.list_transcription_jobs(MaxResults=10)
                for j in resp.get("TranscriptionJobSummaries", []):
                    s = j["TranscriptionJobStatus"]
                    st.write(f"{status_icon(s)} `{j['TranscriptionJobName']}` — {s}")
            except Exception as e:
                st.error(str(e))

    with col_r2:
        st.markdown("**Call Analytics**")
        if st.button("🔄 Refresh Analytics Jobs"):
            try:
                resp = transcribe.list_call_analytics_jobs(MaxResults=10)
                for j in resp.get("CallAnalyticsJobSummaries", []):
                    s = j["CallAnalyticsJobStatus"]
                    st.write(f"{status_icon(s)} `{j['CallAnalyticsJobName']}` — {s}")
            except Exception as e:
                st.error(str(e))


# ═══════════════════════════════════════════════
# TAB 3 — View Transcripts
# ═══════════════════════════════════════════════
with tab_results:
    st.subheader("View Transcript Output")
    result_type         = st.radio("Output type", ["Standard", "Call Analytics"], horizontal=True)
    is_analytics_result = result_type == "Call Analytics"
    search_prefix       = ANALYTICS_OUTPUT_PREFIX if is_analytics_result else OUTPUT_PREFIX

    if st.button("🔄 Refresh output list"):
        st.rerun()

    output_files = list_output_files(s3, search_prefix)

    if output_files:
        selected_key = st.selectbox(
            "Select output file",
            options=output_files,
            format_func=lambda x: x.split("/")[-1],
        )
        job_name = selected_key.split("/")[-1].replace(".json", "")

        with st.spinner("Loading transcript..."):
            transcript = fetch_transcript_from_s3(s3, selected_key, analytics=is_analytics_result)

        if transcript.startswith("Could not fetch"):
            st.error(transcript)
        else:
            st.success(f"✅ Transcript for `{job_name}`")
            if is_analytics_result:
                st.caption("Format: [ROLE][SENTIMENT] content — Channel 0 = CUSTOMER, Channel 1 = AGENT")
            st.text_area("Transcript", value=transcript, height=350, label_visibility="collapsed")
            st.download_button("⬇️ Download as .txt", data=transcript,
                               file_name=f"{job_name}.txt", mime="text/plain")
    else:
        st.info(f"No output files found in `{search_prefix}`. Upload a file and wait for the job to complete.")

    st.divider()
    st.subheader("All Output Files in S3")
    std_files       = list_output_files(s3, OUTPUT_PREFIX)
    analytics_files = list_output_files(s3, ANALYTICS_OUTPUT_PREFIX)
    col_o1, col_o2  = st.columns(2)
    with col_o1:
        st.markdown(f"**`output/results/`** ({len(std_files)} files)")
        for f in std_files:
            st.code(f.split("/")[-1], language=None)
        if not std_files:
            st.caption("No standard results yet")
    with col_o2:
        st.markdown(f"**`output/results/analytics/`** ({len(analytics_files)} files)")
        for f in analytics_files:
            st.code(f.split("/")[-1], language=None)
        if not analytics_files:
            st.caption("No analytics results yet")


# ═══════════════════════════════════════════════
# TAB 4 — Athena Query
# ═══════════════════════════════════════════════
with tab_athena:
    st.subheader("🔍 Query Transcribe Output with Athena")
    st.caption(
        f"Glue database: `{GLUE_DATABASE}` · "
        f"Tables: `{TABLE_STANDARD}` (standard) · `{TABLE_ANALYTICS}` (call analytics) · "
        f"Workgroup: `{ATHENA_WORKGROUP}`"
    )

    # ── Preset query picker ──────────────────────────────────
    st.markdown("#### Pick a preset or write your own SQL")
    preset_options = ["— write my own SQL —"] + list(PRESET_QUERIES.keys())
    selected_preset = st.selectbox("Preset queries", options=preset_options, label_visibility="collapsed")

    default_sql = PRESET_QUERIES.get(selected_preset, "SELECT * FROM " + GLUE_DATABASE + "." + TABLE_STANDARD + " LIMIT 10")

    sql_input = st.text_area(
        "SQL",
        value=default_sql,
        height=180,
        help="Standard Presto/Athena SQL. Use CROSS JOIN UNNEST() to expand arrays.",
        label_visibility="collapsed",
    )

    col_run, col_timeout = st.columns([1, 2])
    with col_run:
        run_btn = st.button("▶️ Run Query", type="primary", use_container_width=True)
    with col_timeout:
        timeout_sec = st.slider("Timeout (seconds)", min_value=15, max_value=120, value=60, step=5)

    # ── Schema reference ─────────────────────────────────────
    with st.expander("📐 Table schema reference"):
        col_s1, col_s2 = st.columns(2)
        with col_s1:
            st.markdown(f"**`{TABLE_STANDARD}`** — standard transcription")
            st.code("""jobName          string
status           string
results
  language_code  string
  transcripts[]
    transcript   string
  items[]
    type         string   -- pronunciation | punctuation
    start_time   string
    end_time     string
    alternatives[]
      content    string
      confidence string
  audio_segments[]
    transcript   string
    start_time   string
    end_time     string""", language="yaml")

        with col_s2:
            st.markdown(f"**`{TABLE_ANALYTICS}`** — call analytics")
            st.code("""jobName          string
jobStatus        string
languageCode     string
conversationcharacteristics
  TotalConversationDurationMillis  int
  TalkTime
    DetailsByParticipant
      AGENT.TotalTimeMillis        int
      CUSTOMER.TotalTimeMillis     int
  TalkSpeed
    DetailsByParticipant
      AGENT.AverageWordsPerMinute  int
      CUSTOMER.AverageWordsPerMinute int
  Interruptions
    TotalCount                     int
    TotalTimeMillis                int
  Sentiment
    OverallSentiment
      AGENT                        double
      CUSTOMER                     double
transcript[]
  ParticipantRole  string   -- AGENT | CUSTOMER
  Content          string
  Sentiment        string
  BeginOffsetMillis  int
  EndOffsetMillis    int""", language="yaml")

    # ── Run query ────────────────────────────────────────────
    if run_btn and sql_input.strip():
        with st.spinner("Submitting query to Athena..."):
            try:
                exec_id, _ = run_athena_query(athena, sql_input.strip())
                st.info(f"Query ID: `{exec_id}`")
            except Exception as e:
                st.error(f"Failed to submit query: {e}")
                st.stop()

        progress = st.progress(0, text="Waiting for Athena...")
        result   = None
        deadline = time.time() + timeout_sec
        step     = 0

        while time.time() < deadline:
            try:
                resp   = athena.get_query_execution(QueryExecutionId=exec_id)
                state  = resp["QueryExecution"]["Status"]["State"]
                reason = resp["QueryExecution"]["Status"].get("StateChangeReason", "")
            except Exception as e:
                st.error(f"Error polling query: {e}")
                break

            elapsed  = timeout_sec - (deadline - time.time())
            pct      = min(int((elapsed / timeout_sec) * 100), 95)
            progress.progress(pct, text=f"State: {state}...")

            if state == "SUCCEEDED":
                progress.progress(100, text="✅ Query complete")
                result = {"state": state, "reason": reason, "execution_id": exec_id}
                break
            elif state in ("FAILED", "CANCELLED"):
                progress.progress(100, text=f"❌ {state}")
                result = {"state": state, "reason": reason, "execution_id": exec_id}
                break

            step += 1
            time.sleep(2)

        if result is None:
            progress.progress(100, text="⏱️ Timed out")
            st.warning(f"Query timed out after {timeout_sec}s. Check the AWS Athena Console for results.")
            st.stop()

        # ── Show results ─────────────────────────────────────
        if result["state"] == "SUCCEEDED":
            cost_str = get_athena_query_cost(athena, exec_id)
            if cost_str:
                st.caption(f"💰 {cost_str}")

            try:
                df = fetch_athena_results(athena, exec_id)
            except Exception as e:
                st.error(f"Could not fetch results: {e}")
                st.stop()

            if df.empty:
                st.info("Query returned no rows.")
            else:
                st.success(f"{len(df)} row(s) returned")
                st.dataframe(df, use_container_width=True)

                # Download as CSV
                csv = df.to_csv(index=False)
                st.download_button(
                    label="⬇️ Download results as CSV",
                    data=csv,
                    file_name=f"athena_results_{exec_id[:8]}.csv",
                    mime="text/csv",
                )

                # Quick visualisation for analytics sentiment
                if "agent_sentiment" in df.columns and "customer_sentiment" in df.columns:
                    st.divider()
                    st.markdown("#### Sentiment overview")
                    chart_df = df[["jobName", "agent_sentiment", "customer_sentiment"]].copy()
                    chart_df = chart_df.set_index("jobName")
                    chart_df = chart_df.apply(pd.to_numeric, errors="coerce")
                    st.bar_chart(chart_df)

                # Quick visualisation for talk time
                if "agent_talk_sec" in df.columns and "customer_talk_sec" in df.columns:
                    st.divider()
                    st.markdown("#### Talk time (seconds)")
                    chart_df = df[["jobName", "agent_talk_sec", "customer_talk_sec"]].copy()
                    chart_df = chart_df.set_index("jobName")
                    chart_df = chart_df.apply(pd.to_numeric, errors="coerce")
                    st.bar_chart(chart_df)

        else:
            st.error(f"Query {result['state']}: {result['reason']}")
            st.code(sql_input, language="sql")

    # ── Recent query history ──────────────────────────────────
    st.divider()
    with st.expander("🕐 Recent query history (last 5)"):
        try:
            history = athena.list_query_executions(WorkGroup=ATHENA_WORKGROUP, MaxResults=5)
            ids     = history.get("QueryExecutionIds", [])
            if ids:
                for qid in ids:
                    try:
                        qe     = athena.get_query_execution(QueryExecutionId=qid)
                        qstate = qe["QueryExecution"]["Status"]["State"]
                        qsql   = qe["QueryExecution"]["Query"][:120]
                        st.markdown(f"`{qid[:8]}...` — **{qstate}** — `{qsql}...`")
                    except Exception:
                        pass
            else:
                st.caption("No recent queries.")
        except Exception as e:
            st.caption(f"Could not load history: {e}")
