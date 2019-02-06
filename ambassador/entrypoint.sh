#!/bin/sh

# Copyright 2018 Datawire. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

if [ -z "$AMBASSADOR_NAMESPACE" ]; then
    AMBASSADOR_NAMESPACE=default
fi

AMBASSADOR_ROOT="/ambassador"
AMBASSADOR_CONFIG_BASE_DIR="${AMBASSADOR_CONFIG_BASE_DIR:-$AMBASSADOR_ROOT}"
CONFIG_DIR="${AMBASSADOR_CONFIG_BASE_DIR}/ambassador-config"

# If AMBASSADOR_NO_KUBEWATCH is set, it means that we're not supposed to try
# to watch for Kubernetes stuff at all. If it's NOT set - so we _are_ allowed
# to watch, which is the default - then we'll use the kube-sync directory to
# hold the configurations we find when we watch.
#
# The user can override AMBASSADOR_SYNC_DIR, too.
if [ -z "${AMBASSADOR_SYNC_DIR}" ]; then
    AMBASSADOR_SYNC_DIR="${AMBASSADOR_CONFIG_BASE_DIR}/kube-sync"
fi

ENVOY_DIR="${AMBASSADOR_CONFIG_BASE_DIR}/envoy"
export ENVOY_DIR

ENVOY_CONFIG_FILE="${ENVOY_DIR}/envoy.json"
TEMP_ENVOY_CONFIG_FILE="/tmp/envoy.json"

# The bootstrap file really is in the config base dir, not the Envoy dir.
ENVOY_BOOTSTRAP_FILE="${AMBASSADOR_CONFIG_BASE_DIR}/bootstrap-ads.json"
export ENVOY_BOOTSTRAP_FILE

# Set AMBASSADOR_DEBUG to things separated by spaces to enable debugging.
check_debug () {
    word="$1"
    args="$2"

    # I'm not sure if ${x:---debug} works, but it's too weird to read anyway.
    if [ -z "$args" ]; then
        args="--debug"
    fi

    if [ $(echo "$AMBASSADOR_DEBUG" | grep -c "$word" || :) -gt 0 ]; then
        echo "$args"
    else
        echo ""
    fi
}

DIAGD_DEBUG=$(check_debug "diagd")
KUBEWATCH_DEBUG=$(check_debug "kubewatch")

ENVOY_DEBUG=$(check_debug "envoy" "-l debug")
export ENVOY_DEBUG

DIAGD_K8S=--k8s
DEMO_MODE=

if [ "$1" == "--demo" ]; then
    # This is _not_ meant to be overridden by AMBASSADOR_CONFIG_BASE_DIR.
    # It's baked into a specific location during the build process.
    CONFIG_DIR="$AMBASSADOR_ROOT/ambassador-demo-config"

    # Demo mode doesn't watch for Kubernetes changes.
    DIAGD_K8S=
    AMBASSADOR_NO_KUBERNETES=no_kubernetes
    AMBASSADOR_SYNC_DIR=
fi

mkdir -p "${CONFIG_DIR}"
mkdir -p "${ENVOY_DIR}"

DELAY=${AMBASSADOR_RESTART_TIME:-1}

APPDIR=${APPDIR:-"$AMBASSADOR_ROOT"}

# If we don't set PYTHON_EGG_CACHE explicitly, /.cache is set by default, which fails when running as a non-privileged
# user
export PYTHON_EGG_CACHE="${PYTHON_EGG_CACHE:-$APPDIR}/.cache"

export PYTHONUNBUFFERED=true

pids=""

ambassador_exit() {
    RC=${1:-0}

    if [ -n "$AMBASSADOR_EXIT_DELAY" ]; then
        echo "AMBASSADOR: sleeping for debug"
        sleep $AMBASSADOR_EXIT_DELAY
    fi

    echo "AMBASSADOR: shutting down ($RC)"
    exit $RC
}

diediedie() {
    NAME=$1
    STATUS=$2

    if [ $STATUS -eq 0 ]; then
        echo "AMBASSADOR: $NAME claimed success, but exited \?\?\?\?"
    else
        echo "AMBASSADOR: $NAME exited with status $STATUS"
    fi

    ambassador_exit 1
}

handle_chld() {
    trap - CHLD
    local tmp
    for entry in $pids; do
        local pid="${entry%:*}"
        local name="${entry#*:}"
        if [ ! -d "/proc/${pid}" ]; then
            wait "${pid}"
            STATUS=$?
            # echo "AMBASSADOR: $name exited: $STATUS"
            # echo "AMBASSADOR: shutting down"
            diediedie "${name}" "$STATUS"
        else
            tmp="${tmp:+${tmp} }${entry}"
        fi
    done

    pids="$tmp"
    trap "handle_chld" CHLD
}

handle_int() {
    echo "Exiting due to Control-C"
}

# set -o monitor
trap "handle_chld" CHLD
trap "handle_int" INT

#KUBEWATCH_DEBUG="--debug"

# Start by reading config from ${CONFIG_DIR} itself, to get our cluster ID.
# XXX Ditch this, really.
cluster_id=$(/usr/bin/python3 "$APPDIR/kubewatch.py" $KUBEWATCH_DEBUG cluster-id "${CONFIG_DIR}" "$ENVOY_CONFIG_FILE")

STATUS=$?

if [ $STATUS -ne 0 ]; then
    diediedie "kubewatch cluster-id" "$STATUS"
fi

# Set Ambassador's cluster ID here. We can do this unconditionally because if AMBASSADOR_CLUSTER_ID was set
# before, kubewatch sync will use it.
AMBASSADOR_CLUSTER_ID="${cluster_id}"
export AMBASSADOR_CLUSTER_ID
echo "AMBASSADOR: using cluster ID $AMBASSADOR_CLUSTER_ID"

# Empty Envoy directory, hence no config via ADS yet.
mkdir -p "${ENVOY_DIR}"

echo "AMBASSADOR: starting ads"
./ambex "${ENVOY_DIR}" &
AMBEX_PID="$!"
pids="${pids:+${pids} }${AMBEX_PID}:ambex"

#echo "AMBASSADOR: validation envoy configuration"
## Envoy does not validate with @type field in there, so removing it
#jq 'del(."@type")' "${ENVOY_CONFIG_FILE}" > "${TEMP_ENVOY_CONFIG_FILE}"
#envoy -c "${TEMP_ENVOY_CONFIG_FILE}" --mode validate
#STATUS=$?
#
#if [ $STATUS -ne 0 ]; then
#    cat "$TEMP_ENVOY_CONFIG_FILE"
#    diediedie "envoy validation" "$STATUS"
#fi

# We can't start Envoy until the initial config happens, which means that diagd has to start it.
#echo "AMBASSADOR: starting Envoy"
#envoy $ENVOY_DEBUG -c "${ENVOY_BOOTSTRAP_FILE}" &
#pids="${pids:+${pids} }$!:envoy"

echo "AMBASSADOR: starting diagd"

diagd "${CONFIG_DIR}" "${ENVOY_BOOTSTRAP_FILE}" "${ENVOY_CONFIG_FILE}" $DIAGD_DEBUG $DIAGD_K8S \
      --kick "sh /ambassador/kick_ads.sh $AMBEX_PID" --notices "${AMBASSADOR_CONFIG_BASE_DIR}/notices.json" &
pids="${pids:+${pids} }$!:diagd"

# Wait for diagd to start
tries_left=10
delay=1
while [ $tries_left -gt 0 ]; do
    echo "AMBASSADOR: pinging diagd ($tries_left)..."

    status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8877/_internal/v0/ping)

    if [ "$status" = "200" ]; then
        break
    fi

    tries_left=$(( $tries_left - 1 ))
    sleep $delay
    delay=$(( $delay * 2 ))
    if [ $delay -gt 10 ]; then delay=5; fi
done

if [ $tries_left -le 0 ]; then
    echo "AMBASSADOR: giving up on diagd and hoping for the best..."
else
    echo "AMBASSADOR: diagd running"
fi

if [ -z "${AMBASSADOR_NO_KUBERNETES}" ]; then
    KUBEWATCH_SYNC_CMD="python3 /ambassador/post_update.py"

    KUBEWATCH_NAMESPACE_ARG=""

    if [ -n "$AMBASSADOR_SINGLE_NAMESPACE" ]; then
        KUBEWATCH_NAMESPACE_ARG="--namespace $AMBASSADOR_NAMESPACE"
    fi

    set -x
    "$APPDIR/kubewatch" ${KUBEWATCH_NAMESPACE_ARG} --sync "$KUBEWATCH_SYNC_CMD" --warmup-delay 10s secrets services &
    set +x
    pids="${pids:+${pids} }$!:kubewatch"
fi

echo "AMBASSADOR: waiting"
echo "PIDS: $pids"
wait

ambassador_exit 0
