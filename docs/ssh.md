# SSH Server

Open **Settings → Security → SSH Server** and turn on **Enable SSH Server**.
Approve the administrator prompt. The status becomes **Running**, and
**Connect with** shows a command to copy to the other computer. Sign in with
your account password or an SSH key already authorized for your account.

The switch is off on a fresh installation and remembers its state after a
restart. Turning it off stops the listener. Existing SSH sessions can finish;
OpenSSH deliberately preserves them when its service stops.

The installed system declares the ordinary NixOS OpenSSH service, PAM password
authentication, host-key generation and firewall ports. Root login and empty
passwords are disabled. By default only the machine's primary user can sign
in. The service starts only when its root-owned persistent switch at
`/var/lib/cybexos/ssh-server/enabled` exists. No password is stored there.
The declared SSH ports are reserved in the firewall; with the switch off
there is no SSH listener. Other firewall rules remain in place.

The setting uses a narrow Polkit helper accepting only enable/disable and
read-only status. It does not rebuild the system, change the account password,
edit personal NixOS modules or depend on the updater/release endpoint.
Personal OpenSSH configuration in `/etc/nixos/local` can override the vendor
defaults. If it disables the service or selects socket activation, the switch
reports unavailable rather than replacing that configuration. The installation
ISO itself keeps SSH disabled.
