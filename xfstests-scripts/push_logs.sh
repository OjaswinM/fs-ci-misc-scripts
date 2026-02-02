#!/bin/bash
set -x

push_logs_to_server() {
    local run_id=$1
    local local_dir=$2
    if [[ -z "$run_id" || -z "$local_dir"  ]]; then
        echo "Usage: push_logs <run_id> <local_zip_dir>"
        return 1
    fi

    local zip_name="/tmp/${run_id}.zip"
    local remote_dir="/var/log/ci-dashboard/$run_id"

    echo "Zipping logs to $zip_name..."
    pushd $local_dir
    echo "in dir: `pwd`"
    zip -r "$zip_name" "."
    popd

    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

    sshpass -p "$remote_pass" ssh $ssh_opts "${remote_user}@${remote_host}" "mkdir -p \"$remote_dir\""
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "ERROR: Failed to create directory on remote host"
      exit 1
    fi
    
    echo "Copying zip archive to $remote_host..."
    sshpass -p "$remote_pass" scp $ssh_opts "$zip_name" \
      "${remote_user}@${remote_host}:$remote_dir/"
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "ERROR: Failed to copy zip archive to remote host"
      exit 1
    fi

    echo "Unzipping on remote..."
    sshpass -p "$remote_pass" ssh $ssh_opts "${remote_user}@${remote_host}" "unzip -o $remote_dir/$(basename "$zip_name") -d $remote_dir && rm $remote_dir/$(basename "$zip_name")"
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "ERROR: Failed to unzip on remote"
      exit 1
    fi

    echo "Cleaning up local zip..."
    rm "$zip_name"
}

upload_results() {
    local json_file=$1
    #local url="http://$remote_host:3000/api/import-test-run"
    local url=$dashboard_insert_url

    if [[ -z "$json_file" || ! -f "$json_file" ]]; then
        echo "Error: JSON file '$json_file' not found."
        return 1
    fi

    echo "Posting test run from $json_file to $url..."
    response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
        -H "Content-Type: application/json" \
        -d @"$json_file")

    body=$(echo "$response" | sed '$d')
    status=$(echo "$response" | tail -n1)

    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        echo "Success: Server responded with status $status"
        # echo "$body"
	testTypeId=$(echo "$body" | jq -r '.testTypeId')
	subtypeId=$(echo "$body" | jq -r '.subtypeId')
	runId=$(echo "$body" | jq -r '.runId')
	run_url=http://$remote_host:$remote_port/test-types/$testTypeId/subtypes/$subtypeId/runs/$runId
	echo "Dashboard URL of run: $run_url"
    else
        echo "Error: Server responded with status $status"
        echo "$body" >&2
        return 1
    fi
}

HOSTDETAILS_FILE="$(dirname "$0")/hostdetails"

required_vars=(
  remote_host
  remote_user
  remote_pass
  remote_port
  dashboard_insert_url
)

if [[ -f "$HOSTDETAILS_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$HOSTDETAILS_FILE"
else
	# This happens in jnekins run
	echo "hostdetails not found, using environment variables"
fi

# ---- validation ----
missing=()

for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    missing+=("$v")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: Missing required configuration values:"
  for v in "${missing[@]}"; do
    echo "  - $v"
  done
  echo
  echo "Provide them via hostdetails file or environment variables."
  exit 1
fi

# push the logs to dashboard server
push_logs_to_server "$1" "$2"

# finally upload the results to the dashboard db
upload_results "$3"
