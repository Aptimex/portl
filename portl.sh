#!/bin/bash

# modified from the script here: https://www.wireguard.com/netns/
# using info from here: https://volatilesystems.org/wireguard-in-a-separate-linux-network-namespace.html

# Make sure we're running as root (auto-elevates if you have NOPASSWD sudo configured)
[[ $UID != 0 ]] && exec sudo -E "$(readlink -f "$0")" "$@"

NAMESPACE="portl"
INTERFACE="portl0"
CONF="/etc/wireguard/${INTERFACE}.conf"

Red='\033[1;31m'
Off='\033[0m'

config() {
    # -e causes the script to exit if any command errors out
    # -x prints each executed line, prepended with a +
    set -e
    supported="address|dns"
    unsupported="mtu|table|preup|postup|predown|postdown|saveconfig"
    
    #warn if unsupported options are found
    while read -r u; do
        echo -e "${Red}Ignoring unsupported config option: ${u} ${Off}"
    done < <(grep -i -E "^[[:space:]]*(${unsupported})" "$1")
    
    
    # Comment out Address and DNS lines because the wg command doesn't support them (only wg-quick does)
    # Need Address and DNS to still be present so they can be parsed as part of the up() function
    # For those lines, also add a ~ to mark that those lines weren't commented out in the original and should be used
    # Without some marker like this we might parse pre-commented lines were supposed to be ignored
    # Double-comment other unsupported lines we don't need (could just delete them)
    # Write to configuration file (overwriting)
    sed -E "s/^[[:space:]]*(${supported})/#~\1/Ig" "$1" \
        | sed -E "s/^[[:space:]]*(${unsupported})/##\1/Ig" \
        > "${CONF}"
    
    echo "Config file parsed and written to ${CONF}"
}

up() {
    set -ex
    
    ip netns add "$NAMESPACE"
    ip link add "$INTERFACE" type wireguard
    ip link set "$INTERFACE" netns "$NAMESPACE"
    ip netns exec "$NAMESPACE" wg setconf "$INTERFACE" "$CONF"
    
    #Parse addresses
    while read -r address; do
        ip -n "$NAMESPACE" addr add "$address" dev "$INTERFACE"
    done < <(grep -i "^#~address" "$CONF" | cut -d= -f2 | tr -d " " | tr "," "\n")
    
    #Parse DNS
    #By default, /etc/resolve.conf will be used by the namespace
    #If /etc/netns/NAMESPACE_NAME/resolv.conf exists (it is persistent), that will be used by the namespace instead
    #If the config file specifies DNS, this will parse it, truncate /etc/netns/"$NAMESPACE"/resolv.conf, and apply the settings; otherwise no changes to the filesystem will be made
    dns_setup=0
    while read -r dns; do
        if [[ "$dns_setup" == 0 ]]; then
            mkdir -p /etc/netns/"$NAMESPACE" #make dir structure if it doesn't exist
            > /etc/netns/"$NAMESPACE"/resolv.conf #create or truncate the file
            dns_setup=1 #don't truncate the file on subsequent loops
        fi
        echo nameserver "$dns" >> /etc/netns/"$NAMESPACE"/resolv.conf
    done < <(grep -i "^#~dns" "$CONF" | cut -d= -f2 | tr -d " " | tr "," "\n")
    
    
    ip -n "$NAMESPACE" link set "$INTERFACE" up
    ip -n "$NAMESPACE" link set lo up
    ip -n "$NAMESPACE" route add default dev "$INTERFACE"
}

down() {
    set -x
    ip -n "$NAMESPACE" link set "$INTERFACE" down
    ip -n "$NAMESPACE" link del "$INTERFACE"
    #ip link del "$INTERFACE" #in case the config file had an issue and the interface was created but not moved
    ip netns del "$NAMESPACE"
}

exec_n() {
    #exec completely replaces this script process with the specified process
    exec ip netns exec "$NAMESPACE" sudo -E -u \#${SUDO_UID:-$(id -u)} -g \#${SUDO_GID:-$(id -g)} "$@"
    exit #this is never reached, just here to remind you that there's no returning from this function
}

show() {
    ip netns exec "$NAMESPACE" wg show
}

usage() {
    echo "Usage: $0 config|up|show|exec|down"
    echo -e "\tconfig ./path/to/wg/config/file"
    echo -e "\texec [any command to execute within namesapce]"
    echo -e "\trun: alias for exec"
    echo -e "\tshow: shortcut to run 'wg show' within namespace"
    
}

if [[ $UID != 0 ]]; then
    echo -e "${Red}Must run as root!${Off}"
    usage
    exit 1
fi

command="$1"

case "$command" in
    config) shift && config "$@" ;;
    up) up ;;
    down) down ;;
    exec) shift && exec_n "$@" ;;
    run) shift && exec_n "$@" ;;
    show) show ;;
    *) usage ; exit 1 ;;
esac
