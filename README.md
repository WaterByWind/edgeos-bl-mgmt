## Ubiquiti Networks EdgeRouter Firewall BlackList Management
-------------------------------------------------------------
Automated management of network and host address blacklists, for use
in EdgeRouter firewall rules.


### Quick Start
To get started, perform these steps on your EdgeRouter from a CLI configure prompt:  
1. ```set firewall group network-group Nets4-BlackList description 'Blacklisted IPv4 Sources'```  
2. ```cp updBlackList.sh /config/scripts/updBlackList.sh```  
3. ```cp fw-BlackList-URLs.txt /config/user-data/fw-BlackList-URLs.txt```  
4. ```cp loadBlackList.sh /cofnig/scripts/post-config.d/loadBlackList.sh```  
5. ```set system task-scheduler task Update-Blacklists executable path /config/scripts/updBlackList.sh```  
6. ```set system task-scheduler task Update-Blacklists interval 12h```  
7. ```/config/scripts/updBlackList.sh```  

You will also need to create a firewall rule to deny inbound source addresses
that match this network-group ```Nets4-BlackList```.  An example using
a zone-based firewall might look like:  
1. ```set firewall name wan-dmz-4 rule 1 source group network-group Nets4-BlackList```  
2. ```set firewall name wan-lan-4 rule 1 source group network-group Nets4-BlackList```  
3. ```set firewall name wan-self-4 rule 1 source group network-group Nets4-BlackList```  

That should get you going with minimal effort.  However, you really should
revew ```fw-BlackList-URLs.txt``` and edit as appropriate.  The two scripts
both have configuration sections that you should also review and edit as
appropriate.


### Network and host blacklist IPset creation script
```updBlackList.sh``` is the actual tool that will fetch various blacklists,
consolidate into one group, and load into a pre-existing IPset already used
with firewall rulesets.  
You may schedule this approprately for your needs, but the quick start above
provides for a daily update at noon and midnight.


### List of URLs containing blacklists
The file ```fw-BlackList-URLs.txt``` should contain the list of URLs to
individual blacklist of networks and hosts.  Blank lines and comments
(beginning with a hash (#) are acceptable).  
The sample provided here has many sources listed as a starting point,
though only some are enabled (uncommented).  
'```cURL```' will be used to fetch each of these individually,
exactly as listed.


### Boot-time IPset reload script
Since the ```updBlackList.sh``` tool directly manipulates IPsets and does
not reflect any changes in the EdgeOS ```config.boot```, contents of the
blacklist network-group are lost upon reboot/restart of the EdgeRouter.  
The ```loadBlackList.sh``` script addresses this by restoring the previously
saved network-group at boot time.  
Alternatively, the ```updBlackList.sh``` script may be re-run at boot-time.
This will take longer, however, since it will recreate the list newly.


### More detail
IPset documentation may be found at http://ipset.netfilter.org

This work was inspired by the
[Emerging Threats Blacklist](https://community.ubnt.com/t5/EdgeMAX/Emerging-Threats-Blacklist/td-p/645375)
discussion thread in the Ubiquiti Networks community forums.
