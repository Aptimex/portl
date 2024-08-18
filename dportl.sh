#!/bin/bash

# modified from the script here: https://www.wireguard.com/netns/
# using info from here: https://volatilesystems.org/wireguard-in-a-separate-linux-network-namespace.html

# This version is for running wireguard inside a Docker container.

# Make sure we're running as root (auto-elevates if you have NOPASSWD sudo configured)
[[ $UID != 0 ]] && exec sudo -E "$(readlink -f "$0")" "$@"

NAMESPACE="dportl"
INTERFACE="dportl0"
CONF="/etc/wireguard/${NAMESPACE}.conf"

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
    
    # Link the container's network namespace file to where 'ip netns' can use it.
    pid=$(docker inspect -f '{{.State.Pid}}' "$1")
    if [[ ! $pid || $pid == 0 ]]; then
        echo "Invalid PID for Container ID $1, ensure the ID is a valid running container"
        exit 2
    fi
    rm -f /var/run/netns/"$NAMESPACE"
    ln -s /proc/$pid/ns/net /var/run/netns/"$NAMESPACE"
    
    #ip netns add "$NAMESPACE"
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
    
    # Remove all existing interfaces (other than lo)
    while read -r iface; do
        if [[ "$iface" != "lo" ]]; then
            ip netns exec "$NAMESPACE" ip link delete "$iface"
        fi
    done < <(ip netns exec "$NAMESPACE" netstat -i | tail -n +3 | cut -d " " -f 1) #ignore the first two header lines
    
    
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
    rm -f /var/run/netns/"$NAMESPACE"
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
    echo "Usage: $(basename "$0") [ config FILE | up | down | show | exec CMD | run CMD | help ]"
    echo ""
    echo "COMMANDS"
    echo -e "\tconfig FILE"
    echo -e "\t\tSet FILE as the wireguard configuration file to use when creating or deleting the portl namespace\n"
    
    echo -e "\tup CONTAINER_ID"
    echo -e "\t\tCreate the portl namespace and symlink it to the docker container namespace used by CONTAINER_ID (the truncated 12-character ID, as shown in 'docker ps'). This deletes all network interfaces inside the container (except 'lo') and replaces them with a portl interface, forcing all the container's networking to go through it. Must run 'config' first\n"
    
    echo -e "\tdown"
    echo -e "\t\tDeletes the configured portl namespace. The target docker container namespace continues to exist, but the portl interface inside it will be deleted.\n"
    
    echo -e "\tshow"
    echo -e "\t\tShortcut to run 'wg show' within the portl namespace\n"
    
    echo -e "\texec CMD..."
    echo -e "\t\tRun any command within the portl namesapce. However, the purpose of this script is really to make any commands run inside the docker container go through the wireguard tunnel, so you shouldn't need to use this.\n"
    
    echo -e "\trun CMD..."
    echo -e "\t\tAlias for exec\n"
    
    echo -e "\thelp"
    echo -e "\t\tDisplay this help message\n"
    echo ""
    echo -e "Each command can also be run by specifying only its first letter, such as 's' instead of 'show'.\n"
    echo ""
    
    echo "Example"
    echo "-------"
    echo "dportl.sh config ./tunnel.conf"
    echo "dportl.sh up e90b8831a4b8"
    echo "docker exec -it e90b8831a4b8 ping -c 4 10.0.0.1"
    echo "docker exec -it e90b8831a4b8 curl 10.0.0.1:8080/info.txt"
    echo "dportl.sh down"
    echo "docker stop e90b8831a4b8"
    
}

if [[ $UID != 0 ]]; then
    echo -e "${Red}Must run as root!${Off}"
    usage
    exit 1
fi

command="$1"

case "$command" in
    config) shift && config "$@" ;;
    configure) shift && config "$@" ;;
    c) shift && config "$@" ;; #shortcut
    
    up) shift && up "$@" ;;
    u) shift && up "$@" ;; #shortcut
    
    down) down ;;
    d) down ;; #shortcut
    
    show) show ;;
    s) show ;; #shortcut
    
    exec) shift && exec_n "$@" ;;
    e) shift && exec_n "$@" ;; #shortcut
    run) shift && exec_n "$@" ;; #same as exec
    r) shift && exec_n "$@" ;; #shortcut
    
    help) usage ; exit 1 ;;
    h) usage ; exit 1 ;;
    -h) usage ; exit 1 ;;
    
    *) exec_n "$@" ;; #asume exec
esac
