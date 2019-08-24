#!/bin/bash
#
# vim: tabstop=8 expandtab shiftwidth=4 softtabstop=4
#
#------------------------------------------------------------------------------
#
# Copyright (c) 2015 - 2019 Waterside Consulting, inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
# Automated Blacklist management for Ubiquiti EdgeRouters
# For use in lieu or supplement of blackhole-routing and BGP route filtering
#
# 18 April 2019: v1.5
#    - Update 'sed' patterns to match new usage requirements
#    - Avoid potential cache file naming collisions
#    - Other cache filename tweaks
#    - Cache source URLs used
#
# 10 February 2019: v1.4
#    - Update 'sed' patterns to match modern usage requirements
#
# 19 April 2018: v1.3
#    - Add initial support for 'iprange'
#
# 07 May 2017: v1.2
#    - Add IPv6 support
#    - Ensure /dev/fd exists (ER-X uses devtmpfs with missing template entry)
#    - Update cURL output filenaming
#
# 05 October 2015: v1.1.1
#    - Fix for additional comment (//) delineator in some blacklists
#
# 21 September 2015:  v1.1
#    - Move list of blacklist URLs to separate file
#    - Check for failed retreival (curl error)
#    - Minor updates and fixes
#
# 19 September 2015:  v1.0
#    - Initial release
#
#------------------------------------------------------------------------------
#
# Inspired by UBNT Community forums post:
#   https://community.ubnt.com/t5/EdgeMAX/Emerging-Threats-Blacklist/td-p/645375
#
#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
#
##
## Configuration
##
#
# Place this file in /config/scripts
#
# Firewall blacklist groups
#   These network-groups must already exist.
#   These shoudld be created via EdgeOS BUI or CLI, and to have any
#     effect must be assigned to one or more firewall rules
#   Leave empty to not populate IPset netgroup
fwGroupNets4="Nets4-BlackList"
fwGroupNets6="Nets6-BlackList"
#
# Persistent data location (directory)
dirUserData="/config/user-data"
#
# Locally-defined blacklist, in above persistent location (file, optional)
fnLocalBlackList="LocalBlackList.txt"
#
# Locally-defined whitelist, in above persistent location (file, optional)
fnLocalWhiteList="LocalWhiteList.txt"
#
# List of URLs from which to retrieve blacklists (file, required)
fnUrlList="fw-BlackList-URLs.txt"
#
# Files to save persistent IPSET content (file, optional)
#   This can be used in a post-config.d script to recover the
#     existing blacklist quickly during restart rather than having to
#     re-run this script.  Either option would suffice.
#   Leave empty to not save network group across reboots
fnIPSetSave4="fw-IPSET-4.txt"
fnIPSetSave6="fw-IPSET-6.txt"
#
# Default verbosity (for messages to display/tty)
#   0 = Completely silent
#   1 = + errors and failures
#   2 = + informational status
#   3 = + cURL, iprange status output
#   9 = + debug output
verbose=2
#
# Use email for messages
#   Values same as for 'verbosity' above
#   /etc/ssmtp/ssmtp.conf must be configured to be able
#     to send email.  At minimum mailhub may need to be defined
#     along with any potential authentication credentials.
useMail=0
#
# Destination for email messages, if enabled
mailDest="USER@MAILDOMAIN.com"
#
# Use 'logger' (syslog) for messages
#   Values same as for 'verbosity' above
useLogger=2
#
# Maximum number of blacklist elements
#   The absolute maximum count for blacklisted elements (networks + hosts)
#   Note that the 'maxelem' value is dynamically set with each run
#     to the size of the actual resultant list.  The value here is the
#     largest that will be dynamically allowed, and if the total count of
#     blocked networks + hosts is greater than this value then no
#     update will be made to the firewall group.
fwSetMaxElem=131071
#
# Location for 'iprange' exectuable, optional.
#   See https://github.com/firehol/iprange/wiki
#   If this is defined, the target exists, and the target is executable
#   it will be used for merging/optimizing and potentially reducing the
#   number of prefix lengths.
#   Note that currently iprange only supports IPv4
cmdBaseIPRange='/usr/bin/iprange'
#
# When using 'iprange' for reduction in prefix length count, two
#   parameters control how large the resulting ipset may become.  The
#   larger of these two values will determine the max size.
#
# The maximum growth in size as percentage.
ipRangeRedFactor=0
#
# The maximum set size as absolute count
ipRangeRedEntries=${fwSetMaxElem}
#
#
#
#-----------------------------------------------------------
#-----------------------------------------------------------
##
## Configuration ends here
##   There should be no need to make further changes below
##
#-----------------------------------------------------------
#-----------------------------------------------------------

#-----------------------------------------------------------
##
## Exit codes
##
##   0:  Clean exit
##  10:  Data dir (/config/user-data?) does not exist
##  11:  Temp dir (/tmp?) does not exist
##  12:  Could not create temp sub dir under temp dir
##  13:  Could not create temp files (mktemp failure)
##  14:  Specified firewall group (IP set) does not exist
##  15:  Resulting blacklist too large
##  16:  ipset restore (to tmp group) failed
##  17:  ipset swap (tmp and target groups) failed
##  18:  URL list file missing or empty
##  19:  file retreival failure (cURL error)
##  20:  No firewall group(s) configured
##
#-----------------------------------------------------------

#-----------------------------------------------------------
##
## TODO:  Better/proper whitelist support
## TODO:  Aggregation & prefix count reduction
## TODO:  Rework to reduce IPv4/IPv6 duplicate coding
##
#-----------------------------------------------------------

#-----------------------------------------------------------
##
## Definitions
##
fnUsedSourceList="source-urls.txt"
fpLocBlackList="${dirUserData}/${fnLocalBlackList}"
fpLocWhiteList="${dirUserData}/${fnLocalWhiteList}"
fpUrlList="${dirUserData}/${fnUrlList}"
[[ -n "${fnIPSetSave4}" ]] && fpIPSetSave4="${dirUserData}/${fnIPSetSave4}"
[[ -n "${fnIPSetSave6}" ]] && fpIPSetSave6="${dirUserData}/${fnIPSetSave6}"

cmdBaseCURL="curl --compressed"
cmdBaseIPSet="sudo /sbin/ipset"
cmdBaseSSMTP="/usr/sbin/ssmtp"
cmdBaseLN="sudo /bin/ln"

fwGroupTmp4="bl_tmp_4"
fwGroupTmp6="bl_tmp_6"
blUrl=()
useIPRange=0
flgOpt=0
: ${TMPDIR:="/tmp"}
#
#-----------------------------------------------------------

#-----------------------------------------------------------
##
## Support
##

#
## Timestamp
#
pTimeNow()
{
    date "+%T %Z %a %d %b %Y"
}

#
## Add message to email
#
queueEmail()
{
    echo "$(date +%FT%T%Z): $*" >> "${fnTemp4}"
}

#
## Display/log error message
#
errMsg()
{
    if [[ ${verbose} -gt 0 ]]; then
        echo "$*" >&2
    fi
    if [[ ${useLogger} -gt 0 ]]; then
        logger -p err -t "${myName}" "$*"
    fi
    if [[ ${useMail} -gt 0 ]]; then
        queueEmail "$*"
    fi
}

#
## Display/log non-error message
#
logMsg()
{
    if [[ ${verbose} -gt 1 ]]; then
        echo "$*"
    fi
    if [[ ${useLogger} -gt 1 ]]; then
        logger -p notice -t "${myName}" "$*"
    fi
    if [[ ${useMail} -gt 1 ]]; then
        queueEmail "$*"
    fi
}

#
## Display/log debug message
#
debugMsg()
{
    if [[ ${verbose} -ge 9 ]]; then
        echo "$*"
    fi
    if [[ ${useLogger} -ge 9 ]]; then
        logger -p debug -t "${myName}" "$*"
    fi
    if [[ ${useMail} -ge 9 ]]; then
        queueEmail "$*"
    fi
}

#
## Terminate with error
#
die()
{
    rc=$1
    shift
    debugMsg "die()"
    errMsg "FATAL: $*"
    exit ${rc}
}

#
## Initial setup
#
startup()
{
    myName=$(basename $0 .sh)
    strTime="$(pTimeNow)"

    # Don't attempt to log to email just yet. . .
    saveUseMail=${useMail}
    useMail=0

    debugMsg "startup()"

    if [[ ! -d ${dirUserData} ]]; then
        die 10 "Data dir '${dirUserData}' does not exist"
    fi
    if [[ ! -d ${TMPDIR} ]]; then
        die 11 "Temp dir '${TMPDIR}' does not exist"
    fi

    export TMPDIR="${TMPDIR}/.BL"

    if ! mkdir -p ${TMPDIR}; then
        die 12 "Failed to create working dir '${TMPDIR}': error $?"
    fi
    cd ${TMPDIR}

    # Set up temp files for use later
    fnTemp1=$(mktemp -t "${myName}.1-XXXXXX")
    fnTemp2=$(mktemp -t "${myName}.2-XXXXXX")
    fnTemp3=$(mktemp -t "${myName}.3-XXXXXX")
    fnTemp4=$(mktemp -t "${myName}.4-XXXXXX")
    fnTemp5=$(mktemp -t "${myName}.5-XXXXXX")
    if [ -z "${fnTemp1}" -o -z "${fnTemp2}" -o -z "${fnTemp3}" \
        -o -z "${fnTemp4}" -o -z "${fnTemp5}" -o \
        ! -w "${fnTemp1}" -o ! -w "${fnTemp2}" -o \
        ! -w "${fnTemp3}" -o ! -w "${fnTemp4}" -o \
        ! -w "${fnTemp5}" ]; then
            die 13 "Could not create temporary files"
    fi
    tmpFileList="${fnTemp1} ${fnTemp2} ${fnTemp3} ${fnTemp4} ${fnTemp5}"

    #  Now we can start logging via email, if desired
    if [[ -x ${cmdBaseSSMTP} ]]; then
        useMail=${saveUseMail}
    elif [[ ${saveUseMail} -ne 0 ]]; then
        errMsg "Missing MTA '${cmdBaseSSMTP}'.  Will not send email"
    fi

    if [[ -n "${cmdBaseIPRange}" ]]; then
        if [[ -x ${cmdBaseIPRange} ]]; then
            useIPRange=1
        else
            useIPRange=0
            errMsg "Missing executable '${cmdBaseIPRange}'.  Will not optimize IPsets"
        fi
    fi

    logMsg "Starting at ${strTime}"

    # Ensure /dev/fd exists
    if [[ ! ( -h /dev/fd ) ]]; then
        debugMsg "/dev/fd missing:  Creating symlink /dev/fd -> /proc/self/fd"
        ${cmdBaseLN} -s /proc/self/fd /dev/fd
    fi

    if [ ${useMail} -gt 1 -o ${useLogger} -gt 1 -o ${verbose} -gt 1 ]; then
        flgDoCounts=1;
    else
        flgDoCounts=0;
    fi

    if [ ${useMail} -le 1 -a ${useLogger} -le 1 -a ${verbose} -le 1 ]; then
      cmdBaseIPSet="${cmdBaseIPSet} -q"
    fi

    if [[ ${verbose} -ge 3 ]]; then
        cmdBaseIPRange="${cmdBaseIPRange} -v"
    fi

    if [[ ${verbose} -lt 3 ]]; then
        # cURL should be quiet
        cmdBaseCURL="${cmdBaseCURL} -s"
        if [[ ${verbose} -gt 0 ]]; then
            # But still show errors
            cmdBaseCURL="${cmdBaseCURL} -S"
        fi
    fi

    # Ensure at least one netgroup is defined
    [[ -z "${fwGroupNets4}" && -z "${fwGroupNets6}" ]] && \
        die 20 "No firewall groups (IPsets) configured (Nothing to do!)"

    debugMsg "Reading blocklist URL file '${fpUrlList}"
    [[ -s "${fpUrlList}" ]] || \
        die 18 "URL list file '${fpUrlList}' missing or empty"

    while read line; do
        blUrl+=(${line})
    done < <(sed -e 's/#.*$//g' -e '/^[[:space:]]*$/d' ${fpUrlList})
    elCtBL=${#blUrl[@]}
    debugMsg "Read ${elCtBL} URLs from blocklist URL file"

    [[ ${elCtBL} -gt 0 ]] || \
        die 18 "URL list file '${fpUrlList}' contains no URLs"

    if [[ -s ${fpLocBlackList} ]]; then
        flBlockList="${fpLocBlackList}"
    else
        flBlockList=""
    fi

    # Verify firewall groups exist and save creation parameters
    if [[ -n "${fwGroupNets4}" ]]; then
        fwSetHNets4=$(${cmdBaseIPSet} -t list ${fwGroupNets4} | egrep '^Header')
        if [[ $? -eq 0 ]]; then
            # Found it, now do some fixup
            fwSetHNets4=$(echo ${fwSetHNets4} \
                | sed -e "s/Header: /create ${fwGroupTmp4} hash:net /")
        else
            die 14 "Target firewall group '${fwGroupNets4}' does not exist"
        fi
    fi
    if [[ -n "${fwGroupNets6}" ]]; then
        fwSetHNets6=$(${cmdBaseIPSet} -t list ${fwGroupNets6} | egrep '^Header')
        if [[ $? -eq 0 ]]; then
            # Found it, now do some fixup
            fwSetHNets6=$(echo ${fwSetHNets6} \
                | sed -e "s/Header: /create ${fwGroupTmp6} hash:net /")
        else
            die 14 "Target firewall group '${fwGroupNets6}' does not exist"
        fi
    fi
}

#
## Download appropriate blacklist updates
#
doFetch()
{
    debugMsg "doFetch()"
    # This will abort if there was a failure retreiving the URL
    # and there was nothing saved.  If there is content then we
    # continue on.
    #
    fpUsedSourceList="${TMPDIR}/${myName}-${fnUsedSourceList}"
    > ${fpUsedSourceList}
    debugMsg "Starting block file list: '${flBlockList}'"
    for (( i=0; i<${elCtBL}; i++ )); do
        fnUrl="${blUrl[$i]}"
        if [[ -n "${fnUrl}" ]]; then
            printf '[%2.2d] %s\n' $i "${fnUrl}" >> ${fpUsedSourceList}
            fnBase="$(printf '%2.2d' $i)_$(echo ${fnUrl} | \
                awk -F/ '{print $3}')_$(basename ${fnUrl} | \
                sed -e 's/?/_/' -e 's/api_key=[^&]*&\?//')"
            cmdFlg=""
            if [[ -s ${fnBase} ]]; then
                cmdFlg="-z ${fnBase}"
            fi
            logMsg "Fetching '${fnUrl}'"
            ${cmdBaseCURL} -R ${cmdFlg} -o ${fnBase} ${fnUrl}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                errMsg "Could not retrieve URL '${fnUrl}'"
                if [[ -s ${fnBase} ]]; then
                    # Have content, just complain
                    errMsg "cURL error ${rc}"
                else
                    # Nothing received, let's abort
                    die 19 "cURL error ${rc}"
                fi
            fi
            # It is possible (not likely) that the requested file
            # is legitimately empty.  We can ignore if so.
            if [[ -s ${fnBase} ]]; then
                flBlockList="${flBlockList} ${fnBase}"
            fi
        fi
        debugMsg "Updated block file list: '${flBlockList}'"
    done
}

#
## Process updated lists of blacklisted networks and hosts
#
# IPv4
doProcess4()
{
    debugMsg "doProcess4()"
    # Remove comments and blank lines
    # Remove 'hosts.deny' prefixes
    # Remove trailing identifiers
    # Remove IPv6 addresses/networks
    logMsg "Processing block file list (IPv4): '${flBlockList}'"
    cat ${flBlockList} | \
        sed -e '/^[;#]/d' \
            -e '/^[^0-9]/d' \
            -e '/ERROR/d' \
            -e 's/^[[:space:]]*ALL[[:space:]]*:[[:space:]]*//' \
            -e 's#^\(\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\(/[0-9]\{1,2\}\)\?\).*$#\1#' \
            -e '/[\:\::]/d' \
            -e 's/ .*//g' \
            -e 's#//.*##g' \
            -e 's/[^0-9./]*//g' \
            -e '/^$/d' > ${fnTemp1}
    # Sort and remove duplicates
    sort -u ${fnTemp1} -o ${fnTemp2}

    if [[ ${flgDoCounts} -gt 0 ]]; then
        # Save counts, total and unique
        debugMsg "Counting total IPv4 addresses received"
        elCtTot4=$(wc -l ${fnTemp1} | cut -d\  -f1)
        debugMsg "Counting unique IPv4 addresses received"
        elCtUnq4=$(wc -l ${fnTemp2} | cut -d\  -f1)
    fi

    flgOpt=0
    if [[ ${useIPRange} -gt 0 ]]; then
        debugMsg "Using '${cmdBaseIPRange}' for optimizing"
        cmdFlg=""
        cmdFlg2=""
        [[ -n "${ipRangeRedFactor}" ]] && cmdFlg="--reduce-factor ${ipRangeRedFactor}"
        [[ -n "${ipRangeRedEntries}" ]] && cmdFlg="${cmdFlg} --reduce-entries ${ipRangeRedEntries}"
        # If local whitelist exists, exclude those IPs from blacklist
        [[ -s "${fpLocWhiteList}" ]] && cmdFlg2="--exclude-next ${fpLocWhiteList}"
        ${cmdBaseIPRange} ${fnTemp2} ${cmdFlg} ${cmdFlg2} > ${fnTemp3}
        rc=$?
        if [[ ${rc} -eq 0 ]]; then
            flgOpt=1
        else
            errMsg "Failure executing '${cmdBaseIPRange}', rc=${rc}"
            errMsg "Skipping optimization!"
        fi
    fi

    # Only do this if iprange not used or failed
    if [[ ${flgOpt} -eq 0 ]]; then
        # If local whitelist exists, use to filter blacklist
        if [[ -s ${fpLocWhiteList} ]]; then
            comm -23 ${fnTemp2} <(sort ${fpLocWhiteList}) > ${fnTemp3}
        else
            mv ${fnTemp2} ${fnTemp3}
        fi
    fi

    # Save count, final (always need this for maxelem)
    debugMsg "Counting IPv4 filtered addresses"
    elCtFnl4=$(wc -l ${fnTemp3} | cut -d\  -f1)

    if [[ ${flgDoCounts} -gt 0 ]]; then
        # Count total number of prefixes
        debugMsg "Counting IPv4 address prefixes"
        prfxCtFnl4=$(sed -e 's#^\([^/]*\)$#\1/0#' \
            -e 's#.*/\([^/]*\)$#\1#' ${fnTemp3} \
            | sort -u | wc -l)
    fi
}
#
# IPv6
doProcess6()
{
    debugMsg "doProcess6()"
    # Remove comments and blank lines
    # Remove trailing identifiers
    # Remove IPv4 addresses/networks
    logMsg "Processing block file list (IPv6): '${flBlockList}'"
    cat ${flBlockList} | \
        tr '[:upper:]' '[:lower:]' | \
        sed -e '/^[;#]/d' \
            -e '/^[^:0-9a-f]/d' \
            -e '/error/d' \
            -e '/\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}/d' \
            -e 's/ .*//g' \
            -e 's#//.*##g' \
            -e 's/[^0-9,a-z,A-Z,:,/]*//g' \
            -e '/^$/d' > ${fnTemp1}
    # Sort and remove duplicates
    sort -u ${fnTemp1} -o ${fnTemp2}

    if [[ ${flgDoCounts} -gt 0 ]]; then
        # Save counts, total and unique
        debugMsg "Counting total IPv6 addresses received"
        elCtTot6=$(wc -l ${fnTemp1} | cut -d\  -f1)
        debugMsg "Counting unique IPv6 addresses received"
        elCtUnq6=$(wc -l ${fnTemp2} | cut -d\  -f1)
    fi

    # If local whitelist exists, use to filter blacklist
    if [[ -s ${fpLocWhiteList} ]]; then
        comm -23 ${fnTemp2} <(tr '[:upper:]' '[:lower:]' < ${fpLocWhiteList} \
            | sort) > ${fnTemp5}
    else
        mv ${fnTemp2} ${fnTemp5}
    fi

    # Save count, final (always need this for maxelem)
    debugMsg "Counting IPv6 filtered addresses"
    elCtFnl6=$(wc -l ${fnTemp5} | cut -d\  -f1)

    if [[ ${flgDoCounts} -gt 0 ]]; then
        # Count total number of prefixes
        debugMsg "Counting IPv6 address prefixes"
        prfxCtFnl6=$(sed -e 's#^\([^/]*\)$#\1/0#' \
            -e 's#.*/\([^/]*\)$#\1#' ${fnTemp5} \
            | sort -u | wc -l)
    fi
}

#
## Update IPsets
#
#  1. Simulate an 'ipset save' file
#  2. Perform 'ipset restore' to temporary group (IPset)
#  3. Swap temporary and target groups
#  4. Delete temporary group
#
#  When creating the new (temporary) group, set the maxelem
#  explicitly to the total count.  A larger set should never be
#  needed since the group here is fully automated and should
#  never be manually adjusted/expanded.
#
#  The hashsize used is from the existing target set.  This should provide
#  a reasonable starting point while avoiding repeated rehashing as the
#  set is loaded.
#
#  TODO:  Add ability to start with default hashsize rather than existing
#
# IPv4 / inet
doUpdate4()
{
    debugMsg "doUpdate4()"
    logMsg "Applying IPset (IPv4)"
    # Ensure we don't have a list that is too large
    if [[ ${elCtFnl4} -gt ${fwSetMaxElem} ]]; then
        die 15 "IPv4 Blocklist too large (count=${elCtFnl4}, maxelem=${fwSetMaxElem})"
    fi
    # Reset the 'maxelem' value to our new size and save initial header
    echo "${fwSetHNets4}" | sed -e "s/ maxelem [0-9]*//" -e "s/$/ maxelem ${elCtFnl4}/" > ${fnTemp2}
    sed -e "s/^/add ${fwGroupTmp4} /" ${fnTemp3} >> ${fnTemp2}
    debugMsg "Creating temp inet IPset"
    ${cmdBaseIPSet} -! -f ${fnTemp2} restore || \
        die 16 "inet ipset restore failed: error $?"
    debugMsg "Swapping temp and ${fwGroupNets4} IPsets"
    ${cmdBaseIPSet} swap "${fwGroupTmp4}" "${fwGroupNets4}" || \
        die 17 "inet ipset swap failed: error $?"
    debugMsg "Destroying temp inet IPset"
    ${cmdBaseIPSet} destroy "${fwGroupTmp4}"
}
#
# IPv6 / inet6
doUpdate6()
{
    debugMsg "doUpdate6()"
    logMsg "Applying IPset (IPv6)"

    # Ensure we don't have a list that is too large
    if [[ ${elCtFnl6} -gt ${fwSetMaxElem} ]]; then
        die 15 "IPv6 Blocklist too large (count=${elCtFnl6}, maxelem=${fwSetMaxElem})"
    fi
    # Reset the 'maxelem' value to our new size and save initial header
    echo "${fwSetHNets6}" | sed -e "s/ maxelem [0-9]*//" -e "s/$/ maxelem ${elCtFnl6}/" > ${fnTemp2}
    sed -e "s/^/add ${fwGroupTmp6} /" ${fnTemp5} >> ${fnTemp2}
    debugMsg "Creating temp inet6 IPset"
    ${cmdBaseIPSet} -! -f ${fnTemp2} restore || \
        die 16 "inet6 ipset restore failed: error $?"
    debugMsg "Swapping temp and ${fwGroupNets6} IPsets"
    ${cmdBaseIPSet} swap "${fwGroupTmp6}" "${fwGroupNets6}" || \
        die 17 "inet6 ipset swap failed: error $?"
    debugMsg "Destroying temp inet6 IPset"
    ${cmdBaseIPSet} destroy "${fwGroupTmp6}"
}

#
## Send pending email
#
doSendEmail()
{
    debugMsg "doSendEmail()"

    nameUser=$(whoami)
    nameHost=$(uname -n)
    if [[ -s ${fnTemp4} ]]; then
        if egrep 'FATAL:' ${fnTemp4}; then
            mailSubject="Subject: ${nameHost} ${myName} failure"
            mailPrio="X-Priority: 1 (Highest)\nImportance: High"
        else
            mailSubject="Subject: ${nameHost} ${myName} results"
            mailPrio="X-Priority: 3 (Normal)\nImportance: Normal"
        fi
        mailFrom="From: EdgeOS <${nameUser}@${nameHost}>"
        mailTo="To: ${mailDest}"
        mailHeader="${mailFrom}\n${mailTo}\n${mailSubject}\n${mailPrio}"
        (echo -e "${mailHeader}\n\n" && cat ${fnTemp4}) | \
            ${cmdBaseSSMTP} "${mailDest}"
    fi
}

#
## Ensure cleanup
#
atExit()
{
    debugMsg "atExit()"

    doSendEmail
    [[ -n "${tmpFileList}" ]] && rm -f ${tmpFileList}
    ${cmdBaseIPSet} -q destroy "${fwGroupTmp4}"
    ${cmdBaseIPSet} -q destroy "${fwGroupTmp6}"
}

#
## Finish up
#
finishup()
{
    debugMsg "finishup()"

    if [[ -n "${fwGroupNets4}" ]]; then
        logMsg "IPv4 blocklist items fetched: ${elCtTot4}, unique: ${elCtUnq4}, final: ${elCtFnl4}"
        logMsg "Total IPv4 prefix length count (including hosts): ${prfxCtFnl4}"
        # Save new group persistently
        if [[ -n "${fpIPSetSave4}" ]]; then
            debugMsg "Saving inet IPset to '${fpIPSetSave4}'"
            ${cmdBaseIPSet} -f ${fpIPSetSave4} save ${fwGroupNets4}
        fi
    fi
    if [[ -n "${fwGroupNets6}" ]]; then
        logMsg "IPv6 blocklist items fetched: ${elCtTot6}, unique: ${elCtUnq6}, final: ${elCtFnl6}"
        logMsg "Total IPv6 prefix length count (including hosts): ${prfxCtFnl6}"
        # Save new group persistently
        if [[ -n "${fpIPSetSave6}" ]]; then
            debugMsg "Saving inet6 IPset to '${fpIPSetSave6}'"
            ${cmdBaseIPSet} -f ${fpIPSetSave6} save ${fwGroupNets6}
        fi
    fi
    # All done
    logMsg "Finished at $(pTimeNow)"
}

#
#-----------------------------------------------------------

#-----------------------------------------------------------
##
## Now the work (Main)
##

trap atExit EXIT

startup
doFetch
if [[ -n "${fwGroupNets4}" ]]; then
    doProcess4
    doUpdate4
fi
if [[ -n "${fwGroupNets6}" ]]; then
    doProcess6
    doUpdate6
fi
finishup

exit 0
