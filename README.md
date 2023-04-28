# Wireguard Namespaced (wgns)

Bash script to start Wireguard in its own Linux network namespace, and then run arbitrary commands within that namespace. Requires root access.

Useful if you want select programs to (be forced to) use Wireguard as a full VPN without affecting your main system or having to calculate complicated AllowedIP ranges for some excluded IPs. Also a good solution for when you want to use specific tools to access local network resources on both ends of the VPN at various times but have IP conflicts from overlapping local subnets.

Requires GNU `sed`, `grep`, `cut`, and `tr` to be installed. If you get errors about unsupported flags in these commands it's probably because you have a BSD (POSIX) version installed.

## Usage

`wgns.sh [command] [arguments]`

Commands:
- `config path/to/config/file`: specify a Wireguard configuration file to use (caveats below).
- `up`: brings up a namespaced Wireguard interface using the config file specified previously.
- `show`: shortcut to run `wg show` within the configured namespace.
- `down`: removes the Wireguard interface and namespace created by `up`.
- `exec [command]`: run an arbitrary command within the namespace created by `up`.

Note that the namespace and interface names are defined at the top of the script and can be changed. By default the namespace is `wgns` and the interface is `wgns0`. The rest of this documentation will describe the script's behavior assuming those values remain unchanged.

The script must always be run as root, e.g. with `sudo ./wgns.sh ...`. I intentionally avoided hard-coding a `sudo` into the script (as is done in the namespace example on Wireguard's website) because that increases the potential for users accidently creating local privilege escalation vulnerabilities if this script was used as part of an automated process (e.g. cron); implicit escalation to root can be dangerous.

### config
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

The specified config file will be copied to `/etc/wireguard/wgns0.conf`. `Address` and `DNS` lines (not supported by `wg`) will be commented out but parsed later by the `up` command to configure the interface. The config file will persist after the interface is removed (via the down command or otherwise) so you should only need to run config once unless configuration changes are needed.

### up
Uses the config file at `/etc/wireguard/wgns0.conf` (created via the config command) to create a Wireguard interface `wgns0` running in the `wgns` network namespace.

If the original config file contained `DNS=IP` options (also allowing multiple comma-separated IPs), those will be parsed and applied as `nameserver [IP]` values to a resolve.conf file specific to this namespace. This is done by writing them to `/etc/netns/wgns/resolve.conf`, which Linux will make available inside the namespace at the standard `/etc/resolve.conf` location without affecting that file outside the namespace. Like the config file in `/etc/wireguard/`, this namespaced `resolve.conf` file will be persistent and remain in use until modified manually or by the config command. If `/etc/netns/wgns/resolve.conf` does not exist (either because it is deleted or DNS was never specified in a config file) then the namespace will use the same `/etc/resolve.conf` file as the main OS.

### show
Shortcut to run `wg show` within the namespace

### exec
Runs the specified command as the current user (even when `sudo` is used to run the script as root). To run the specified command as root just specify sudo as part of the target command. E.g. `sudo ./wgns.sh exec sudo iptables -L`.

Pretty much any command that you would normally run in bash can be specified and should work as expected. You can even specify `bash` as the command to open a shell within the namespace, then return to the parent shell with `exit`.

### down
Brings down the namespaced Wireguard interface, then deletes the `wgns` namespace and all network interfaces in it. Any configuration options specified with the `config` command will be preserved (no need to run `config` again after `down`), but any namespace-specific changes that were made inside the namespace (e.g. iptables rules) will be lost.
