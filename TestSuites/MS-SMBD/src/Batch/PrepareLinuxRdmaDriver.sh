#!/usr/bin/env bash
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

set -u

CONFIGURE=false
CONFIG_PATH=""
PRIMARY_INTERFACE=""
SECONDARY_INTERFACE=""
PREFIX_LENGTH="24"
POWERSHELL_VERSION="7.6.5"
MIN_MEMLOCK_BYTES=67108864
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

failure_count=0
warning_count=0

usage() {
    cat <<EOF
Usage: $0 [--configure] [options]

Validates the Linux MS-SMBD driver by default. With --configure, installs
dependencies and applies the required IP, route, hostname, firewall, and
memlock settings.

Options:
  --configure                    Apply missing settings (requires sudo)
    --config=PATH                  Deployment ptfconfig used by the tests
    --primary-interface=NAME       Interface for configured ClientRNicIp
    --secondary-interface=NAME     Interface for configured ClientNonRNicIp
  --help                         Show this help
EOF
}

pass() {
    printf '[PASS] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    failure_count=$((failure_count + 1))
}

warn() {
    printf '[WARN] %s\n' "$1" >&2
    warning_count=$((warning_count + 1))
}

for argument in "$@"; do
    case "$argument" in
        --configure) CONFIGURE=true ;;
        --config=*) CONFIG_PATH="${argument#*=}" ;;
        --primary-interface=*) PRIMARY_INTERFACE="${argument#*=}" ;;
        --secondary-interface=*) SECONDARY_INTERFACE="${argument#*=}" ;;
        --help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$CONFIG_PATH" ]]; then
    config_candidates=(
        "$SCRIPT_DIRECTORY/../Bin/MS-SMBD_ServerTestSuite.deployment.ptfconfig"
        "$SCRIPT_DIRECTORY/../../../../drop/TestSuites/MS-SMBD-user/Bin/MS-SMBD_ServerTestSuite.deployment.ptfconfig"
        "$SCRIPT_DIRECTORY/../../../../drop/TestSuites/MS-SMBD/Bin/MS-SMBD_ServerTestSuite.deployment.ptfconfig"
        "$SCRIPT_DIRECTORY/../TestSuite/MS-SMBD_ServerTestSuite.deployment.ptfconfig"
    )
    for candidate in "${config_candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            CONFIG_PATH="$candidate"
            break
        fi
    done
fi

if [[ -z "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]]; then
    printf 'Deployment configuration was not found. Pass --config=PATH.\n' >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 is required to parse the deployment configuration.\n' >&2
    exit 1
fi

CONFIG_PATH="$(realpath "$CONFIG_PATH")"
mapfile -t config_values < <(python3 - "$CONFIG_PATH" <<'PY'
import sys
import xml.etree.ElementTree as ET

required_names = (
    "ClientRNicIp",
    "ClientNonRNicIp",
    "ServerRNicIp",
    "ServerNonRNicIp",
    "SutComputerName",
)
root = ET.parse(sys.argv[1]).getroot()
properties = {
    node.attrib["name"]: node.attrib.get("value", "")
    for node in root.iter()
    if node.tag.endswith("Property") and "name" in node.attrib
}
missing = [name for name in required_names if not properties.get(name)]
if missing:
    raise SystemExit("Missing required config properties: " + ", ".join(missing))
for name in required_names:
    print(properties[name])
PY
)

if [[ ${#config_values[@]} -ne 5 ]]; then
    printf 'Failed to read required topology values from %s.\n' "$CONFIG_PATH" >&2
    exit 1
fi

CLIENT_RNIC_IP="${config_values[0]}"
CLIENT_SECONDARY_IP="${config_values[1]}"
SERVER_RNIC_IP="${config_values[2]}"
SERVER_SECONDARY_IP="${config_values[3]}"
SUT_NAME="${config_values[4]}"

run_as_root() {
    sudo "$@"
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

interface_for_ip() {
    local address="$1"
    ip -o -4 address show | awk -v address="$address" '$4 ~ ("^" address "/") { print $2; exit }'
}

connection_for_interface() {
    nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null | head -n 1
}

ensure_networkmanager_profile() {
    local interface_name="$1"
    local address="$2"
    local connection_name

    connection_name="$(connection_for_interface "$interface_name")"
    if [[ -n "$connection_name" ]]; then
        return 0
    fi

    if ! $CONFIGURE; then
        fail "No NetworkManager connection owns $interface_name"
        return 1
    fi

    if ! command -v nmcli >/dev/null 2>&1; then
        fail "NetworkManager is required to configure $interface_name but nmcli is unavailable"
        return 1
    fi

    connection_name="${interface_name}-static"
    run_as_root nmcli connection add type ethernet ifname "$interface_name" con-name "$connection_name" >/dev/null 2>&1 || true
    run_as_root nmcli connection modify "$connection_name" ipv4.method manual ipv4.addresses "${address}/${PREFIX_LENGTH}" ipv4.never-default yes connection.autoconnect yes >/dev/null 2>&1 || true
    run_as_root nmcli device connect "$interface_name" >/dev/null 2>&1 || true

    connection_name="$(connection_for_interface "$interface_name")"
    if [[ -n "$connection_name" ]]; then
        pass "Created NetworkManager profile for $interface_name"
        return 0
    fi

    fail "No NetworkManager connection owns $interface_name after configuration"
    return 1
}

ensure_interface_enabled() {
    local interface_name="$1"
    local driver_name=""
    local link_path=""

    if [[ -z "$interface_name" || ! -d "/sys/class/net/$interface_name" ]]; then
        return
    fi

    link_path="$(readlink -f "/sys/class/net/$interface_name/device/driver" 2>/dev/null || true)"
    if [[ -n "$link_path" ]]; then
        driver_name="$(basename "$link_path")"
        if [[ -n "$driver_name" ]] && command -v modprobe >/dev/null 2>&1 && ! lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$driver_name"; then
            if $CONFIGURE; then
                run_as_root modprobe "$driver_name"
                pass "Loaded network driver module $driver_name for $interface_name"
            else
                fail "Network driver module $driver_name is not loaded for $interface_name"
            fi
        fi
    fi

    if ip link show dev "$interface_name" 2>/dev/null | grep -q 'state DOWN'; then
        if $CONFIGURE; then
            run_as_root ip link set "$interface_name" up
            pass "Enabled network interface $interface_name"
        else
            fail "$interface_name is down and must be enabled"
        fi
    else
        pass "$interface_name is already enabled"
    fi
}

ensure_host_route() {
    local interface_name="$1"
    local source_address="$2"
    local peer_address="$3"
    local connection_name
    local route_line

    route_line="$(ip route get "$peer_address" 2>/dev/null | head -n 1 || true)"
    if [[ "$route_line" == *"dev $interface_name"* && "$route_line" == *"src $source_address"* ]]; then
        pass "$peer_address routes through $interface_name with source $source_address"
        return
    fi

    if ! $CONFIGURE; then
        fail "$peer_address does not route through $interface_name with source $source_address"
        return
    fi

    connection_name="$(connection_for_interface "$interface_name")"
    if [[ -z "$connection_name" ]]; then
        fail "No NetworkManager connection owns $interface_name"
        return
    fi

    if ! nmcli -g ipv4.routes connection show "$connection_name" | tr ',' '\n' | grep -q "^${peer_address}/32"; then
        run_as_root nmcli connection modify "$connection_name" +ipv4.routes "${peer_address}/32"
    fi
    run_as_root nmcli device reapply "$interface_name" >/dev/null

    route_line="$(ip route get "$peer_address" 2>/dev/null | head -n 1 || true)"
    if [[ "$route_line" == *"dev $interface_name"* && "$route_line" == *"src $source_address"* ]]; then
        pass "Configured persistent route for $peer_address through $interface_name"
    else
        fail "Persistent route for $peer_address was not applied correctly"
    fi
}

ensure_address() {
    local interface_name="$1"
    local address="$2"
    local connection_name

    if ip -o -4 address show dev "$interface_name" | grep -q " ${address}/${PREFIX_LENGTH} "; then
        pass "$interface_name has ${address}/${PREFIX_LENGTH}"
        return
    fi

    if ! $CONFIGURE; then
        fail "$interface_name does not have ${address}/${PREFIX_LENGTH}"
        return
    fi

    ensure_networkmanager_profile "$interface_name" "$address"
    connection_name="$(connection_for_interface "$interface_name")"
    if [[ -z "$connection_name" ]]; then
        fail "No NetworkManager connection owns $interface_name"
        return
    fi

    run_as_root nmcli connection modify "$connection_name" \
        ipv4.method manual ipv4.addresses "${address}/${PREFIX_LENGTH}" ipv4.never-default yes
    run_as_root nmcli device reapply "$interface_name" >/dev/null

    if ip -o -4 address show dev "$interface_name" | grep -q " ${address}/${PREFIX_LENGTH} "; then
        pass "Configured ${address}/${PREFIX_LENGTH} on $interface_name"
    else
        fail "Failed to configure ${address}/${PREFIX_LENGTH} on $interface_name"
    fi
}

echo "MS-SMBD Linux RDMA driver readiness check"
echo "Config: $CONFIG_PATH"

if $CONFIGURE; then
    sudo -v || exit 1
fi

required_packages=(
    samba git rdma-core ibverbs-utils infiniband-diags net-tools
    build-essential cmake wget libibverbs-dev librdmacm-dev
)

install_missing_packages() {
    local missing_packages=()
    local package_name

    for package_name in "${required_packages[@]}"; do
        if ! package_installed "$package_name"; then
            missing_packages+=("$package_name")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return 0
    fi

    if ! $CONFIGURE; then
        return 1
    fi

    printf 'Installing missing packages: %s\n' "${missing_packages[*]}"
    run_as_root apt-get update
    run_as_root apt-get install -y "${missing_packages[@]}"

    for package_name in "${missing_packages[@]}"; do
        if package_installed "$package_name"; then
            pass "Package $package_name is installed after configuration"
        else
            fail "Package $package_name could not be installed"
        fi
    done
}

if $CONFIGURE; then
    install_missing_packages || true
fi

for package_name in "${required_packages[@]}"; do
    if package_installed "$package_name"; then
        pass "Package $package_name is installed"
    else
        fail "Package $package_name is not installed"
    fi
done

installed_pwsh_version=""
if command -v pwsh >/dev/null 2>&1; then
    installed_pwsh_version="$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
fi

if [[ "$installed_pwsh_version" != "$POWERSHELL_VERSION" && $CONFIGURE == true ]]; then
    temporary_directory="$(mktemp -d)"
    powershell_package="$temporary_directory/powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb"
    wget -q "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb" \
        -O "$powershell_package"
    if ! run_as_root dpkg -i "$powershell_package"; then
        run_as_root apt-get install -f -y
        run_as_root dpkg -i "$powershell_package"
    fi
    rm -rf "$temporary_directory"
    installed_pwsh_version="$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
fi

if [[ "$installed_pwsh_version" == "$POWERSHELL_VERSION" ]]; then
    pass "PowerShell $POWERSHELL_VERSION is installed"
else
    fail "PowerShell $POWERSHELL_VERSION is required; found '${installed_pwsh_version:-not installed}'"
fi

dotnet_command=""
if [[ -x "$HOME/.dotnet/dotnet" ]]; then
    dotnet_command="$HOME/.dotnet/dotnet"
elif command -v dotnet >/dev/null 2>&1; then
    dotnet_command="$(command -v dotnet)"
fi

if [[ -z "$dotnet_command" || -z "$($dotnet_command --list-sdks 2>/dev/null | grep '^8\.' || true)" ]]; then
    if $CONFIGURE; then
        dotnet_install_script="$SCRIPT_DIRECTORY/../../../dotnet-install.sh"
        if [[ -f "$dotnet_install_script" ]]; then
            mkdir -p "$HOME/.dotnet"
            bash "$dotnet_install_script" --channel 8.0 --install-dir "$HOME/.dotnet" >/dev/null
            dotnet_command="$HOME/.dotnet/dotnet"
        else
            run_as_root apt-get install -y wget
            wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh
            bash /tmp/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet" >/dev/null
            dotnet_command="$HOME/.dotnet/dotnet"
        fi
    fi
fi

if [[ -n "$dotnet_command" && -n "$($dotnet_command --list-sdks 2>/dev/null | grep '^8\.' || true)" ]]; then
    pass ".NET 8 SDK is installed via $dotnet_command"
else
    fail ".NET 8 SDK is not installed"
fi

if command -v ufw >/dev/null 2>&1; then
    ufw_enabled="$(awk -F= '$1 == "ENABLED" { print $2 }' /etc/ufw/ufw.conf 2>/dev/null || true)"
    if [[ "$ufw_enabled" == "no" ]]; then
        pass "UFW is inactive"
    elif $CONFIGURE; then
        run_as_root ufw --force disable
        pass "UFW was disabled"
    else
        fail "UFW is active"
    fi
else
    pass "UFW is not installed"
fi

if [[ -d /sys/class/infiniband ]]; then
    mapfile -t rdma_interfaces < <(
        for interface_path in /sys/class/net/*; do
            if [[ -d "$interface_path/device/infiniband" ]]; then
                basename "$interface_path"
            fi
        done | sort
    )
else
    rdma_interfaces=()
fi

if [[ ${#rdma_interfaces[@]} -ge 2 ]]; then
    pass "Found ${#rdma_interfaces[@]} RDMA network interfaces"
else
    fail "At least two RDMA network interfaces are required; found ${#rdma_interfaces[@]}"
fi

if [[ -z "$PRIMARY_INTERFACE" ]]; then
    PRIMARY_INTERFACE="$(interface_for_ip "$CLIENT_RNIC_IP")"
    if [[ -z "$PRIMARY_INTERFACE" && ${#rdma_interfaces[@]} -gt 0 ]]; then
        PRIMARY_INTERFACE="${rdma_interfaces[0]}"
    fi
fi
if [[ -z "$SECONDARY_INTERFACE" ]]; then
    SECONDARY_INTERFACE="$(interface_for_ip "$CLIENT_SECONDARY_IP")"
    if [[ -z "$SECONDARY_INTERFACE" && ${#rdma_interfaces[@]} -gt 1 ]]; then
        SECONDARY_INTERFACE="${rdma_interfaces[1]}"
    fi
fi

if [[ -z "$PRIMARY_INTERFACE" || -z "$SECONDARY_INTERFACE" ]]; then
    fail "Could not determine both test interfaces; pass --primary-interface and --secondary-interface"
elif [[ "$PRIMARY_INTERFACE" == "$SECONDARY_INTERFACE" ]]; then
    fail "Primary and secondary test interfaces must be different"
else
    ensure_interface_enabled "$PRIMARY_INTERFACE"
    ensure_interface_enabled "$SECONDARY_INTERFACE"
    ensure_address "$PRIMARY_INTERFACE" "$CLIENT_RNIC_IP"
    ensure_address "$SECONDARY_INTERFACE" "$CLIENT_SECONDARY_IP"
    ensure_host_route "$PRIMARY_INTERFACE" "$CLIENT_RNIC_IP" "$SERVER_RNIC_IP"
    ensure_host_route "$SECONDARY_INTERFACE" "$CLIENT_SECONDARY_IP" "$SERVER_SECONDARY_IP"
fi

if command -v rdma >/dev/null 2>&1 && rdma link show | grep -q 'state ACTIVE'; then
    pass "At least one RDMA link is active"
else
    fail "No active RDMA link was reported"
fi

if command -v ibv_devices >/dev/null 2>&1 && [[ $(ibv_devices 2>/dev/null | tail -n +3 | wc -l) -gt 0 ]]; then
    pass "libibverbs detects RDMA hardware"
else
    fail "libibverbs did not detect RDMA hardware"
fi

resolved_sut_ip="$(getent ahostsv4 "$SUT_NAME" 2>/dev/null | awk 'NR == 1 { print $1 }')"
if [[ "$resolved_sut_ip" == "$SERVER_RNIC_IP" ]]; then
    pass "$SUT_NAME resolves to $SERVER_RNIC_IP"
elif $CONFIGURE; then
    run_as_root sed -i "/[[:space:]]${SUT_NAME}\([[:space:]]\|$\)/d" /etc/hosts
    printf '%s %s\n' "$SERVER_RNIC_IP" "$SUT_NAME" | run_as_root tee -a /etc/hosts >/dev/null
    pass "Added $SUT_NAME to /etc/hosts"
else
    fail "$SUT_NAME must resolve to $SERVER_RNIC_IP; found '${resolved_sut_ip:-unresolved}'"
fi

for peer_address in "$SERVER_RNIC_IP" "$SERVER_SECONDARY_IP"; do
    if ping -c 1 -W 1 "$peer_address" >/dev/null 2>&1; then
        pass "$peer_address responds to ICMP"
    else
        fail "$peer_address does not respond to ICMP"
    fi

    if timeout 3 bash -c "</dev/tcp/${peer_address}/445" >/dev/null 2>&1; then
        pass "$peer_address accepts SMB connections on TCP 445"
    else
        fail "$peer_address does not accept SMB connections on TCP 445"
    fi
done

memlock_limit="$(awk '/Max locked memory/ { print $4 }' /proc/$$/limits)"
if [[ "$memlock_limit" == "unlimited" || "$memlock_limit" =~ ^[0-9]+$ && "$memlock_limit" -ge "$MIN_MEMLOCK_BYTES" ]]; then
    pass "Current memlock limit is $memlock_limit"
elif $CONFIGURE; then
    run_as_root prlimit --pid "$PPID" --memlock=unlimited:unlimited
    run_as_root mkdir -p /etc/security/limits.d
    printf '* soft memlock unlimited\n* hard memlock unlimited\n' |
        run_as_root tee /etc/security/limits.d/99-ms-smbd-rdma.conf >/dev/null
    pass "Raised the invoking shell memlock and installed persistent PAM limits"
else
    fail "Memlock is $memlock_limit bytes; at least $MIN_MEMLOCK_BYTES bytes is required"
fi

printf '\nSummary: %d failure(s), %d warning(s).\n' "$failure_count" "$warning_count"
if [[ "$failure_count" -gt 0 ]]; then
    exit 1
fi
exit 0