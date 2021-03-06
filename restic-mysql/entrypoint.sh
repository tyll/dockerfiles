#!/bin/bash

RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-""}
RESTIC_PASSWORD=${RESTIC_PASSWORD:-""}
DATA_DIRECTORY=${DATA_DIRECTORY:-""}
MYSQL_DATABASE=${MYSQL_DATABASE:-""}

RESTIC_ARGS=${1:-""}

PUSHGATEWAY_URL="${PUSHGATEWAY_URL:-""}"

INSTANCE="${INSTANCE:-""}"
NAMESPACE="${NAMESPACE:-""}"

TIMEOUT="${TIMEOUT:-"60m"}"

set -euo pipefail

timeout_handler() {
	if [ "$?" -eq 124 ]; then
		echo "ERROR: one of restic commands timed out. Try changing TIMEOUT env to higher value."
	fi
}

backup() {
	local start end data stats snapshots group

	echo "INFO: Releasing all locks"
	if ! timeout "$TIMEOUT" restic unlock --remove-all -v; then
		echo "$(date +"%F %T") INFO: creating new repository"
		timeout "$TIMEOUT" restic init
	fi

	echo "INFO: checking repository state"
	timeout "$TIMEOUT" restic check

	echo "INFO: starting new backup"
	start=$(date +%s)
	if [ -n "$DATA_DIRECTORY" ]; then
		restic backup ${RESTIC_ARGS} --host "${INSTANCE:-"$(hostname)"}" "${DATA_DIRECTORY}"
		data="${DATA_DIRECTORY}"
	elif [ -n "${MYSQL_DATABASE}" ]; then
		check_db_vars
		mysqldump -h "$MYSQL_HOST" --single-transaction -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" | restic backup ${RESTIC_ARGS} --host "${INSTANCE:-"$(hostname)"}" --stdin --stdin-filename "${MYSQL_DATABASE}_dump.sql"
		data="${MYSQL_DATABASE}_dump.sql"
	fi
	end=$(date +%s)

	# statistics are not imporatant when not sent to monitoring
	if [ -z "$PUSHGATEWAY_URL" ]; then
		echo "INFO: PUSHGATEWAY_URL not defined, metrics won't be sent"
		exit 0
	fi

	# statistics
	echo "INFO: Backup finished, exporting statistics"
	stats=$(timeout "$TIMEOUT" restic stats --no-lock --json)
	if [ "$stats" = "" ]; then
		echo "ERROR: No backup statistics can be found. Exiting."
		exit 1
	fi

	# snapshots
	snapshots=$(timeout "$TIMEOUT" restic snapshots --no-lock --json | jq length)
	if [ "$snapshots" = "" ]; then
		echo "ERROR: No backup snapshots can be found. Exiting."
		exit 1
	fi

	group="job/backup"
	if [ "${INSTANCE}" != "" ]; then
		group="${group}/instance@base64/$(echo -n "${INSTANCE}" | base64)"
	fi
	if [ "${NAMESPACE}" != "" ]; then
		group="${group}/namespace@base64/$(echo -n "${NAMESPACE}" | base64 )"
	fi
	group="${group}/repository@base64/$(echo -n "${RESTIC_REPOSITORY}" | base64 )"
	group="${group}/data@base64/$(echo -n "${data}" | base64 )"

	cat <<EOF | curl --data-binary @- "${PUSHGATEWAY_URL}/metrics/${group}" 2> /dev/null
# HELP backup_start_last_timestamp_seconds Time whan backup started
# TYPE backup_start_last_timestamp_seconds counter
backup_start_last_timestamp_seconds ${start}
# HELP backup_end_last_timestamp_seconds Time when backup ended
# TYPE backup_end_last_timestamp_seconds counter
backup_end_last_timestamp_seconds ${end}
# HELP backup_size_bytes Backup size
# TYPE backup_size_bytes gauge
backup_size_bytes $(echo "$stats" | jq .total_size)
# HELP backup_files_total Total number of backed up files
# TYPE backup_files_total gauge
backup_files_total $(echo "$stats" | jq .total_file_count)
# HELP backup_snapshots_total Total number of snapshots
# TYPE backup_snapshots_total gauge
backup_snapshots_total ${snapshots}
EOF
	echo "INFO: Statistics exported. All done."
}

check_db_vars() {
	if [ -z "$MYSQL_PASSWORD" ]; then
		echo "ERROR: MYSQL_PASSWORD is not set. Exiting"
		exit 1
	fi
	if [ -z "$MYSQL_USER" ]; then
		echo "ERROR: MYSQL_USER is not set. Exiting"
		exit 1
	fi
	if [ -z "$MYSQL_HOST" ]; then
		echo "ERROR: MYSQL_HOST is not set. Exiting"
		exit 1
	fi
}


check_restic_vars() {
	if [ -z "$RESTIC_REPOSITORY" ]; then
		echo "ERROR: RESTIC_REPOSITORY is not set. Exiting"
		exit 1
	fi
	if [ -z "$RESTIC_PASSWORD" ]; then
		echo "ERROR: RESTIC_PASSWORD is not set. Exiting"
		exit 1
	fi
	if [ -z "$DATA_DIRECTORY" ] && [ -z "$MYSQL_DATABASE" ]; then
		echo "ERROR: Either DATA_DIRECTORY or MYSQL_DATABASE is not set. Exiting"
		exit 1
	fi
}

echo "INFO: Start restic backup"
check_restic_vars

trap timeout_handler EXIT

backup
