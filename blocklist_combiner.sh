#!/usr/bin/sh

################################################################################
# rpz_blocklist_combiner.sh
# Version: 1.0.7 (for Ubuntu)
# An amateurish shell script to download, make consistent, and merge RPZ
# blocklists for Unbound, deleting duplicate entries. Now with user
# allowlisting and user blocklisting, oo-ee.
################################################################################

# Uncomment for debug output
#set -x

# Eat your variables
readonly CHOWN="/usr/bin/chown"
readonly CP="/usr/bin/cp"
readonly CURL="/usr/bin/curl"
readonly DATE="/usr/bin/date"
readonly GREP="/usr/bin/grep"
readonly INIT_SERVICE="/usr/bin/systemctl"
readonly MV="/usr/bin/mv"
readonly RM="/usr/bin/rm"
readonly SED="/usr/bin/sed"
readonly SORT="/usr/bin/sort"
readonly UNBOUND_CHECKCONF="/usr/sbin/unbound-checkconf"
#readonly WGET="/usr/bin/wget"

readonly INIT_COMMAND="restart unbound.service"

readonly UNBOUND_USER="unbound"
readonly UNBOUND_GROUP="unbound"
readonly UNBOUND_CONF_DIR="/etc/unbound/blocklist_combiner"

readonly LIST_URL_01="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/rpz/ultimate.txt"
readonly LIST_URL_02="https://big.oisd.nl/rpz"
readonly LIST_URL_03="https://raw.githubusercontent.com/badmojr/1Hosts/master/Pro/rpz.txt"
readonly LIST_URL_04="https://urlhaus.abuse.ch/downloads/rpz/"

readonly LIST_TMPFILE_01="$UNBOUND_CONF_DIR/blocklist_hagezi-multi-ultimate.tmp"
readonly LIST_TMPFILE_02="$UNBOUND_CONF_DIR/blocklist_oisd-big.tmp"
readonly LIST_TMPFILE_03="$UNBOUND_CONF_DIR/blocklist_1hosts-pro.tmp"
readonly LIST_TMPFILE_04="$UNBOUND_CONF_DIR/blocklist_urlhaus.tmp"

readonly LIST_TMPFILE_ALL="$UNBOUND_CONF_DIR/blocklist_*.tmp"

readonly USER_ALLOWLIST="$UNBOUND_CONF_DIR/user_allowlist.txt"
readonly USER_BLOCKLIST="$UNBOUND_CONF_DIR/user_blocklist.txt"

readonly LIST_COMBINED_TMP="$UNBOUND_CONF_DIR/blocklist_combined.staging"
readonly LIST_COMBINED="$UNBOUND_CONF_DIR/blocklist_combined.rpz"

# RPZ header serial number = seconds since the Epoch (1970-01-01 00:00 UTC)
#RPZ_HEADER_SERIAL=`$DATE +"%s"`
RPZ_HEADER_SERIAL=$($DATE +"%s")
RPZ_HEADER_LINE_01="\$TTL 300\\n"
RPZ_HEADER_LINE_02="@ SOA localhost. root.localhost. $RPZ_HEADER_SERIAL 43200 3600 86400 120\\n"
RPZ_HEADER_LINE_03="  NS  localhost.\\n"

###########################
## Start doing the thing ##
###########################

# Check if a combined blocklist exists and, if so, make a backup
if test -f "${LIST_COMBINED}"; then
    (>&2 printf "Found existing combined blocklist, making backup...\n")
    "$CP" "${LIST_COMBINED}" "${LIST_COMBINED}.backup"
fi

# Fetch the blocklists
(>&2 printf "Downloading blocklists...\n")
"$CURL" --silent "${LIST_URL_01}" -o "${LIST_TMPFILE_01}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_01}") ; exit 1; }
"$CURL" --silent "${LIST_URL_02}" -o "${LIST_TMPFILE_02}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_02}") ; exit 1; }
"$CURL" --silent "${LIST_URL_03}" -o "${LIST_TMPFILE_03}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_03}") ; exit 1; }
"$CURL" --silent "${LIST_URL_04}" -o "${LIST_TMPFILE_04}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_04}") ; exit 1; }

# Strip comments and any existing RPZ headers
"$SED" -i '/^\;.*$/d' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_ALL}") ; exit 1; }
"$SED" -i '/^\@.*$/d' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_ALL}") ; exit 1; }
"$SED" -i '/^\$.*$/d' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_ALL}") ; exit 1; }
"$SED" -i '/^.*NS.*$/d' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_ALL}") ; exit 1; }
# Strips inline comments from urlhaus list
"$SED" -i 's/\ \;\ .*//' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_ALL}") ; exit 1; }

# Add the wildcard domains to the urlhaus list
if test -f "${LIST_TMPFILE_04}"; then
    "$GREP" -E -v '^#|^$' ${LIST_TMPFILE_04} | while IFS= read -r URLHAUS_BLOCKLIST_ENTRY; do
        printf "*.%s\n" "${URLHAUS_BLOCKLIST_ENTRY}" >> ${LIST_TMPFILE_04} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_04}") ; exit 1; }
    done
fi

# Delete lines longer than 256 character to avoid a bug in Unbound (248 characters + the later added ' CNAME .')
"$SED" -i '/^.\{247\}./d' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong checking line lengths, exiting\n") ; exit 1; }
"$SED" -i '/^\*\..\{247\}./d' ${LIST_TMPFILE_ALL} || { (>&2 printf "Something went wrong checking line lengths, exiting\n") ; exit 1; }

(>&2 printf "Creating the combined blocklist...\n")

# Combine the .tmp files and append them to the combined blocklist file
"$SORT" -u -f ${LIST_TMPFILE_ALL} > "${LIST_COMBINED_TMP}" || { (>&2 printf "Something went wrong combining the blocklists, exiting\n") ; exit 1; }

# Add the RPZ headers at the start of the file
"$SED" -i "1s/^/$RPZ_HEADER_LINE_01$RPZ_HEADER_LINE_02$RPZ_HEADER_LINE_03/" "${LIST_COMBINED_TMP}" || { (>&2 printf "Something went wrong adding the RPZ header, exiting\n") ; exit 1; }

# Basic blocklist filtering
if test -f "${USER_BLOCKLIST}"; then
    (>&2 printf "Processing user blocklist...\n")
    "$GREP" -E -v '^#|^$' ${USER_BLOCKLIST} | while IFS= read -r USER_BLOCKLIST_ENTRY; do
        printf "*.%s CNAME .\n" "${USER_BLOCKLIST_ENTRY}" >> ${LIST_COMBINED_TMP} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_BLOCKLIST}") ; exit 1; }
        printf "%s CNAME .\n" "${USER_BLOCKLIST_ENTRY}" >> ${LIST_COMBINED_TMP} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_BLOCKLIST}") ; exit 1; }
    done
fi

# Basic allowlist filtering
if test -f "${USER_ALLOWLIST}"; then
    (>&2 printf "Processing user allowlist...\n")
    "$GREP" -E -v '^#|^$' ${USER_ALLOWLIST} | while IFS= read -r USER_ALLOWLIST_ENTRY; do
        "$SED" -i "/\*\."${USER_ALLOWLIST_ENTRY}"\ CNAME\ \./d" ${LIST_COMBINED_TMP} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_ALLOWLIST}") ; exit 1; }
        "$SED" -i "/"${USER_ALLOWLIST_ENTRY}"\ CNAME\ \./d" ${LIST_COMBINED_TMP} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_ALLOWLIST}") ; exit 1; }
    done
fi

"$MV" "${LIST_COMBINED_TMP}" "${LIST_COMBINED}" || { (>&2 printf "Moving the blocklist .tmp file to its final destination failed, exiting\n") ; exit 1; }

"$RM" ${LIST_TMPFILE_ALL}

# Make sure everything is owned by UNBOUND_USER and UNBOUND_GROUP
(>&2 printf "Changing user and group of Unbound configuration directory...\n")
"$CHOWN" -R ${UNBOUND_USER}:${UNBOUND_GROUP} ${UNBOUND_CONF_DIR} || { (>&2 printf "Something went wrong while changing ownership of the %s directory, exiting\n" "${UNBOUND_CONF_DIR}") ; exit 1; }

# Check the Unbound configuration and restart Unbound if all is well.
# If an error is found, Unbound is not restarted
if "$GREP" -q -w -i "no errors" "$UNBOUND_CHECKCONF"; then
    (>&2 printf "No errors found in unbound.conf, reloading Unbound configuration...\n")
    "$INIT_SERVICE" $INIT_COMMAND || { (>&2 printf "Something went wrong reloading Unbound's configuration, exiting\n") ; exit 1; }
    exit
else
    (>&2 printf "Errors found in unbound.conf, not reloading Unbound configuration\n")
    exit
fi
