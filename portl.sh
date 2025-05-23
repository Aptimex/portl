#!/bin/bash

# modified from the script here: https://www.wireguard.com/netns/
# using info from here: https://volatilesystems.org/wireguard-in-a-separate-linux-network-namespace.html

# Make sure we're running as root (auto-elevates if you have NOPASSWD sudo configured)
[[ $UID != 0 ]] && exec sudo -E "$(readlink -f "$0")" "$@"

NAMESPACE="portl"
INTERFACE="portl0"
CONF="/etc/wireguard/${NAMESPACE}.conf"

# Some functions may need to recursively call this script
portlCMD=$0

Red='\033[1;31m'
Off='\033[0m'

config() {
    # -e causes the script to exit if any command errors out
    # -x prints each executed line, prepended with a +
    set -e
    supported="address|dns|mtu"
    unsupported="table|preup|postup|predown|postdown|saveconfig"
    
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
    
    #Parse MTU
    while read -r mtu; do
        if ! [ -z "$mtu" ]; then
            ip -n "$NAMESPACE" link set dev "$INTERFACE" mtu "$mtu"
        fi
    done < <(grep -i "^#~mtu" "$CONF" | cut -d= -f2 | tr -d " ")

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

forward() {
    # Forwards a port from inside the namespace back to your normal host namespace 
    # Does this using two SOCAT commands that talk via a "unix domain socket" file
    # This script will keep running while the child processes are alive, and forward INT signals to them
    # Recommand backgrounding this script and using job control to end it

    children=() #array of PIDs to kill on exit

    cleanup() {
        # kill all processes whose parent is this process
        pkill -P $$
    }

    for sig in INT QUIT HUP TERM; do
    trap "
        cleanup
        trap - $sig EXIT
        kill -s $sig "'"$$"' "$sig"
    done
    trap cleanup EXIT

    fUsage() {
        echo "Usage: $portlCMD fwd protocol fromPort [toPort]"
        echo "protocol must be tcp, t, udp, or u"
        echo "toPort will be same as fromPort if not specified"
        exit 1
    }    

    if [ "$#" -lt 2 ]; then
        fUsage
    fi

    set -e

    protocol=$1
    nsPort=$2
    extPort=${3:-$nsPort} #if extPort is not provided, use nsPort
    sFile="./$NAMESPACE.$protocol-$nsPort-$extPort.sock"
    pl="${protocol,,}"

    #set -x
    if [[ "$pl" == "tcp" || "$pl" == "t" ]]; then
        # IPv-agnotic TCP (or UDP) destination with localhost target works for both ipv4 and ipv6
        socat UNIX-LISTEN:$sFile,reuseaddr,fork TCP:localhost:$extPort &
        children+=($!)
        echo "Child Process 1: $!"

        # TCP6-LISTEN (or UDP6-LISTEN) captures IPv4 traffic as well
        $portlCMD exec sudo socat TCP6-LISTEN:$nsPort,reuseaddr,fork UNIX-CONNECT:$sFile &
        children+=($!)
        echo "Child Process 2: $!"

    elif [[ "$pl" == "udp" || "$pl" == "u" ]]; then
        socat UNIX-LISTEN:$sFile,reuseaddr,fork UDP:localhost:$extPort &
        children+=($!)
        echo "Child Process 1: $!"

        $portlCMD exec sudo socat UDP6-LISTEN:$nsPort,reuseaddr,fork UNIX-CONNECT:$sFile &
        children+=($!)
        echo "Child Process 2: $!"

    else 
        echo "error: protocol must be tcp, t, udp, or u"
        fUsage
        exit 1
    fi

    #socat TCP4-LISTEN:80,bind=127.0.0.1,reuseaddr,fork TCP6:[::1]:8080 &
    echo "$protocol: $nsPort -> $extPort"

    #This will wait forever unless both children somehow die
    for pid in "${children[@]}"
    do
            wait $pid
    done
    exit 0
}

usage() {
    echo "Usage: $(basename "$0") [ config FILE | up | down | show | exec CMD | run CMD | fwd OPTIONS | help ]"
    echo ""
    echo "COMMANDS"
    echo -e "\tconfig FILE"
    echo -e "\t\tSet FILE as the wireguard configuration file to use when creating or deleting the portl namespace\n"
    
    echo -e "\tup"
    echo -e "\t\tCreate the portl namespace (must run 'config' first)\n"
    
    echo -e "\tdown"
    echo -e "\t\tDelete the configured portl namespace\n"
    
    echo -e "\tshow"
    echo -e "\t\tShortcut to run 'wg show' within the portl namespace\n"
    
    echo -e "\texec CMD..."
    echo -e "\t\tRun any command within the portl namesapce\n"
    
    echo -e "\trun CMD..."
    echo -e "\t\tAlias for exec\n"

    echo -e "\tfwd PROTOCOL fromPort [toPort]"
    echo -e "\t\tForward localhost port traffic from inside the portl namespace to a localhost port in the host namespace\n"
    echo -e "\t\tPROTOCOL must be tcp, t, udp, or u\n"
    echo -e "\t\ttoPort will be the same as fromPort if not specified\n"
    
    echo -e "\thelp"
    echo -e "\t\tDisplay this help message\n"
    echo ""
    echo -e "Each command can also be run by specifying only its first letter, such as 's' instead of 'show'.\n"
    echo -e "If none of the above commands are provided as the first argument, 'exec' is assumed. This means you can use 'portl.sh CMD...' instead of 'portl.sh exec CMD...'\n"
    echo -e "Note that you cannot chain COMMANDs together with pipes inside the namespace; anything after the first pipe will run outside the namespace due to the way shells handle them. If you need to do this, start by running 'portl.sh exec bash' or similar, at which point everything that runs in the new shell will be inside the portl namespace.\n"
    echo ""
    
    echo "Example"
    echo "-------"
    echo "portl.sh config ./tunnel.conf"
    echo "portl.sh up"
    echo "portl.sh show"
    echo "portl.sh exec ping -c 4 10.0.0.1"
    echo "portl.sh curl 10.0.0.1:8080/info.txt"
    echo "portl.sh down"
    
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
    
    up) up ;;
    u) up ;; #shortcut
    
    down) down ;;
    d) down ;; #shortcut
    
    show) show ;;
    s) show ;; #shortcut
    
    exec) shift && exec_n "$@" ;;
    e) shift && exec_n "$@" ;; #shortcut
    run) shift && exec_n "$@" ;; #same as exec
    r) shift && exec_n "$@" ;; #shortcut

    fwd) shift && forward "$@" ;;
    f) shift && forward "$@" ;;
    
    help) usage ; exit 1 ;;
    h) usage ; exit 1 ;;
    -h) usage ; exit 1 ;;
    
    *) exec_n "$@" ;; #assume exec
esac
