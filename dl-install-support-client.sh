#!/bin/zsh

# Beyondtrust Remote Support download and install script

# Logging output to a file for testing
#time=$( date "+%d%m%y-%H%M" )
#set -x
#logfile=/private/tmp/bomgar-"$time".log
#exec > $logfile 2>&1

# Set credential variables here
clientid=""
clientse=''
b64creds=$( printf "$clientid:$clientse" | /usr/bin/iconv -t ISO-8859-1 | /usr/bin/base64 -i - )

# Set Beyondtrust API creds here
url="https://CORPORATE.bomgarcloud.com"
token="oauth2/token"
base="api/config/v1"
jumpgroup="jump-group"
jumpclient="jump-client"
installer="jump-client/installer"

# Misc information we need to supply for this to work
jumpgroupname="ADD NAME HERE"
platform="mac-dmg"
dlfolder="/private/tmp"

# Who's the current user and their details?
currentuser=$( /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}' )
userid=$( /usr/bin/id -u $currentuser )

#####
## Download the latest BeyondTrust client from their API
#####

# Request bearer access token using the API
request=$( /usr/bin/curl -s -X POST "${url}/${token}" \
-H "accept: application/json" \
-H "Authorization: Basic ${b64creds}" \
-d "grant_type=client_credentials" )

# Extract the bearer token from the json output above
access_token=$( /usr/bin/plutil -extract access_token raw -o - - <<< "$request" )

# Get a list of the jump groups
groups=$( /usr/bin/curl -s -X GET "${url}/${base}/${jumpgroup}" \
-H "Accept: application/json" \
-H "Authorization: Bearer ${access_token}" )

# Find the group ID number based on the jump group name
# Since BeyondTrust does multiple json dictionaries, the parsing of this is ... fraught.
# Grab the entire list, convert all the },{ separators so the comma is a newline instead.
# We can then grep for the line with the name we want. Split that into multiple lines,
# find the id line and extract the value. Yuck but it works.
groupid=$( echo $groups \
	| /usr/bin/sed 's/},{/}\n{/g' \
	| /usr/bin/grep "$jumpgroupname" \
	| /usr/bin/sed 's/,/\n/g' \
	| /usr/bin/grep id \
	| /usr/bin/cut -d":" -f2 )

# We're ready to request the download. First form the data to pass to the API
# Feed it the groupid from before.
# session policy id 3 is none.
# session policy id 4 is the Do Not Prompt: Screen Sharing option.
# session policy id 5 is the Prompt User: Screen Sharing option.
# Modification suggested by @Partario on mac admins slack for silent installation, by replacing the "is_quiet" for "customer_client_start_mode".
jumpclientconfig='{
    "name":"",
    "jump_group_id":'$groupid',
    "jump_policy_id":null,
    "jump_group_type":"shared",
    "connection_type":"active",
    "attended_session_policy_id":5,
    "unattended_session_policy_id":5,
    "valid_duration":30,
    "elevate_install":true,
    "elevate_prompt":true,
    "customer_client_start_mode":"hidden",
    "allow_override_jump_group":false,
    "allow_override_jump_policy":false,
	"allow_override_name":false,
	"allow_override_comments":false
}'

# Use the prepared json above to get the installer unique id
uid=$( /usr/bin/curl -s -X POST "${url}/${base}/${installer}" \
-d "${jumpclientconfig}" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer ${access_token}" )

# Extract the installer ID from the output
installer_id=$( /usr/bin/plutil -extract installer_id raw -o - - <<< "$uid" )
filename=$( /usr/bin/plutil -extract key_info.mac-osx-x86.filename raw -o - - <<< "$uid" )

# Download latest installer to private tmp folder. Retry if required.
for loop in {1..10};
do
	echo "Download attempt: [$loop / 10]"
	test=$( /usr/bin/curl -s \
		-X GET "${url}/${base}/${installer}/${installer_id}/${platform}" \
		-H "Accept: application/json" \
		-H "Authorization: Bearer ${access_token}" \
		-w "%{http_code}" \
		-o ${dlfolder}/${filename} )
	[ "$test" = "200" ] && break
done

# Did the download actually work. Error if not.
[ "$test" != "200" ] && { echo "Download failed. Exiting."; exit 1; }

#####
## Check and uninstall any previous installations.
#####

# Find the existing Bomgar install in /Users then run the uninstall command
/usr/bin/find /Users/Shared /Applications -iname "sdcust" -type f -maxdepth 5 -exec {} -uninstall silent \;
sleep 3

# This is the manual cleanup process. Uninstall should remove everything
# however this will also catch any previous failed installations.

# Are there any LaunchAgents from a previous install?
test=$( /usr/bin/find /Library/LaunchAgents -iname "com.bomgar.bomgar*.plist" | /usr/bin/wc -l | /usr/bin/awk '{ print $1 }' )

# More than zero means we have work to do
if [ "$test" -gt 0 ];
then
	# Attempt to unload all the launchd agents and daemons
	# Apple's new launchctl commands means we have to get output from root and user
	# separately, then extract the launchd service names and finally unload them.
	# array variables so we can deal with more than one service potentially loaded.
	laarray=($( /usr/bin/su - $currentuser -c "/bin/launchctl list" | /usr/bin/grep com.bomgar | /usr/bin/awk '{ print $3 }' ))
	for la ($laarray); do /bin/launchctl bootout user/$la; done

	ldarray=($( /bin/launchctl list | /usr/bin/grep com.bomgar | /usr/bin/awk '{ print $3 }' ))
	for ld ($ldarray); do /bin/launchctl bootout system/$ld; done

	# Remove all the launchd agents and daemons
	/usr/bin/find /Library/LaunchAgents -iname "*com.bomgar*.plist" -exec rm -rf {} \;
	/usr/bin/find /Library/LaunchDaemons -iname "*com.bomgar*.plist" -exec rm -rf {} \;
	/usr/bin/find /Library/LaunchDaemons -iname "*com.bomgar*.helper" -exec rm -rf {} \;

	# Remove any existing install folders
	/bin/rm -rf /Users/Shared/bomgar-scc*
	/bin/rm -rf /Users/Shared/.com.bomgar.scc.*
	/bin/rm -rf /Applications/.com.bomgar*
fi

# Check the API to see if there's an existing record for the current hostname
# Remove if exists

# Generate the query date we require. As long as our hostnames are correct,
# then we can find the mac we're running on.

# Do the API query for the hostname. Strip off any opening [ ] characters.
# It can break the json parsing otherwise.
devicerecord=$( /usr/bin/curl -s -X GET "${url}/${base}/${jumpclient}?name=$( hostname )" \
-H "Content-Type: application/json" \
-H "Authorization: Bearer ${access_token}" | /usr/bin/sed 's/[][]//g' )

if [ ! -z "$devicerecord" ];
then
	# Existing record detected. Find it's ID number
	deviceid=$( /usr/bin/plutil -extract id raw -o - - <<< "$devicerecord" )

	# Issue an API delete command to delete that ID before proceeding
	/usr/bin/curl -s -X DELETE "${url}/${base}/${jumpclient}/${deviceid}" \
		-H "accept: application/json" \
		-H "Authorization: Bearer ${access_token}"

	# Wait a few seconds to let the system sort itself out
	sleep 5
fi

#####
## We're ready finally to install the application.
#####

# Create a temporary folder to mount the dmg to.
tmpmnt=$( /usr/bin/mktemp -d /private/tmp/tempinstall.XXXXXX )

# Error check to see if temporary folder was created. Fail out if not. Unlikely.
if [ $? -ne 0 ];
then
	echo "$0: Cannot create temporary folder. Exiting."
	exit 1
fi

# Mount the dmg into the temporary folder we just created. Make sure it doesn't annoy the user by hiding what it's doing.
/usr/bin/hdiutil attach "${dlfolder}/${filename}" -mountpoint "$tmpmnt" -nobrowse -noverify -noautoopen

# Find the path of the binary we're looking for
sdc=$( /usr/bin/find "$tmpmnt" -iname "sdcust" -type f )

# Run the install binary
"$sdc" --silent
sleep 20

# Unmount the disk image
/usr/sbin/diskutil unmount force "$tmpmnt"

# Remove the temporary mount point and downloaded file.
/bin/rm -rf "$tmpmnt"
/bin/rm -rf "$filename"

# All done
exit 0
