#!/bin/bash
#
# vim: tabstop=8 expandtab shiftwidth=4 softtabstop=4
#
#------------------------------------------------------------------------------
# Automated Blacklist firewall group reloading for Ubiquiti EdgeRouters
#
# 07 May 2017:  v 1.2
#    - Add IPv6 support
#
# 21 Sept 2015:  v 1.1
#    - Minor updates and fixes
#
# 19 Sept 2015:  v 1.0
#    - Initial release
#
#------------------------------------------------------------------------------
#
# Copyright (c) 2017 Waterside Consulting, inc.
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
##
## Configuration
##
#
# Place this file in /config/scripts/post-config.d
#
# Firewall blacklist groups
#   These network-groups must already exist.
#   These shoudld be created via EdgeOS BUI or CLI, and to have any
#     effect must be assigned to one or more firewall rules
#   Leave empty to not populate IPset netgroup
fwGroupNets4="Nets4-BlackList"
fwGroupNets6="Nets6-BlackList"

# Persistent data location (directory)
dirUserData="/config/user-data"
#
# File to retrieve persistent IPSET content (file, at least one required)
fnIPSetSave4="fw-IPSET-4.txt"
fnIPSetSave6="fw-IPSET-6.txt"
#
# Default verbosity (for messages to display/tty)
#   0 = Completely silent
#   1 = + errors and failures
#   2 = + informational status
#   3 = + cURL status output
#   9 = + debug output
verbose=0

#
# Use email for messages
#   Values same as for 'verbosity' above
#   /etc/ssmtp/ssmtp.conf must be minimally configured to be
#     able to send email.  At minimum mailhub may need to be defined
#     along with any potential authentication needed.
useMail=0
#
# Destination for email messages, if enabled
mailDest="USER@MAILDOMAIN.com"

#
# Use 'logger' (syslog) for messages
#   Values same as for 'verbosity' above
useLogger=2

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
##  14:  Specified fiewall group (IP set) does not exist
##  15:  IPset save file does not exist
##  16:  ipset restore (to tmp group) failed
##  17:  ipset swap (tmp and target groups) failed
##  18:  No firewall group(s) configured
##
#-----------------------------------------------------------

#-----------------------------------------------------------
##
## Definitions
##
[[ -n "${fnIPSetSave4}" ]] && fpIPSetSave4="${dirUserData}/${fnIPSetSave4}"
[[ -n "${fnIPSetSave6}" ]] && fpIPSetSave6="${dirUserData}/${fnIPSetSave6}"

cmdBaseIPSet="sudo ipset"
cmdBaseSSMTP="/usr/sbin/ssmtp"

fwGroupTmp4="bl_tmp_4"
fwGroupTmp6="bl_tmp_6"
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
    echo "$(date +%FT%T%Z): $*" >> "${fnTemp1}"
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
    if [ -z "${fnTemp1}" -o ! -w "${fnTemp1}" ]; then
        die 13 "Could not create temporary files"
    fi
    tmpFileList="${fnTemp1}"

    #  Now we can start logging via email, if desired
    if [[ -x ${cmdBaseSSMTP} ]]; then
        useMail=${saveUseMail}
    elif [[ ${saveUseMail} -ne 0 ]]; then
        errMsg "Missing MTA '${cmdBaseSSMTP}'.  Will not send email"
    fi
    logMsg "Starting at ${strTime}"

    # Ensure at least one netgroup is defined
    [[ -z "${fwGroupNets4}" && -z "${fwGroupNets6}" ]] && \
        die 18 "No firewall groups (IPsets) configured (Nothing to do!)"

    if [[ -n "${fwGroupNets4}" && ! -s ${fpIPSetSave4} ]]; then
        die 15 "IPset save file '${fpIPSetSave4}' does not exist or is empty"
    fi
    if [[ -n "${fwGroupNets6}" && ! -s ${fpIPSetSave6} ]]; then
        die 15 "IPset save file '${fpIPSetSave6}' does not exist or is empty"
    fi

    if [ ${useMail} -gt 1 -o ${useLogger} -gt 1 -o ${verbose} -gt 1 ]; then
        flgDoCounts=1;
    else
        flgDoCounts=0;
    fi

    if [ ${useMail} -le 1 -a ${useLogger} -le 1 -a ${verbose} -le 1 ]; then
      cmdBaseIPSet="${cmdBaseIPSet} -q"
    fi

    # Verify firewall group(s) exist and save creation parameters
    if [[ -n "${fwGroupNets4}" ]]; then
        fwSetHNets4=$(${cmdBaseIPSet} -t list ${fwGroupNets4} | egrep '^Header')
        if [[ $? -ne 0 ]]; then
            die 14 "Target firewall group '${fwGroupNets4}' does not exist"
        fi
    fi
    if [[ -n "${fwGroupNets6}" ]]; then
        fwSetHNets6=$(${cmdBaseIPSet} -t list ${fwGroupNets6} | egrep '^Header')
        if [[ $? -ne 0 ]]; then
            die 14 "Target firewall group '${fwGroupNets6}' does not exist"
        fi
    fi
}

#
## Load IPsets
#
#  1. Perform 'ipset restore' to temporary group (IPset)
#  2. Swap temporary and target groups
#  3. Delete temporary group
#
# IPv4
doLoad4()
{
    debugMsg "doLoad4()"

    debugMsg "Creating temp inet IPset"

    sed -e "s/${fwGroupNets4}/${fwGroupTmp4}/g" ${fpIPSetSave4} | \
        ${cmdBaseIPSet} -! restore || \
        die 16 "ipset restore failed: error $?"
    debugMsg "Swapping temp and ${fwGroupNets4} IPsets"
    ${cmdBaseIPSet} swap "${fwGroupTmp4}" "${fwGroupNets4}" || \
        die 17 "inet ipset swap failed: error $?"
    debugMsg "Destroying temp inet IPset"
    ${cmdBaseIPSet} destroy "${fwGroupTmp4}"

    if [[ ${flgDoCounts} -gt 0 ]]; then
        # Count total number of prefixes
        debugMsg "Counting IPv4 address prefixes"
        prfxCtFnl4=$(${cmdBaseIPSet} list ${fwGroupNets4} | \
            sed -e '/^[^0-9]/d' -e 's#^\([^/]*\)$#\1/0#' \
                -e 's#.*/\([^/]*\)$#\1#' | sort -u | wc -l)
        # Count total number of elements
        debugMsg "Counting total IPv4 addresses "
        elCtFnl4=$(${cmdBaseIPSet} list ${fwGroupNets4} | \
            egrep '^[0-9]' | wc -l)
    fi
}
# IPv6
doLoad6()
{
    debugMsg "doLoad6()"

    debugMsg "Creating temp inet6 IPset"

    sed -e "s/${fwGroupNets6}/${fwGroupTmp6}/g" ${fpIPSetSave6} | \
        ${cmdBaseIPSet} -! restore || \
        die 16 "ipset restore failed: error $?"
    debugMsg "Swapping temp and ${fwGroupNets6} IPsets"
    ${cmdBaseIPSet} swap "${fwGroupTmp6}" "${fwGroupNets6}" || \
        die 17 "inet6 ipset swap failed: error $?"
    debugMsg "Destroying temp inet6 IPset"
    ${cmdBaseIPSet} destroy "${fwGroupTmp6}"

    if [[ ${flgDoCounts} -gt 0 ]]; then
        # Count total number of prefixes
        debugMsg "Counting IPv6 address prefixes"
        prfxCtFnl6=$(${cmdBaseIPSet} list ${fwGroupNets6} | \
            egrep -v '^(Nam|Hea|Siz|Ref|Mem|Typ|Rev)' | \
            sed -e 's#^\([^/]*\)$#\1/0#' -e 's#.*/\([^/]*\)$#\1#' | \
            sort -u | wc -l)
        # Count total number of elements
        debugMsg "Counting total IPv6 addresses "
        elCtFnl6=$(${cmdBaseIPSet} list ${fwGroupNets6} | \
            egrep -v '^(Nam|Hea|Siz|Ref|Mem|Typ|Rev)' | wc -l)
    fi
}

#
## Send pending email
#
doSendEmail()
{
    debugMsg "doSendEmail()"

    nameUser=$(whoami)
    nameHost=$(uname -n)
    if [[ -s ${fnTemp1} ]]; then
        if egrep 'FATAL:' ${fnTemp1}; then
            mailSubject="Subject: ${nameHost} ${myName} failure"
            mailPrio="X-Priority: 1 (Highest)\nImportance: High"
        else
            mailSubject="Subject: ${nameHost} ${myName} results"
            mailPrio="X-Priority: 3 (Normal)\nImportance: Normal"
        fi
        mailFrom="From: EdgeOS <${nameUser}@${nameHost}>"
        mailTo="To: ${mailDest}"
        mailHeader="${mailFrom}\n${mailTo}\n${mailSubject}\n${mailPrio}"
        (echo -e "${mailHeader}\n\n" && cat ${fnTemp1}) | \
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

    if [[ ${flgDoCounts} -gt 0 ]]; then
        [[ -n "${fwGroupNets4}" ]] && \
            logMsg "Loaded ${elCtFnl4} IPv4 addresses with ${prfxCtFnl4} prefix lengths"
        [[ -n "${fwGroupNets6}" ]] && \
            logMsg "Loaded ${elCtFnl6} IPv6 addresses with ${prfxCtFnl6} prefix lengths"
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
[[ -n "${fwGroupNets4}" ]] && doLoad4
[[ -n "${fwGroupNets6}" ]] && doLoad6
finishup

exit 0
