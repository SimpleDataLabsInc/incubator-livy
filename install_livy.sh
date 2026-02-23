#!/bin/bash
# Livy init-action for Dataproc 3.x (Spark 4 / Scala 2.13)
#
# What this script does:
# - Runs ONLY on master node
# - Downloads a Livy Scala 2.13 distro zip from a placeholder URL (YOU MUST SET IT)
# - Verifies it is a ZIP and that it's a Scala 2.13 build (best-effort heuristic)
# - If any existing Livy install is found, it is REMOVED ("nuked")
# - Installs Livy under /usr/local/lib/<extracted-dir> and symlinks /usr/local/lib/livy -> that dir
# - Writes livy.conf + livy-env.sh safely
# - Creates/updates systemd unit and starts Livy
# - Fully non-interactive (no prompts) and safe under set -euo pipefail

set -euo pipefail
IFS=$'\n\t'

log() { echo "[$(date -Is)] $*"; }

# === REQUIRED: set this to your hosted Scala 2.13 Livy binary zip ===
# Examples:
#   gs://my-bucket/livy/apache-livy-0.9.0-incubating_2.13-bin.zip
#   https://storage.googleapis.com/my-bucket/livy/apache-livy-0.9.0-incubating_2.13-bin.zip
: "${LIVY_213_ZIP_URL:=gs://qa-prophecy/tmp/apache-livy-0.10.0-incubating-SNAPSHOT_2.13-bin.zip}"

readonly LIVY_SYMLINK="/usr/local/lib/livy"
readonly INSTALL_ROOT="/usr/local/lib"
readonly SPARK_HOME="/usr/lib/spark"
readonly SPARK_CONF_DIR="/etc/spark/conf"
readonly HADOOP_CONF_DIR="/etc/hadoop/conf"

readonly LIVY_TIMEOUT_SESSION="$(
  /usr/share/google/get_metadata_value attributes/livy-timeout-session 2>/dev/null || echo "1h"
)"

# ---- Guard: must run as root (init-actions do); be graceful if run manually ----
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    log "Not root; re-exec with sudo"
    exec sudo -E bash "$0" "$@"
  fi
  log "ERROR: must run as root (no sudo available)."
  exit 1
fi

# ---- Run only on Master ----
role="$(/usr/share/google/get_metadata_value attributes/dataproc-role 2>/dev/null || echo "Master")"
if [[ "$role" != "Master" ]]; then
  log "Not Master (role=$role). Skipping."
  exit 0
fi

# ---- Basic sanity checks ----
[[ -d "$SPARK_HOME" ]] || { log "ERROR: SPARK_HOME not found: $SPARK_HOME"; exit 1; }
[[ -d "$SPARK_CONF_DIR" ]] || { log "ERROR: SPARK_CONF_DIR not found: $SPARK_CONF_DIR"; exit 1; }

# ---- Safe temp + cleanup ----
tmp="$(mktemp -d -t livy-init-XXXX)"
cleanup() { [[ -n "${tmp:-}" && -d "${tmp:-}" ]] && rm -rf "${tmp}"; }
trap cleanup EXIT

# ---- Download helper (supports gs:// and http(s)://) ----
download_to() {
  local url="$1"
  local out="$2"

  if [[ "$url" == __REPLACE_ME_WITH_SCALA_2_13_LIVY_ZIP_URL__ || -z "$url" ]]; then
    log "ERROR: LIVY_213_ZIP_URL is not set. Set it to a Scala 2.13 Livy zip location."
    exit 2
  fi

  if [[ "$url" == gs://* ]]; then
    command -v gsutil >/dev/null 2>&1 || { log "ERROR: gsutil not found but LIVY_213_ZIP_URL is gs://"; exit 3; }
    gsutil -q cp "$url" "$out"
  else
    command -v curl >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 3; }
    curl -fsSL --retry 5 --retry-connrefused --connect-timeout 10 --max-time 600 \
      -o "$out" "$url"
  fi
}

# ---- Parse spark-defaults cleanly (key=value or key value) ----
spark_conf_get() {
  local key="$1"
  local file="${SPARK_CONF_DIR}/spark-defaults.conf"
  [[ -f "$file" ]] || return 0

  awk -v k="$key" '
    $0 ~ "^[[:space:]]*#" {next}
    $1 == k {
      line=$0
      sub("^[^=[:space:]]+[[:space:]]*=?[[:space:]]*", "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
      exit
    }' "$file" || true
}

detect_python3() {
  local candidates=(
    "/opt/conda/default/bin/python3"
    "/opt/conda/miniconda3/bin/python3"
    "/opt/conda/bin/python3"
    "/opt/micromamba/bin/python3"
    "/usr/bin/python3"
  )
  for p in "${candidates[@]}"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  command -v python3 >/dev/null 2>&1 && { command -v python3; return 0; }
  echo ""
}

# ---- Nuke existing Livy install(s) ----
nuke_livy() {
  log "Nuking any existing Livy installation..."

  # Stop systemd service if present (ignore failures)
  if systemctl list-unit-files | grep -q '^livy\.service'; then
    systemctl stop livy.service >/dev/null 2>&1 || true
    systemctl disable livy.service >/dev/null 2>&1 || true
  fi

  rm -f /etc/systemd/system/livy.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  # Remove symlink and common install dirs
  rm -rf "$LIVY_SYMLINK" \
         /var/log/livy \
         /usr/local/lib/apache-livy-* \
         /opt/livy \
         /etc/livy || true

  log "Existing Livy (if any) removed."
}

# ---- Write configs ----
write_livy_conf() {
  local livy_conf_dir="$1"
  mkdir -p "$livy_conf_dir"

  local spark_master deploy_mode
  spark_master="$(spark_conf_get "spark.master")"
  deploy_mode="$(spark_conf_get "spark.submit.deployMode")"

  # Normalize and default
  spark_master="${spark_master#=}"
  deploy_mode="${deploy_mode#=}"
  [[ -n "$spark_master" ]] || spark_master="yarn"
  [[ -n "$deploy_mode" ]] || deploy_mode="client"

  cat >"${livy_conf_dir}/livy.conf" <<EOF
livy.spark.master = ${spark_master}
livy.spark.deploy-mode = ${deploy_mode}
livy.server.session.timeout = ${LIVY_TIMEOUT_SESSION}
livy.repl.enable-hive-context = true
EOF
}

write_livy_env() {
  local livy_conf_dir="$1"
  mkdir -p "$livy_conf_dir"

  local java_home=""
  if command -v java >/dev/null 2>&1; then
    java_home="$(readlink -f "$(command -v java)" | sed 's:/bin/java$::')"
  fi
  local py3; py3="$(detect_python3)"

  {
    echo "export SPARK_HOME=${SPARK_HOME}"
    echo "export SPARK_CONF_DIR=${SPARK_CONF_DIR}"
    echo "export HADOOP_CONF_DIR=${HADOOP_CONF_DIR}"
    echo "export LIVY_LOG_DIR=/var/log/livy"
    [[ -n "$java_home" ]] && echo "export JAVA_HOME=${java_home}"
    if [[ -n "$py3" ]]; then
      echo "export PYSPARK_PYTHON=${py3}"
      echo "export PYSPARK_DRIVER_PYTHON=${py3}"
    fi
  } >"${livy_conf_dir}/livy-env.sh"
  chmod +x "${livy_conf_dir}/livy-env.sh"
}

create_livy_user() {
  if ! id -u livy >/dev/null 2>&1; then
    useradd -G hadoop livy -d /home/livy
  fi
  mkdir -p /home/livy
  chown livy:hadoop /home/livy
}

create_systemd_unit() {
  local livy_home="$1"
  cat >/etc/systemd/system/livy.service <<EOF
[Unit]
Description=Apache Livy service
After=network.target

[Service]
Group=livy
User=livy
Type=forking
WorkingDirectory=/tmp
ExecStart=${livy_home}/bin/livy-server start
ExecStop=${livy_home}/bin/livy-server stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# ---- Main install ----
main() {
  nuke_livy

  log "Downloading Livy Scala 2.13 distro from: ${LIVY_213_ZIP_URL}"
  download_to "${LIVY_213_ZIP_URL}" "${tmp}/livy.zip"

  # Validate zip
  if ! file "${tmp}/livy.zip" | grep -qi "zip archive"; then
    log "ERROR: downloaded file is not a ZIP."
    head -n 60 "${tmp}/livy.zip" || true
    exit 4
  fi

  # Best-effort check: ensure zip name/content suggests 2.13
  # (Not perfect, but catches obvious mistakes like _2.12 distros.)
  if unzip -l "${tmp}/livy.zip" | head -n 50 | grep -qi "_2\.12"; then
    log "ERROR: Livy distro appears to be Scala 2.12. Dataproc 3 requires Scala 2.13."
    exit 5
  fi

  log "Extracting Livy (non-interactive overwrite)..."
  unzip -oq "${tmp}/livy.zip" -d "${INSTALL_ROOT}"

  # Determine extracted top-level directory
  all_entries="$(unzip -Z -1 "${tmp}/livy.zip")"
  extracted_dir="$(echo "$all_entries" | head -n 1 | cut -d/ -f1)"
  livy_home="${INSTALL_ROOT}/${extracted_dir}"

  [[ -d "$livy_home" ]] || { log "ERROR: expected extracted dir not found: $livy_home"; exit 6; }
  [[ -x "${livy_home}/bin/livy-server" ]] || { log "ERROR: livy-server not found in ${livy_home}/bin"; exit 7; }

  create_livy_user

  mkdir -p /var/log/livy
  chown -R livy:livy /var/log/livy

  write_livy_conf "${livy_home}/conf"
  write_livy_env  "${livy_home}/conf"

  chown -R livy:livy "${livy_home}"

  # Point /usr/local/lib/livy to this install
  ln -sfn "${livy_home}" "${LIVY_SYMLINK}"

  create_systemd_unit "${LIVY_SYMLINK}"
  systemctl daemon-reload
  systemctl enable livy.service
  systemctl restart livy.service

  # Smoke check
  sleep 30
  if ! curl -sf http://localhost:8998/sessions >/dev/null 2>&1; then
    log "ERROR: Livy not responding on :8998"
    journalctl -u livy --no-pager -n 200 || true
    exit 8
  fi

  log "Livy is up on http://localhost:8998"
  log "NOTE: This expects a Scala 2.13 Livy distro compatible with Spark 4."
}

main
