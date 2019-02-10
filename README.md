## Ubiquiti Networks EdgeRouter Firewall BlockList Management
-------------------------------------------------------------
Automated management of network and host address blocklists, for use
in EdgeRouter firewall rules.


### Quick Start
To get started, perform these steps on your EdgeRouter from a CLI configure prompt:  
1. For IPv4:  `set firewall group network-group Nets4-BlackList description 'Blacklisted IPv4 Sources'`  
2. For IPv6:  `set firewall group ipv6-network-group Nets6-BlackList description 'Blacklisted IPv6 Sources'`  
3. `cp updBlackList.sh /config/scripts/updBlackList.sh`  
4. `cp fw-BlackList-URLs.txt /config/user-data/fw-BlackList-URLs.txt`  
5. `cp loadBlackList.sh /config/scripts/post-config.d/loadBlackList.sh`  
6. `set system task-scheduler task Update-Blacklists executable path /config/scripts/updBlackList.sh`  
7. `set system task-scheduler task Update-Blacklists interval 12h`  
8. `sudo /config/scripts/updBlackList.sh`  

You will also need to create a firewall rule to deny inbound source addresses
that match this network-group `Nets4-BlackList`.  An example using
a zone-based firewall might look like:  
1. `set firewall name wan-dmz-4 rule 1 source group network-group Nets4-BlackList`  
2. `set firewall name wan-dmz-4 rule 1 action drop`
3. `set firewall name wan-dmz-4 rule 1 protocol all`
4. `set firewall name wan-lan-4 rule 1 source group network-group Nets4-BlackList`  
5. `set firewall name wan-lan-4 rule 1 action drop`  
6. `set firewall name wan-lan-4 rule 1 protocol all`  
7. `set firewall name wan-self-4 rule 1 source group network-group Nets4-BlackList`  
8. `set firewall name wan-self-4 rule 1 action drop`  
9. `set firewall name wan-self-4 rule 1 protocol all`  

Similar for IPv6:
1. `set firewall ipv6-name wan-dmz-6 rule 1 source group ipv6-network-group Nets6-BlackList`  
2. `set firewall ipv6-name wan-dmz-6 rule 1 action drop`  
3. `set firewall ipv6-name wan-dmz-6 rule 1 protocol all`  
4. `set firewall ipv6-name wan-lan-6 rule 1 source group ipv6-network-group Nets6-BlackList`  
5. `set firewall ipv6-name wan-lan-6 rule 1 action drop`  
6. `set firewall ipv6-name wan-lan-6 rule 1 protocol all`  
7. `set firewall ipv6-name wan-self-6 rule 1 source group ipv6-network-group Nets6-BlackList`  
8. `set firewall ipv6-name wan-self-6 rule 1 action drop`  
9. `set firewall ipv6-name wan-self-6 rule 1 protocol all`  

To use the optional `iprange` for optimization and reduction you will need to install the
binary.  There is an existing iprange .deb package for both mips and mipsel that
may be used.
1.  If apt repositories have been configured:  `sudo apt install iprange`
2.  If apt has not been configured:
    1.  `mkdir -p /config/data/firstboot/install-packages`
    2.  `cd /config/data/firstboot/install-packages`
    3.  For Cavium-based platforms (MIPS):
        1.  `curl -O http://http.us.debian.org/debian/pool/main/i/iprange/iprange_1.0.3+ds-1_mips.deb`
        2.  `sudo dpkg --install iprange_1.0.3+ds-1_mips.deb`
    4.  For MTK-based platforms (MIPSEL; including ER-X, ER-X-SFP, EP-R6):
        1.  `curl -O http://http.us.debian.org/debian/pool/main/i/iprange/iprange_1.0.3+ds-1_mipsel.deb`
        2.  `sudo dpkg --install iprange_1.0.3+ds-1_mipsel.deb`

That should get you going with minimal effort.  However, you really should
review `fw-BlackList-URLs.txt` and edit as appropriate.  The two scripts
both have configuration sections that you should also review and edit as
appropriate.


### Network and host blocklist IPset creation script
`updBlackList.sh` is the actual tool that will fetch various blocklists,
consolidate into one group, and load into a pre-existing IPset already used
with firewall rulesets.  
You may schedule this appropriately for your needs, but the quick start above
provides for a twice-daily update at noon and midnight.  Note that most list
providers have guidelines on frequency of retrieval so these should be taken
into account when setting the schedule.


### List of URLs containing blacklists
The file `fw-BlackList-URLs.txt` should contain the list of URLs to
individual blocklist of networks and hosts.  Blank lines and comments
(beginning with a hash (#) are acceptable).  
The sample provided here has many sources listed as a starting point,
though only some are enabled (uncommented).  Note that several of the indicated
lists either overlap or fully include other lists so it is not necessary nor is
it recommended to blindly uncomment all URLs here.
'`cURL`' will be used to fetch each of these individually, exactly as listed.


### Boot-time IPset reload script
Since the `updBlackList.sh` tool directly manipulates IPsets and does
not reflect any changes in the EdgeOS `config.boot`, contents of the
blocklist network-groups are lost upon reboot/restart of the EdgeRouter.  
The `loadBlackList.sh` script addresses this by restoring the previously
saved network-groups at boot time.  
Alternatively, the `updBlackList.sh` script may be re-run at boot-time.
This will take longer, however, since it will recreate the list newly.


### Using iprange
iprange may be used to optimize lists of network addresses, particularly when
merging multiple different lists from multiple sources.  Overlaps and consolidation
is standard with additional ability to reduce the number of prefix lengths for runtime
efficiency when using the created IPsets.

iprange also provides for a true proper whitelist mechanism, automatically splitting
address blocks around the whitelisted addresses followed by the above optimization
and reduction.

Unfortunately iprange only supports IPv4 currently so there would be no optimization
for IPv6 IPsets (yet)

By default, if iprange is found it will be used with nothing more than the installation
noted above being required.  Note that if 'apt' is used to install iprange you will
need to re-install after each firmware update, though 'apt' sources would need to be
reconfigured at the same time anyway.  If you download the .deb and place it in the directory
referenced above, however, this will be re-installed automatically after each firmware
upgrade so that may actually be a preferred option.


### More detail
IPset documentation may be found at http://ipset.netfilter.org

IPrange documentation may be found at https://github.com/firehol/iprange/wiki

This work was inspired by the
[Emerging Threats Blacklist](https://community.ubnt.com/t5/EdgeMAX/Emerging-Threats-Blacklist/td-p/645375)
discussion thread in the Ubiquiti Networks community forums.

This utility is one option among several for ingress filtering, and is primarily
intended to be used in lieu of blackhole-routing and BGP route filtering.

Note that arbitrary lists should not be arbitrarily added or enabled for blocking.
Review of each list should be performed combined with a period of careful monitoring after
enabling to ensure legitimate traffic is not blocked.  Some public "blocklists"
are known to be rather aggressive and add addresses/netblocks too easily.
