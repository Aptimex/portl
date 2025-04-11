#!/bin/bash

# Forwards a TCP port from inside the namespace back to your normal host namespace 
# Does this using two SOCAT commands that talk via a "unix domain socket" file
# This script will keep running while the child processes are alive, and forward INT signals to them
# Recommand backgrounding this script and using job control to end it when done

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


if [ "$#" -ne 2 ]; then
        echo "USAGE: $0 fromPort toPort"
        exit 1
fi

nsPort=$1
extPort=$2
sFile="./$nsPort-$extPort.sock"
portlCMD="portl"

socat UNIX-LISTEN:./$sFile,reuseaddr,fork TCP4:0.0.0.0:$extPort &
children+=($!)
#echo "$!"

$portlCMD exec socat TCP6-LISTEN:$nsPort,reuseaddr,fork UNIX-CONNECT:./$sFile &
children+=($!)
#echo "$!"

echo "$nsPort -> $extPort"


#This will wait forever unless both children somehow die
for pid in "${children[@]}"
do
        wait $pid
done
