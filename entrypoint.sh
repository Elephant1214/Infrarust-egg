#!/bin/bash

# Forward signals to child process
function handle_signal {
    kill -$1 "$child_pid" 2>/dev/null
}


if [ -f "/home/container/config.yml" ] && [ ! -f "/home/container/infrarust.toml" ]; then
    echo "Detected V1 configuration. Running automatic migration..."
    mkdir -p /home/container/servers
    mkdir -p /home/container/.v1-backup

    if [ -d "/home/container/proxies" ]; then
        /bin/infrarust migrate /home/container/proxies \
            --output /home/container/servers \
            --config /home/container/config.yml || true
    fi

    mv /home/container/config.yml /home/container/.v1-backup/
    [ -d "/home/container/proxies" ] && mv /home/container/proxies /home/container/.v1-backup/

    echo "V1 migration complete. Old files backed up to .v1-backup/"
fi


if [ -d "/home/container/proxies" ]; then
    shopt -s nullglob
    yml_files=(/home/container/proxies/*.yml)
    shopt -u nullglob

    if [ ${#yml_files[@]} -gt 0 ]; then
        echo "Found leftover V1 proxy YAML files. Converting to V2 TOML..."
        mkdir -p /home/container/servers
        mkdir -p /home/container/.v1-backup/proxies

        for yml_file in "${yml_files[@]}"; do
            basename=$(basename "$yml_file" .yml)
            toml_file="/home/container/servers/${basename}.toml"

            # Parse addresses from YAML (format: "  - address:port")
            addresses=""
            while IFS= read -r line; do
                addr=$(echo "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | xargs)
                if [ -n "$addr" ]; then
                    [ -n "$addresses" ] && addresses+=", "
                    addresses+="\"${addr}\""
                fi
            done < "$yml_file"

            # Parse domains if present
            domains=""
            in_domains=false
            while IFS= read -r line; do
                if echo "$line" | grep -q "^domains:"; then
                    in_domains=true
                    continue
                fi
                if $in_domains; then
                    if echo "$line" | grep -q "^[[:space:]]*-"; then
                        dom=$(echo "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | xargs)
                        if [ -n "$dom" ]; then
                            [ -n "$domains" ] && domains+=", "
                            domains+="\"${dom}\""
                        fi
                    else
                        in_domains=false
                    fi
                fi
            done < "$yml_file"

            # Write TOML file
            {
                [ -n "$domains" ] && echo "domains = [${domains}]"
                [ -n "$addresses" ] && echo "addresses = [${addresses}]"
            } > "$toml_file"

            mv "$yml_file" /home/container/.v1-backup/proxies/
            echo "  Converted ${basename}.yml -> ${basename}.toml"
        done
    fi
fi


BIND_PORT="${SERVER_PORT:-25565}"

cat > /home/container/infrarust.toml << TOML
bind = "0.0.0.0:${BIND_PORT}"
servers_dir = "/home/container/servers"

[rate_limit]
max_connections = ${RATE_LIMIT_MAX:-10}
window = "${RATE_LIMIT_WINDOW:-1}s"

[keepalive]
time = "${KEEPALIVE_TIME:-30}s"
interval = "${KEEPALIVE_INTERVAL:-10}s"
retries = ${KEEPALIVE_RETRIES:-3}
TOML

mkdir -p /home/container/servers

function createServerToml {
    local proxyNumber=$1
    local domains_var="DOMAINS_${proxyNumber}"
    local addresses_var="ADDRESSES_${proxyNumber}"

    if [ -z "${!domains_var}" ]; then
        echo "DOMAINS_${proxyNumber} is not set."
        exit 1
    fi

    if [ -z "${!addresses_var}" ]; then
        echo "ADDRESSES_${proxyNumber} is not set."
        exit 1
    fi

    local file="/home/container/servers/${proxyNumber}.toml"

    # Build domains TOML array
    local domains_toml="["
    local first=true
    IFS=',' read -ra DOMS <<< "${!domains_var}"
    for dom in "${DOMS[@]}"; do
        dom=$(echo "$dom" | xargs)
        [ -z "$dom" ] && continue
        $first || domains_toml+=", "
        domains_toml+="\"${dom}\""
        first=false
    done
    domains_toml+="]"

    # Build addresses TOML array
    local addresses_toml="["
    first=true
    IFS=',' read -ra ADDRS <<< "${!addresses_var}"
    for addr in "${ADDRS[@]}"; do
        addr=$(echo "$addr" | xargs)
        [ -z "$addr" ] && continue
        $first || addresses_toml+=", "
        addresses_toml+="\"${addr}\""
        first=false
    done
    addresses_toml+="]"

    cat > "$file" << SERVERTOML
domains = ${domains_toml}
addresses = ${addresses_toml}
SERVERTOML

    echo "Generated server config: ${proxyNumber}.toml"
}

# Only generate from env vars if PROXY_COUNT is set (not manual mode)
if [ -n "$PROXY_COUNT" ]; then
    if ! [[ $PROXY_COUNT =~ ^[0-9]+$ ]]; then
        echo "PROXY_COUNT is not a number"
        exit 1
    fi

    for i in $(seq 1 $PROXY_COUNT); do
        createServerToml $i
    done
fi


MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))

trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP
trap 'handle_signal USR1' USR1
trap 'handle_signal USR2' USR2

${MODIFIED_STARTUP} &

child_pid=$!

wait "$child_pid"
exit_code=$?

exit $exit_code
