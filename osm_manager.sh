#!/usr/bin/env bash
#
# florida-osm-update.sh
#
# Maintains a PostgreSQL/PostGIS database of Florida OSM data, kept in sync
# with Geofabrik's daily diffs. Designed to run from cron.
#
# Phases:
#   1. System check  - ensure required packages and Postgres are installed/running
#   2. Database check - initialize 'gis' DB from florida-latest.osm.pbf if missing
#   3. Health check   - verify the DB is sound before applying updates
#   4. Update loop    - fetch state.txt, download/clip/apply each new .osc.gz
#
# Designed for development on macOS with Homebrew. Logs to $LOG_FILE.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

DB_NAME="${DB_NAME:-gis}"
WORK_DIR="${WORK_DIR:-$HOME/.florida-osm}"
LOG_FILE="${LOG_FILE:-$WORK_DIR/florida-osm.log}"
STATE_FILE="$WORK_DIR/local_state.txt"      # tracks last applied sequence number
LOCK_FILE="$WORK_DIR/florida-osm.lock"
POLY_FILE="$WORK_DIR/florida.poly"
# PBF_FILE is set at runtime by resolve_pbf_filename(), since Geofabrik
# serves a dated filename (e.g. florida-260520.osm.pbf) via redirect.
PBF_FILE=""

GEOFABRIK_BASE="https://download.geofabrik.de/north-america"
PBF_URL="$GEOFABRIK_BASE/us/florida-latest.osm.pbf"
POLY_URL="$GEOFABRIK_BASE/us/florida.poly"
STATE_URL="$GEOFABRIK_BASE/us-updates/state.txt"
UPDATES_BASE="$GEOFABRIK_BASE/us-updates"

REQUIRED_PACKAGES=(postgresql osm2pgsql postgis osmium-tool)

# Map package name -> CLI we expect to find on PATH after install.
# Implemented as a function instead of `declare -A` so it works on macOS's
# stock bash 3.2 (which has no associative arrays).
pkg_binary() {
case "$1" in
postgresql)   echo psql ;;
osm2pgsql)    echo osm2pgsql ;;
postgis)      echo pg_config ;;   # postgis ships the extension; pg_config is part of postgresql
osmium-tool)  echo osmium ;;
*)            echo "" ;;
esac
}

mkdir -p "$WORK_DIR"

# ----------------------------------------------------------------------------
# Logging & error handling
# ----------------------------------------------------------------------------

log() {
local level="$1"; shift
printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@" >&2; }

trap 'log_error "Script failed at line $LINENO (exit $?)"; exit 1' ERR

# ----------------------------------------------------------------------------
# Locking - prevent concurrent runs from cron
# ----------------------------------------------------------------------------

acquire_lock() {
# macOS doesn't ship flock(1). Use it when available, otherwise rely on
    # a PID-file check.
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            log_warn "Another instance holds the lock. Exiting."
            exit 0
        fi
    else
        if [[ -f "$LOCK_FILE.pid" ]] && kill -0 "$(cat "$LOCK_FILE.pid")" 2>/dev/null; then
            log_warn "Another instance is running (pid $(cat "$LOCK_FILE.pid")). Exiting."
            exit 0
        fi
    fi
    echo $$ > "$LOCK_FILE.pid"
    trap 'rm -f "$LOCK_FILE.pid"' EXIT
}

# ----------------------------------------------------------------------------
# Phase 1: System check
# ----------------------------------------------------------------------------

ensure_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        log_error "Homebrew not found. Install from https://brew.sh and re-run."
        exit 1
    fi
}

ensure_packages() {
    log_info "Checking required packages: ${REQUIRED_PACKAGES[*]}"
    local pkg bin missing=()

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        bin=$(pkg_binary "$pkg")
        if command -v "$bin" >/dev/null 2>&1; then
            log_info "  $pkg: present ($bin found)"
        else
            log_warn "  $pkg: missing"
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_info "Installing missing packages via brew: ${missing[*]}"
        brew install "${missing[@]}" 2>&1 | tee -a "$LOG_FILE"
    fi
}

ensure_postgres_running() {
    log_info "Checking PostgreSQL service status"
    # `brew services list` is the source of truth on macOS.
    local status
    status=$(brew services list | awk '$1 ~ /^postgresql/ {print $2; exit}')

    if [[ "$status" != "started" ]]; then
        log_info "PostgreSQL not started (status: ${status:-unknown}). Starting..."
        brew services start postgresql 2>&1 | tee -a "$LOG_FILE"
        # Give it a moment to come up
        sleep 3
    else
        log_info "PostgreSQL is already running"
    fi

    # Verify we can actually connect
    local tries=0
    until pg_isready -q; do
        ((tries++))
        if (( tries > 10 )); then
            log_error "PostgreSQL did not become ready after 10 attempts"
            exit 1
        fi
        sleep 1
    done
    log_info "PostgreSQL accepting connections"
}

# ----------------------------------------------------------------------------
# Phase 2: Database check & initialization
# ----------------------------------------------------------------------------

db_exists() {
    psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1
}

# Resolve the actual filename Geofabrik serves (follows redirects, reads
# Content-Disposition if present, otherwise the final URL's basename).
resolve_pbf_filename() {
local effective
effective=$(curl -sIL -o /dev/null -w '%{url_effective}' "$PBF_URL")
basename "$effective"
}

download_pbf() {
local fname
fname=$(resolve_pbf_filename)
PBF_FILE="$WORK_DIR/$fname"

if [[ -f "$PBF_FILE" ]]; then
log_info "PBF already downloaded: $PBF_FILE"
return
fi

log_info "Downloading $PBF_URL -> $PBF_FILE"
curl -fL --retry 3 -o "$PBF_FILE.partial" "$PBF_URL"
mv "$PBF_FILE.partial" "$PBF_FILE"
}

# Reads the embedded sequence number from the PBF so we know where diffs
# should resume. osmium prints it as "osmosis_replication_sequence_number".
seq_from_pbf() {
osmium fileinfo -e -g header.option.osmosis_replication_sequence_number "$PBF_FILE" 2>/dev/null \
        || echo ""
}

initialize_db() {
log_info "Database '$DB_NAME' does not exist. Initializing..."

download_pbf

log_info "Creating database '$DB_NAME'"
createdb "$DB_NAME"

log_info "Installing PostGIS and hstore extensions"
psql -d "$DB_NAME" -c "CREATE EXTENSION postgis; CREATE EXTENSION hstore;"

log_info "Importing PBF with osm2pgsql (this can take a while)"
osm2pgsql -c -d "$DB_NAME" --slim -G --hstore "$PBF_FILE" 2>&1 | tee -a "$LOG_FILE"

# Seed the local state file with the PBF's replication sequence number so
    # the first cron run knows where to pick up.
    local seq
    seq=$(seq_from_pbf)
    if [[ -n "$seq" ]]; then
        echo "$seq" > "$STATE_FILE"
        log_info "Seeded local state at sequence $seq"
    else
        log_warn "Could not read replication sequence from PBF; first update run will need manual seed"
    fi
}

# ----------------------------------------------------------------------------
# Phase 3: Database health check
# ----------------------------------------------------------------------------

db_health_check() {
    log_info "Running database health checks"

    # 1. Connectivity
    if ! psql -d "$DB_NAME" -tAc "SELECT 1" >/dev/null 2>&1; then
        log_error "Cannot connect to '$DB_NAME'"
        return 1
    fi

    # 2. Extensions present
    local extcount
    extcount=$(psql -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM pg_extension WHERE extname IN ('postgis','hstore')")
    if [[ "$extcount" -ne 2 ]]; then
        log_error "Required extensions missing (postgis+hstore). Found $extcount/2."
        return 1
    fi

    # 3. osm2pgsql tables exist
    local missing_tables=()
    for t in planet_osm_point planet_osm_line planet_osm_polygon planet_osm_roads; do
        if ! psql -d "$DB_NAME" -tAc "SELECT to_regclass('public.$t')" | grep -q "$t"; then
            missing_tables+=("$t")
        fi
    done
    if (( ${#missing_tables[@]} > 0 )); then
        log_error "Missing osm2pgsql tables: ${missing_tables[*]}"
        return 1
    fi

    # 4. Tables have data (sanity, not just schema)
    local rowcount
    rowcount=$(psql -d "$DB_NAME" -tAc "SELECT count(*) FROM planet_osm_point LIMIT 1")
    if [[ "${rowcount:-0}" -lt 1 ]]; then
        log_error "planet_osm_point is empty - DB appears unpopulated"
        return 1
    fi

    log_info "Health check passed (extensions OK, tables OK, ${rowcount} points)"
    return 0
}

# ----------------------------------------------------------------------------
# Phase 4: Updates
# ----------------------------------------------------------------------------

# Parse sequenceNumber from a state.txt file (handles escaped colons).
parse_seq() {
    local file="$1"
    awk -F= '/^sequenceNumber=/ {gsub(/\\:/,":",$2); print $2; exit}' "$file"
}

# Convert a sequence number to its Geofabrik path: 2263 -> 000/002/263
seq_to_path() {
    local seq="$1"
    # Zero-pad to 9 digits
    local padded
    padded=$(printf '%09d' "$seq")
    echo "${padded:0:3}/${padded:3:3}/${padded:6:3}"
}

ensure_poly() {
    if [[ -f "$POLY_FILE" ]]; then
        return
    fi
    log_info "Downloading Florida polygon: $POLY_URL"
    curl -fL --retry 3 -o "$POLY_FILE.partial" "$POLY_URL"
    mv "$POLY_FILE.partial" "$POLY_FILE"
}

get_remote_seq() {
    local tmp="$WORK_DIR/state.remote.txt"
    curl -fLs --retry 3 -o "$tmp" "$STATE_URL"
    parse_seq "$tmp"
}

get_local_seq() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
        return
    fi
    # Fallback: try to read from a previously-downloaded PBF if we can find it.
    local candidate
    candidate=$(ls -t "$WORK_DIR"/florida-*.osm.pbf 2>/dev/null | head -n 1 || true)
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        PBF_FILE="$candidate"
        seq_from_pbf
    fi
}

# Apply a single sequence number: download, clip, apply, record.
apply_one_update() {
    local seq="$1"
    local path; path=$(seq_to_path "$seq")
    local last3="${path##*/}"   # last segment, e.g. "263"

    local osc_url="$UPDATES_BASE/${path}.osc.gz"
    local osc_file="$WORK_DIR/${last3}.osc.gz"
    local clipped="$WORK_DIR/${last3}.florida.osc.gz"

    log_info "Update $seq: downloading $osc_url"
    curl -fL --retry 3 -o "$osc_file.partial" "$osc_url"
    mv "$osc_file.partial" "$osc_file"

    log_info "Update $seq: clipping to Florida polygon"
    # osmium extract refuses to overwrite by default
    rm -f "$clipped"
    osmium extract -p "$POLY_FILE" "$osc_file" -o "$clipped"

    log_info "Update $seq: applying with osm2pgsql"
    osm2pgsql --append --slim -G --hstore -d "$DB_NAME" "$clipped" 2>&1 | tee -a "$LOG_FILE"

    # Record progress only after successful apply
    echo "$seq" > "$STATE_FILE"
    log_info "Update $seq: applied and recorded"

    # Cleanup intermediate files (keep state file; keep PBF)
    rm -f "$osc_file" "$clipped"
}

run_updates() {
    local remote_seq local_seq
    remote_seq=$(get_remote_seq)
    local_seq=$(get_local_seq)

    if [[ -z "$remote_seq" ]]; then
        log_error "Could not read remote sequence number"
        return 1
    fi
    if [[ -z "$local_seq" ]]; then
        log_error "No local sequence number known. Cannot determine starting point."
        return 1
    fi

    log_info "Local sequence: $local_seq, Remote sequence: $remote_seq"

    if (( remote_seq <= local_seq )); then
        log_info "Already up to date"
        return 0
    fi

    ensure_poly

    local seq
    for (( seq = local_seq + 1; seq <= remote_seq; seq++ )); do
        apply_one_update "$seq"
    done

    log_info "Caught up to sequence $remote_seq"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    log_info "===== florida-osm-update starting ====="
    acquire_lock

    ensure_homebrew
    ensure_packages
    ensure_postgres_running

    if ! db_exists; then
        initialize_db
    else
        log_info "Database '$DB_NAME' exists"
    fi

    # Handle --bootstrap: seed the state file from the remote sequence.
    # Useful when the DB exists but the state file was lost (e.g. an
    # earlier run was interrupted before it could write state).
    if [[ "${1:-}" == "--bootstrap" ]]; then
        if [[ -f "$STATE_FILE" ]]; then
            log_info "State file already exists: $STATE_FILE ($(cat "$STATE_FILE"))"
            log_info "Refusing to overwrite. Delete it manually if you really want to re-bootstrap."
            exit 0
        fi
        local remote_seq
        remote_seq=$(get_remote_seq)
        if [[ -z "$remote_seq" ]]; then
            log_error "Could not fetch remote sequence number for bootstrap"
            exit 1
        fi
        echo "$remote_seq" > "$STATE_FILE"
        log_info "Bootstrapped state file with remote sequence $remote_seq"
        log_warn "Note: any updates published between your PBF snapshot and sequence $remote_seq will be skipped."
        exit 0
    fi

    if ! db_health_check; then
        log_error "Health check failed - aborting before updates"
        exit 1
    fi

    run_updates

    log_info "===== florida-osm-update finished ====="
}

main "$@"