# Portl

Bash script to start Wireguard in its own Linux network namespace and then run arbitrary commands within that namespace. This "portals" individual process traffic through the Wireguard interface without affecting traffic for any other process. Requires root/sudo.

Portl is useful if you want select programs to (be forced to) use Wireguard as a VPN without affecting traffic from the rest of your system or having to calculate complicated AllowedIP ranges for some excluded IPs (like your local subnet). It's also a good solution for when you want a specific tool to be able to access both local and on-VPN network resources at different times, but have the same (or overlapping) subnet CIDRs on the local and remote ends.

<div align="center">

![Diagram](media/portl.svg)
</div>

Requires GNU `sed`, `grep`, `cut`, and `tr` to be installed. If you get errors about unsupported flags in these commands it's probably because you have a BSD (POSIX) version installed.

## Quick Start
Start a Wireguard server on a machine you want to use a relay. If you're not familiar with this process, [this](https://github.com/burghardt/easy-wg-quick) or [this](https://github.com/wg-easy/wg-easy) should get you started.

Generate a basic Wireguard configuration file compatible with `wg-quick` that will connect to your client machine to the Wireguard server. For this example, save it as `tunnel.conf`.
- Set `AllowedIPs = 0.0.0.0/0` in this configuration file

Then run the following commands on your client:
```
./portl.sh config ./tunnel.conf
./portl.sh up
./portl.sh show
```
- If the Wireguard connection was successful, the `show` command output should include a line like `latest handshake: X seconds ago` that indicates a connection was established with a successful handshake.

Now you now can tunnel traffic for arbitrary programs through this connection by running `./portl.sh exec <any command>`
- `./portl.sh run <any command>` is equivalent
- You can also use `./portl.sh <any command>` so long as the first word in the command is not the same as one of the other portl commands. 

## Usage

```
Usage: portl.sh [ config FILE | up | down | show | exec CMD | run CMD | fwd OPTIONS | help ]

COMMANDS
        config FILE
                Set FILE as the wireguard configuration file to use when creating or deleting the portl namespace

        up
                Create the portl namespace (must run 'config' first)

        down
                Delete the configured portl namespace

        show
                Shortcut to run 'wg show' within the portl namespace

        exec CMD...
                Run any command within the portl namesapce

        run CMD...
                Alias for exec
        
        fwd PROTOCOL fromPort [toPort]
                Forward localhost port traffic from inside the portl namespace to a localhost port in the host namespace
                PROTOCOL must be tcp, t, udp, or u
                toPort will be the same as fromPort if not specified

        help
                Display this help message


Each command can also be run by specifying only its first letter, such as 's' instead of 'show'.

If none of the above commands are provided as the first argument, 'exec' is assumed. This means you can use 'portl.sh CMD...' instead of 'portl.sh exec CMD...'

Note that you cannot chain COMMANDs together with pipes inside the namespace; anything after the first pipe will run outside the namespace due to the way shells handle them. If you need to do this, start by running 'portl.sh bash' or similar, at which point everything that runs in the new shell will be inside the portl.sh namespace.


Example
-------
portl.sh config ./tunnel.conf
portl.sh up
portl.sh show
portl.sh exec ping -c 4 10.0.0.1
portl.sh curl 10.0.0.1:8080/info.txt
portl.sh down
```

Commands:
- `config path/to/config/file`: specify a Wireguard configuration file to use (caveats below).
- `up`: brings up a namespaced Wireguard interface using the config file specified previously.
- `show`: shortcut to run `wg show` within the configured namespace.
- `down`: removes the Wireguard interface and namespace created by `up`.
- `exec CMD...`: run an arbitrary command within the namespace created by `up`.
- `run CMD...`: same as `exec`.
- `fwd PROTOCOL fromPort [toPort]`: Forward traffic from inside the namespace to your normal host namespace.

Note that the namespace and interface names are defined at the top of the script and can be changed. By default the namespace is `portl` and the interface is `portl0`. The rest of this documentation will describe the script's behavior assuming those values remain unchanged.

> [!TIP]
> If you want to setup multiple portl tunnels to different systems just make a copy of the script file (with a different name, such as `portl2.sh`) and change the `NAMESPACE` and `INTERFACE` values near the top of the file to something unique. 

> [!TIP]
> Rename the script to `portl` and put it in a folder in your PATH to make it easy to use portl no matter what your current working directory is. 

The script requires root privileges to function. The first thing it does is check if it's running as root, and if not it automatically attempts to elevate to root using `sudo`. This may prompt the user for credentials.

### config FILE
The specified config file should be one that is compatible with `wg` (see the CONFIGURATION FILE FORMAT section [here](https://www.man7.org/linux/man-pages/man8/wg.8.html)), plus the (required) `Address` and (optional) `DNS` options supported by `wg-quick` (detailed [here](https://man7.org/linux/man-pages/man8/wg-quick.8.html)). **ANY OTHER `wg-quick`-SPECIFIC OPTIONS USED BESIDES `Address` OR `DNS` WILL BE SILENTLY IGNORED.** Comments (`#`) are fine and will be respected/preserved, but avoid using a `#~` combination anywhere because that is used as a special marker for parsing the supported `wg-quick` commands.

At a minimum, the config file should contain the following:
```
[Interface]
PrivateKey = [base64 private key]
Address = [address/subnet to be used by the client]

[Peer]
PublicKey = [server's public key]
AllowedIPs = [IP range(s) for traffic that should be sent over wireguard]
Endpoint = [server IP or FQDN]:[port] #default port is 51820
```
- You may also swap out the Peer's `Endpoint` for an Interface `ListenPort` if you want to act more like a server and have the peer initiate connections to this machine.

The specified config file will be copied to `/etc/wireguard/portl0.conf`. `Address` and `DNS` lines (not supported by `wg`) will be commented out but parsed later by the `up` command to configure the interface. The config file will persist after the interface is removed (via the `down` command or otherwise) so you should only need to run `config` once unless configuration changes are needed.

### up
Uses the config file at `/etc/wireguard/portl0.conf` (created via the `config` command) to create a Wireguard interface named `portl0` located in the `portl` network namespace.

If the original config file contained `DNS=IP` options (also allowing multiple comma-separated IPs), those will be parsed and applied as `nameserver [IP]` values to a `resolve.conf` file specific to the `portl` namespace. This is done by writing the values to `/etc/netns/portl/resolve.conf`, which Linux will make available inside the namespace at the standard `/etc/resolve.conf` location without affecting that file outside the namespace. Like the config file in `/etc/wireguard/`, this namespaced `resolve.conf` file will be persistent and remain in use until modified manually or by the `config` command. If `/etc/netns/portl/resolve.conf` does not exist (either because it is deleted or DNS was never specified in a config file) then the namespace will use the same `/etc/resolve.conf` file as the main OS.

### show
Shortcut to run `wg show` within the namespace.

### exec CMD...
Runs the specified command as the **current user**, even when `sudo` is used to run the script with root privileges. To run a command as root just specify `sudo` as part of the command. For example, `portl.sh exec sudo iptables -L`.

Pretty much any command that you would normally run in your shell can be used and should work as expected. You can even use something like `bash` as the target command to open a shell within the namespace, then return to the parent shell with `exit`.

> [!IMPORTANT]
> Using a pipe (or other command-terminating shell characters) will NOT allow the next command to run inside the namespace. For example, if you run `portl.sh exec echo "google.com" | xargs ping`, the `ping` command will NOT run inside the namespace, it will use your normal host namespace. 

> [!TIP]
> If you need to use something like pipes, run `portl.sh exec bash` to start a new shell inside the namespace, and then **everything** you run from that shell will also run inside that namespace. 

### run CMD...
Same as `exec`.

### fwd PROTOCOL fromPort [toPort]
Uses socat to forward traffic recieved inside the portl namespace on `localhost:<fromPort>` to `localhost:<toPort>` inside the current namespace, which is typically the normal host namespace. This is useful if you're running something like an SSH reverse port forward inside the namespace and want that to route to a service listening on localhost outside that namespace. 

This is accomplished by creating an on-disk Unix socket file that is accessible from any network namespace, which is used to relay traffic between the two namespaces. 

This implementation should work for any combination of IPv4 and IPv6 traffic, including mixing them between the source and destination. But it does not allow converting between TCP traffic into UDP traffic, or vice versa. 

Argument notes:
- `PROTOCOL` must be `tcp`, `t`, `udp`, or `u`
- `toPort` will be the same as `fromPort` if not specified

### down
Brings down the namespaced Wireguard interface, then deletes the `portl` namespace (and all network interfaces in it). Any configuration options specified with the `config` command will be preserved (no need to run `config` again after `down`), but any namespace-specific changes that were made inside the namespace (e.g. iptables rules) will be lost.

# Docker Version (dportl.sh)
This script is the same as the original `portl.sh`, except it moves the wireguard interface into an existing docker container's namespace instead of creating a new `portl` namespace. As part of this process it also deletes all existing network interfaces inside the container, except for `lo` (loopback).
- Deleting other interfaces ensures container traffic is forced through the Wireguard interface, but will probably break things if the container is meant to communicate with any other containers or do any other special local networking activity. This is intended mainly for use with containers that provide access to standalone tools/programs that target network resources, for example `nmap`. 

Usage is exactly the same as the `portl.sh` script described above, except the `up` command takes a single argument: the truncated 12-character `CONTAINER ID` of the target container, as displayed by `docker ps`. E.g. `dportl.sh up e90b8831a4b8`.
