#!/bin/bash

# Name: DeferralScriptfor apps based on time
# Date: 25 Feb 2021
# Author: Elton Asher Jose Menezes
# Purpose: to provide a way to defer software update up to a set number of times based on time

# If app is open, alert user with the option to quit the app or defer for later. If user chooses to install it will quit the app, trigger the installation,
# then alert the user the policy is complete with the option to reopen the app. If the app is not open it will trigger the installation without alerting
# Quit and Open path have 2 entries for the times you are quiting/uninstalling an old version of an app that is replaced by a new name (for example quiting Adobe Acrobat Pro, which is replaced by Adobe Acorbat.app)

################################DEFINE VARIABLES################################

# $4 = Title - not in use. Using $6 as a substitute
# $4 = Url - ARM
# $5 = App ID / Process Name
# $6 = Process Name
# $7 = Jamf Policy Event - not in use
# $7 = icon
# $8 = Quit App Path
# $9 = Open App Path - not in use. Using $8 for open app path
# $9 = File looking for - .pkg
# $9 = Url of Intel link
# $10 - url to reader page

jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
qd="Quit & Update"
# Not in use - icon="/Applications/zoom.us.app/Contents/Resources/ZPLogo.icns"
icon="$7"
#Defining the Sender ID as self service due to setting the Sender ID as the actual app being updated would often cause the app to crash
sender="com.jamfsoftware.selfservice.mac"

#Jamf parameters can't be passed into a function, redefining the app path to be used within the funciton
quitPath="${8}"
openPath="${8}" # Using the same parameters for opening and closing
#openPath="$9" - not in use
appPath="${8}"
appName="${6}"
appID="${5}"

#INSTALLEDVERSION=$( defaults read "$appPath/Contents/Info.plist" CFBundleShortVersionString )
#echo "INSTALLEDVERSION after appPath : $INSTALLEDVERSION"

################################SETUP FUNCTIONS TO CALL################################
#Function to get the current user
fGetCurrenUser (){
currentUser=`python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");'`
#Another way to get the current user but not used here. current=$(stat -f%Su /dev/console)
  # Identify the UID of the logged-in user
  currentUserUID=`id -u "${currentUser}"`
}
#Function to close the app
fQuitApp (){
#  quitPath="/Applications/Google Chrome.app"
cat > /private/tmp/quit_application.sh <<EOF
#!/bin/bash

/bin/launchctl asuser "${currentUserUID}" /usr/bin/osascript -e 'tell application "${quitPath}" to quit' 2> /dev/null
EOF

/bin/chmod +x /private/tmp/quit_application.sh
/bin/launchctl asuser "${currentUserUID}" sudo -iu "${currentUser}" "/private/tmp/quit_application.sh"
/bin/rm -f "/private/tmp/quit_application.sh"
}
#Function to open the app
fOpenApp (){
#  openPath="/Applications/Google Chrome.app"
  cat > /private/tmp/open_application.sh <<EOF
#!/bin/bash

/usr/bin/open "${openPath}"
EOF

/bin/chmod +x /private/tmp/open_application.sh
/bin/launchctl asuser "${currentUserUID}" sudo -iu "${currentUser}" "/private/tmp/open_application.sh"
/bin/rm -f "/private/tmp/open_application.sh"
}


################################ALERTER MESSAGE OPTIONS################################

saveQuitMSG="The Application must be quit in order to update.
Save all data before quitting."
updatedMSG="The application has been updated. Thank you."

# setup logging
logFile="/var/log/os-update-deferral.log"

# Check for / create logFile
if [ ! -f "${logFile}" ]; then
    # logFile not found; Create logFile
    /usr/bin/touch "${logFile}"
fi

## logging courtesy Dan Snelson (@dan.snelson)
function ScriptLog() { # Re-direct logging to the log file ...

    exec 3>&1 4>&2        # Save standard output and standard error
    exec 1>>"${logFile}"    # Redirect standard output to logFile
    exec 2>>"${logFile}"    # Redirect standard error to logFile

    NOW=`date +%Y-%m-%d\ %H:%M:%S`
    /bin/echo "${NOW}" " ${1}" >> ${logFile}

}

url="${4}" #ARM
intel_arm_url="${4}"
# -z means if the variable if empty
arch=$(/usr/bin/arch)
if [ "$arch" == "arm64" ]; then
    echo "<result> ARM - Apple Silicon - $arch</result>"
    if ([ ! -z "${4}" ] && [ ! -z "${9}" ]); then
      echo "<result>Both ARM and Intel URL's exist but inside ARM condition</result>"
      url="${4}"
    elif  ([ ! -z "${4}" ] && [ -z "${9}" ]); then
      echo "<result>Condition met is Universal</result>"
      url="${4}"
    fi
elif [ "$arch" == "i386" ]; then
    echo "<result>Intel - Architecture</result>"
    if [ ! -z "${4}" ] && [ ! -z "${9}" ]; then
      echo "<result>Both ARM and Intel URL's exist but inside Intel condition</result>"
      url="${9}"
    elif  [ ! -z "${4}" ] && [ -z "${9}" ]; then
      echo "<resultCondition met is Universal</result>"
      url="${4}"
    fi
else
    echo "<result>Unknown Architecture</result>"
    exit 1
fi

#path to jamfhelper
jhpath="/Library/Application Support/JAMF/bin/jamfhelper.app/Contents/MacOS/jamfhelper"
#path to counter file
counterpathplist="/Library/Application Support/JAMF/${appName}/com.g2.osupdatedeferral.plist"
#path to lastDeferralTimeplist
lastDeferralTimeplist="/Library/Application Support/JAMF/${appName}/lastDeferralTime.plist"

if [ ! -f "$counterpathplist" ] && [ ! -f "$lastDeferralTimeplist" ]; then
    rm "$logFile"
    /usr/bin/touch "${logFile}"
fi

ScriptLog "Starting deferral run"

 extract_latest_version(){
   # used to extract the latest version from a website.
   # /usr/bin/grep -Eo '^.{4}$' can be used to extract a version number of a specific length.
   # generic extraction code: perl -pe 'if(($_)=/([0-9]+([.][0-9]+)+)/){$_.="\n"}' | /usr/bin/sort -Vu | /usr/bin/tail -n 1
   perl -pe 'if(($_)=/([0-9]+([.][0-9]+)+)/){$_.="\n"}' | /usr/bin/sort -Vu | /usr/bin/grep -Eo '^.{5}$' | /usr/bin/tail -n 1
 }

 get_installed_version(){
   # description of what function does.
   local description='Read and return version information from the Info.plist of the defined application.(aka: obtain version information for currently installed application.)'

   # define local variables.
   local applicationPath="${1}"
   local installedVersion
 echo "Application Path : $applicationPath"
   # if the application path is defined and is a directory attempt to read and return version information
   if [[ -z "${applicationPath}" || ! -d "${applicationPath}" ]]; then
   echo "application not installed or path undefined."
 else
 #   installedVersion="$( /usr/bin/defaults read "${applicationPath}"/Contents/Info CFBundleShortVersionString 2> /dev/null )" || error 'could not detect installed version.'
   installedVersion=$( defaults read "$appPath/Contents/Info.plist" CFBundleShortVersionString )
   echo "Installed version inside function : $installedVersion"

 #   currentvers=$(defaults read /Applications/Google\ Chrome.app/Contents/Info.plist CFBundleShortVersionString)
 #   echo "Current Version: $currentvers"
 fi
   if [[ -z "${installedVersion}" ]]; then
   echo "installed version undefined."
 fi
   # return installed version.
   printf '%s\n' "${installedVersion}"
 }

appdir=`basename "${5}"`
 download(){
  # description of what function does.
  local description='Downloads a file from a given URL to a temporary directory and returns the full path to the download.'

  # define local variables.
  local dlURL="${1}"
  dlDir=''
  local dlName
  local productVer
  local userAgent
  downloadPath=''
  tempfoo=`basename "downloads"`
  echo "dlURL from value passed: $dlURL"
  # if the download URL was provided. Build the effective URL (this helps if the given URL redirects to a specific download URL.)
  if [[ -z "${dlURL}" ]]; then
    echo "error download url undefined."
    exit 1
  fi
  dlURL="$( /usr/bin/curl "${dlURL}" -s -L -I -o /dev/null -w '%{url_effective}' )" || error 'failed to determine effective URL.'
  echo "Effective dlURL : $dlURL"
  # create temporary directory for the download.
#  dlDir="$( /usr/bin/mktemp -d 2> /dev/null )" || error 'failed to create temporary download directory.'
  dlDir=`mktemp -d "/private/tmp/$appdir"`

  if [[ ! -d "${dlDir}" ]]; then
  echo "error temporary download directory does not exist."
  exit 1
  fi
  export dlDir
  echo "Temporary Directory = $dlDir"
  # build user agent for curl.
  productVer="$( /usr/bin/sw_vers -productVersion | /usr/bin/tr '.' '_' )" || error 'could not detect product version needed for user agent.'
  if [[ -z "${productVer}" ]]; then
    echo "error product version undefined"
    exit 1
  fi
  userAgent='Mozilla/5.0 (Macintosh; Intel Mac OS X '"${productVer})"' AppleWebKit/535.6.2 (KHTML, like Gecko) Version/5.2 Safari/535.6.2'

  # change the present working directory to the temporary download directory and attempt download.
  cd "${dlDir}" || error 'could not change pwd to temporary download directory.'
  #dlName="$( /usr/bin/curl -sLJO -A "${userAgent}" -w "%{filename_effective}" --retry 10 "${dlURL}" )" || error 'failed to download latest version.'
#Working but throws error when internet failed:  dlName="$( /usr/bin/curl -LJO -A "${userAgent}" -w "%{filename_effective}" --retry 10 "${dlURL}" )" || error 'failed to download latest version.'
  if ! dlName="$( /usr/bin/curl -LJO -A "${userAgent}" -w "%{filename_effective}" --retry 10 "${dlURL}" )"; then
  echo "curl: failed to download! Retrying next time"
  cleanup
  exit 99
fi
  echo "dlName from value passed: $dlName"
  if [[ -z "${dlName}" ]]; then
    echo "error download filename undefined."
    exit 1
  fi
  downloadPath="${dlDir}/${dlName}"

  echo $downloadPath > /private/tmp/"downloadappPath"
  if [[ ! -e "${downloadPath}" ]]; then
    echo "error download filename undefined. can not locate download."
    exit 1
  fi

  # export full path to the downloaded file including extension.
  export downloadPath
}
# uninstall(){
#  # description of what function does.
#  local description='Uninstalls the defined application.'
#
#  # define local variables.
#  local applicationPath="${1}"
#
#  # data validation.
#  if [[ ! -d "${applicationPath}" ]] && error 'app path undefined or not a directory.'
#
#  # attempt uninstall.
#  /bin/mv "${applicationPath}" "${applicationPath}.old" &> /dev/null || error "failed to uninstall application."
#  sleep 2
#}
install(){
   # description of what function does.
   local description='Determines what kind of installer the download is. Attempts install accordingly.'
   local downloadPath="${1}"
echo "Download Path inside install = $downloadPath"
   # determine download installer type. (dmg, pkg, zip)
   if [[ "$( printf '%s\n' "${downloadPath}" | /usr/bin/grep -c '.dmg$' )" -eq 1 ]]; then
     install_dmg
   elif [[ "$( printf '%s\n' "${downloadPath}" | /usr/bin/grep -c '.pkg$' )" -eq 1 ]]; then
     install_pkg
#   elif [[ "$( printf '%s\n' "${downloadPath}" | /usr/bin/grep -c '.zip$' )" -eq 1 ]]; then
#     install_zip
   else
     echo "could not detect install type."
     if [[ -d "${dlDir}" ]]; then
       /bin/rm -rf "${dlDir}" &> /dev/null
     fi
     exit 1
   fi
}

install_pkg(){
 # description of what function does.
 local description='Silently install pkg.'

 # define local variables.
 local pkg="${1}"

 if [[ -z "${pkg}" ]]; then
   pkg="${downloadPath}"
 fi

 # use installer command line tool to silently install pkg.
 /usr/sbin/installer -allowUntrusted -pkg "${pkg}" -target / &> /dev/null || error 'failed to install latest version pkg.'
}

install_dmg(){
  # description of what function does.
  local description='Silently install dmg.'

  # define variables.
  mnt=''
  local dmg="${1}"
  local app
  local pkg


  if [[ -z "${dmg}" ]]; then
    dmg="${downloadPath}"
  fi
tempfol=`basename "dmg"`
  # create temporary mount directory for dmg and export path if exists.
  mnt=`mktemp -d "/private/tmp/$appdir/${tempfol}.XXXXXX"`

  if [[ ! -d "${mnt}" ]]; then
  echo "error failed to verify temporary mount point for dmg exists."
  exit 1
fi
  export mnt
echo "Mount =$mnt"
  # silently attach the dmg download to the temporary mount directory and determine what it contains (app or pkg)
  sleep 2
  /usr/bin/hdiutil attach "${dmg}" -quiet -nobrowse -mountpoint ${mnt} &> /dev/null || error 'failed to mount dmg.'
  app="$( /bin/ls "${mnt}" | /usr/bin/grep '.app$' | head -n 1 )"
  pkg="$( /bin/ls "${mnt}" | /usr/bin/grep '.pkg$' | head -n 1 )"
echo "App extention = $app"
echo "Pkg extention = $pkg"

  # attempt install based on contents of dmg.
  if [[ ! -z "${app}" && -e "${mnt}/${app}" ]]; then


#######working for apps
rm -Rf "/Applications/${appName}.app"
ditto "/${mnt}/${appName}.app" "/Applications/${appName}.app"
#########

  elif [[ ! -z "${pkg}" && -e "${mnt}/${pkg}" ]]; then
    install_pkg "${mnt}/${pkg}"
  else
    error 'could not detect installation type in mounted dmg.'
    exit 1
  fi
}

cleanup(){
  # description of what function does.
  local description='Removes temporary items created during the download and installation processes.'
echo "Cleanup"
#  local applicationPath="/Applications/${applicationName}.app"
  #local applicationPath="${8}"
echo "Application Path inside cleanup= ${appPath}"
  # if a temporary mount directory has been created, force unmount and remove the directory.
  if [[ -d "${mnt}" ]]; then
    /usr/bin/hdiutil detach -force -quiet "${mnt}"
    /sbin/umount -f "${mnt}" &> /dev/null
    /bin/rm -rf "${mnt}" &> /dev/null
  fi

  # if temporary unzip directory exists, remove it.
  if [[ -d "${uz}" ]]; then
    /bin/rm -rf "${uz}" &> /dev/null
  fi

  # if the defined application does not exist restore the original to the apps directory.
  if [[ ! -d "${appPath}" ]]; then
    printf '%s\n' 'Update failed. Restoring original application...'
    /bin/mv "${appPath}.old" "${appPath}" &> /dev/null
  elif [[ -d "${appPath}.old" ]]; then
    /bin/rm -rf "${appPath}.old" &> /dev/null
  fi

  # if a temporary download directory has been created. remove it.
  if [[ -d "${dlDir}" ]]; then
    /bin/rm -rf "${dlDir}" &> /dev/null
  fi

  if [ -e /private/tmp/"downloadappPath" ]; then
    /bin/rm -rf "/private/tmp/"downloadappPath"" &> /dev/null
  fi

  if [ -e "/Library/Application Support/JAMF/${appName}" ]; then
    /bin/rm -rf "/Library/Application Support/JAMF/${appName}" &> /dev/null
  fi



}

processinstallupdate(){
  # download latest version of the application and export full path to the temporary download location for the cleanup function.

if [ -e /private/tmp/"downloadappPath" ]; then
downloadpath=$(cat /private/tmp/"downloadappPath")
echo "Path is : $downloadpath"
fi
     # install latest version of the application.
      install "${downloadpath}"

      #cleanup
      cleanup

}
deferraltimecalcfunc(){
# Look if app is open via process name
appOpen="$(pgrep -ix "$appID" | wc -l)"

#check if counter file exists. If it does, increment the count and store it
if [ -f "$counterpathplist" ] && [ -f "$lastDeferralTimeplist" ]; then
    echo "Counter file found."
#Read from the counter plist file
    count=`defaults read "$counterpathplist" DeferralCount`
    echo "Current/Old count is $count"
    echo "A deferral file/time stamp is present."
#Read the last deferral from the lastDeferralTimeplist file
    lastDeferralTimeStamp=`defaults read "$lastDeferralTimeplist" DeferralTimeStamp`
    echo "Deferral Time Stamp is $lastDeferralTimeStamp"

else
    echo "Counter file does not exist. Creating one now."
#Set the deferral count in the plist to 0 and set the counter also to 0
    defaults write "$counterpathplist" DeferralCount -int 0
    count=0
    echo "Count is $count"
    echo "A deferral file/time stamp does not exist. Creating one now."
    defaults write "$lastDeferralTimeplist" DeferralTimeStamp -int 0
    lastDeferralTimeStamp=0
fi

## This can be replaced with a script parameter to make it more flexible
    hoursToDefer="4"
# Read the previous DeferralTimeStamp from the stored value, the first time it will be 0 and subsequent times it will be obtained from previous calculations
    echo "Last Deferral is $lastDeferralTimeStamp"
    lastDeferralTimeStamp=`defaults read "$lastDeferralTimeplist" DeferralTimeStamp`
#    echo "Old Time Stamp is $lastDeferralTimeStamp"
#Calculate the hours to defer in seconds or epoch time
    hoursToDeferSecs=$((60*60*hoursToDefer))
#Obtain the current time in epoch
    currentTime=$(date +"%s")
#Get the timeSinceDeferral, first instance it will be the time since epoch and subsequently it will be the time between the runs
    timeSinceDeferral="$((currentTime-lastDeferralTimeStamp))"

#  Check if on the previous run the deferral time stamp is not equal to zero then we will calculate the time for "Troubleshooting purposes"
if [[ "$lastDeferralTimeStamp" -ne "0" ]]; then
#Calculating the number of hours,minutes and seconds to be used only for troubleshooting
   numberofhours=$(( timeSinceDeferral/3600 ))
   remainder=$(( timeSinceDeferral%3600 ))
   numberofminutes=$(( remainder/60 ))
   numberofseconds=$((timeSinceDeferral%60))
   echo "Max Hour Limit in epoch seconds $hoursToDeferSecs
         Current Time in epoch seconds $currentTime
         Last Deferred Time in epoch seconds $lastDeferralTimeStamp
         The difference in HRS: $numberofhours in MINS $numberofminutes and SECS $numberofseconds"
 fi
}

downloadcheck(){
dlDir="/private/tmp/${appID}"
if [[ -d "${dlDir}" ]]; then
  echo "Download installer file found"
  echo "Download Folder: $dlDir"
if [ -e /private/tmp/"downloadappPath" ]; then
  downloadpath=$(cat /private/tmp/"downloadappPath")
  echo "Download Path is : $downloadpath"
else
  echo "Downloader path is invalid: Redownloading"
  /bin/rm -rf "${dlDir}" &> /dev/null
  /bin/rm -rf "/private/tmp/"downloadappPath"" &> /dev/null
  download "${url}"
fi
  #going to check the time stamp
  deferraltimecalcfunc
else
  echo "Download installer file not found; downloading"
  download "${url}"
  if [[ -d "${dlDir}" ]];
    then
      # found the file do something
        echo "Download installer file found"
        echo "Download Folder: $dlDir"
        #going to check the time stamp
        if [ -e /private/tmp/"downloadappPath" ]; then
          downloadpath=$(cat /private/tmp/"downloadappPath")
          echo "Download Path is : $downloadpath"
        else
          echo "Downloader path is invalid: Redownloading"
          /bin/rm -rf "${dlDir}" &> /dev/null
          /bin/rm -rf "/private/tmp/"downloadappPath"" &> /dev/null
          download "${url}"
        fi
        deferraltimecalcfunc
        else
      # didn't find the file, do something
        echo "Download installer file not found"
        exit 1
  fi

fi
}

deferralinitiation(){
  echo "Inside deferral initiation"
#Total Allowed deferrals
totdefer=2
#Check if the app is open and the count is less than the total deferrals and the timeSinceDeferral greater than the hours to defer
if [[ $appOpen -gt 0 ]]; then
  echo "App is open"
  if ([ "$count" -le "$totdefer" ] && [ "$timeSinceDeferral" -ge "$hoursToDeferSecs" ]); then
#if ([ $appOpen -gt 0 ] && [ "$count" -le "$totdefer" ] && [ "$timeSinceDeferral" -ge "$hoursToDeferSecs" ]); then

      defaults write "$lastDeferralTimeplist" DeferralTimeStamp -int $timeSinceDeferral
#      fGetCurrenUser
        if [[ "$count" -eq "totdefer" ]] ; then
            echo "Time since last deferral is equal or greater than ${hoursToDefer} hours"
            echo "Deferral count is at or above max deferrals allowed...."
            fGetCurrenUser
            # determine if the application needs to be updated.
            installedVersion="$( get_installed_version "${appPath}" )" || exit 1
            echo "Installed Version: $installedVersion"
            echo "upgrade"
# $4 - Process Name            finaldialog="$(/bin/launchctl asuser "$currentUserUID" "$jamfHelper" -windowType hud -lockHUD -title "$4" -heading "" -description "$saveQuitMSG" -button1 "Quit & Update" -button2 "No Deferrals Left " -alignDescription center -alignHeading center -icon "$icon" -iconSize "10x10" -windowPosition lr -timeout 3600)"
            finaldialog="$(/bin/launchctl asuser "$currentUserUID" "$jamfHelper" -windowType hud -lockHUD -title "${appName}" -heading "" -description "$saveQuitMSG" -button1 "Quit & Update" -button2 "No Deferrals Left " -alignDescription center -alignHeading center -icon "$icon" -iconSize "20x20" -windowPosition lr -timeout 3600)"
            if [ "$finaldialog" -eq 0 ] || [ "$finaldialog" -eq 2 ]; then
              fQuitApp
#            /usr/local/bin/jamf policy -event "$7"
              # install the package
#              /usr/sbin/installer -pkg "$9" -target /
              processinstallupdate
            fi
# $4 - Process Name            reopenAnswer="$(/bin/launchctl asuser "$currentUserUID" "$jamfHelper" -windowType hud -lockHUD -title "$4" -heading "" -description "$updatedMSG" -button1 Ok -button2 Reopen -alignDescription center -alignHeading center -icon "$icon" -iconSize "10x10" -windowPosition lr -timeout 3600)"
            reopenAnswer="$(/bin/launchctl asuser "$currentUserUID" "$jamfHelper" -windowType hud -lockHUD -title "${appName}" -heading "" -description "$updatedMSG" -button1 Ok -button2 Reopen -alignDescription center -alignHeading center -icon "$icon" -iconSize "20x20" -windowPosition lr -timeout 3600)"
                if [[ $reopenAnswer -eq "2" ]]; then
                  echo "Reopening app"
                  fOpenApp
                fi
#            echo "$lastDeferralTimeplist"
# reset/removes counter of the lastDeferralTime, resets the counter and removes the counterpathplist and the log file
#            rm "$lastDeferralTimeplist"
#Done in cleanup            /bin/rm -rf "/Library/Application Support/JAMF/${appName}" &> /dev/null
#            rm "$counterpathplist"
#            /bin/rm -rf "${counterpathplist}" &> /dev/null
            # remove the installer package when done
#            /bin/rm -f "$9"
#            rm "$logFile"
            count=0
#            fCheckAppUpdated
            latestVersion="$( get_installed_version "${appPath}" )" || exit 1
            echo "Latest Version: $latestVersion"
            exit 0
        else
            fGetCurrenUser
            echo "Deferral count is below max threshold. Kicking off a deferral dialog..."
            userdefercount="$(($totdefer-$count))"
            prompt="$(/bin/launchctl asuser "$currentUserUID" "$jamfHelper" -windowType hud -lockHUD -title "$appName" -heading "" -description "$saveQuitMSG" -button1 "Defer ($userdefercount)" -button2 "Quit & Update ($qd)" -alignDescription center -alignHeading center -icon "$icon" -iconSize "20x20" -windowPosition lr -timeout 3600)"
        fi
      echo "Prompt value= $prompt"

        if [[ "$prompt" -eq "totdefer" ]]; then
            #upgrade
            echo "User chose not to defer"
            fGetCurrenUser
            # determine if the application needs to be updated.
            installedVersion="$( get_installed_version "${appPath}" )" || exit 1
            echo "Installed Version: $installedVersion"
            echo "upgrade"
# The following will run if all the deferrals are exhausted and prompt the user to Quit and update or click on No deferrals left which quits and updates
            fQuitApp
            processinstallupdate
##            /usr/sbin/installer -pkg "$9" -target /
#            /usr/local/bin/jamf policy -event "$7"
            reopenAnswer="$(/bin/launchctl asuser "$currentUserUID" "$jamfHelper" -windowType hud -lockHUD -title "${appName}" -heading "" -description "$updatedMSG" -button1 "Ok" -button2 "Reopen" -alignDescription center -alignHeading center -icon "$icon" -iconSize "20x20" -windowPosition lr -timeout 3600)"
               if [[ $reopenAnswer -eq "2" ]]; then
                 echo "Reopening app"
                 fOpenApp
               fi
#             echo "$lastDeferralTimeplist"
# reset/removes counter of the lastDeferralTime, resets the counter and removes the counterpathplist and the log file
#            rm "$lastDeferralTimeplist"
#Done in cleanup            /bin/rm -rf "/Library/Application Support/JAMF/${appName}" &> /dev/null
#            rm "$counterpathplist"
#            /bin/rm -rf "${counterpathplist}" &> /dev/null
            # remove the installer package when done
#            /bin/rm -f "$9"
#            rm "$logFile"
            count=0

            latestVersion="$( get_installed_version "${appPath}" )" || exit 1
            echo "Latest Version: $latestVersion"
#            latestVersion="$( get_latest_version "${latestVersionUrl}" )" || exit 1
#            latestVersion="$( get_latest_version "${10}" )" || exit 1
#            echo "Latest Version: $latestVersion"
#Not working presently            compare_versions "${latestVersion}" "${installedVersion}"
#            fCheckAppUpdated
            exit 0
        else
          echo "User chose to defer"
            count=`defaults read "$counterpathplist" DeferralCount`
# echo "Old count is $oldcount"
            echo "Old count is $count"
            ((count++))
            echo "New count is $count"
            defaults write "$counterpathplist" DeferralCount -int $count
#dontupgrade
            echo "don't upgrade"
#Check if the count is greater than 1 (The first run) and then reset the lastDeferralTime, lastDeferralTimeStamp in the lastDeferralTimeplist. Else just proceed.
               if [[ "$count" -gt "1" ]]; then
                  lastDeferralTimeStamp=0
                  defaults write "$lastDeferralTimeplist" DeferralTimeStamp -int 0
                  currentTime=$(date +"%s")
                  timeSinceDeferral="$((currentTime-lastDeferralTimeStamp))"
                  defaults write "$lastDeferralTimeplist" DeferralTimeStamp -int $timeSinceDeferral
               fi
         fi
  fi
else
#if app is closed
      # install the package
#      /usr/sbin/installer -pkg "$9" -target /
#      /usr/local/bin/jamf policy -event "$7"
#      echo tee -a "$lastDeferralTimeplist"
echo "App is closed"
installedVersion="$( get_installed_version "${appPath}" )" || exit 1
echo "Installed Version: $installedVersion"
echo "upgrade"
processinstallupdate
latestVersion="$( get_installed_version "${appPath}" )" || exit 1
echo "Latest Version: $latestVersion"
#            rm "$lastDeferralTimeplist"
#Done in cleanup            /bin/rm -rf "/Library/Application Support/JAMF/${appName}" &> /dev/null
#            rm "$counterpathplist"
#            /bin/rm -rf "${counterpathplist}" &> /dev/null
      # remove the installer package when done
#      /bin/rm -f "$9"
#      rm "$logFile"
      count=0
#      fCheckAppUpdated
      exit 0
fi
}

main()
{
  downloadcheck
  deferralinitiation
}

main
