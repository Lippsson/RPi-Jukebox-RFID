#!/usr/bin/env bash

# Test to verify that the installation script works as expected.
# This script needs to be adapted, if new packages, etc are added to the install script

# The absolute path to the folder which contains this script
INSTALLATION_EXITCODE="${1:-0}"

PATHDATA="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
USER_NAME="$(whoami)"
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)

JUKEBOX_HOME_DIR="${HOME_DIR}/RPi-Jukebox-RFID"

tests=0
failed_tests=0

# Tool functions

check_chmod_chown() {
    local mod_expected=$1
    local user_expected=$2
    local group_expected=$3
    local dir=$4
    local files=$5

    for file in ${files};
    do
        mod_actual=$(stat --format '%a' "${dir}/${file}")
        user_actual=$(stat -c '%U' "${dir}/${file}")
        group_actual=$(stat -c '%G' "${dir}/${file}")
        test ! "${mod_expected}" -eq "${mod_actual}" && echo "  ERROR: ${file} actual mod (${mod_actual}) differs from expected (${mod_expected})!"
        test ! "${user_expected}" == "${user_actual}" && echo "  ERROR: ${file} actual owner (${user_actual}) differs from expected (${user_expected})!"
        test ! "${group_expected}" == "${group_actual}" && echo "  ERROR: ${file} actual group (${group_actual}) differs from expected (${group_expected})!"
    done
}

check_file_contains_string() {
    local string="$1"
    local file="$2"

    # sudo is required for checking /etc/mopidy/mopidy.conf
    if [[ ! $(sudo grep -iw "${string}" "${file}") ]]; then
        echo "  ERROR: '${string}' not found in ${file}"
        ((failed_tests++))
    fi
    ((tests++))
}

check_service_state() {
    local service="$1"
    local desired_state="$2"

    local actual_state=$(systemctl show -p ActiveState --value "${service}")
    if [[ ! "${actual_state}" == "${desired_state}" ]]; then
        echo "  ERROR: service ${service} is not ${desired_state} (state: ${actual_state})."
        ((failed_tests++))
    fi
    ((tests++))
}

check_service_enablement() {
    local service="$1"
    local desired_enablement="$2"

    local actual_enablement=$(systemctl is-enabled "${service}")
    if [[ ! "${actual_enablement}" == "${desired_enablement}" ]]; then
        echo "  ERROR: service ${service} is not ${desired_enablement} (state: ${actual_enablement})."
        ((failed_tests++))
    fi
    ((tests++))
}

check_variable() {
  local variable=${1}
  # check if variable exist and if it's empty
  test -z "${!variable+x}" && echo "ERROR: \$${variable} is missing!" && fail=true && return
  test "${!variable}" == "" && echo "ERROR: \$${variable} is empty!" && fail=true
}

# Verify functions
verify_installation_exitcode() {
    if [ "${INSTALLATION_EXITCODE}" -eq 0 ]; then
        echo "Installation successfull."
        echo "Performing further checks..."
    elif [ "${INSTALLATION_EXITCODE}" -eq 2 ]; then
        echo "ABORT: Installation aborted due to prerequisite."
        echo "Further checks skipped."
        exit 0
    else
        echo "ERROR: Installation exited with errorcode '${INSTALLATION_EXITCODE}'"
        exit 1
    fi
}

verify_conf_file() {
    local install_conf="${HOME_DIR}/PhonieboxInstall.conf"
    printf "\nTESTING PhonieboxInstall.conf file...\n\n"
    # check that PhonieboxInstall.conf exists and is not empty

    # check if config file exists
    if [[ -f "${install_conf}" ]]; then
        # Source config file
        source "${install_conf}"
        cat "${install_conf}"
        echo ""
    else
        echo "ERROR: ${install_conf} does not exist!"
        exit 1
    fi

    fail=false
    if [[ -z "${WIFIconfig+x}" ]]; then
        echo "  ERROR: \$WIFIconfig is missing or not set!" && fail=true
    else
        echo "\$WIFIconfig is set to '$WIFIconfig'"
        if [[ "$WIFIconfig" == "YES" ]]; then
            check_variable "WIFIcountryCode"
            check_variable "WIFIssid"
            check_variable "WIFIpass"
            check_variable "WIFIip"
            check_variable "WIFIipRouter"
        fi
    fi
    check_variable "EXISTINGuse"
    check_variable "AUDIOiFace"

    if [[ -z "${SPOTinstall+x}" ]]; then
        echo "  ERROR: \$SPOTinstall is missing or not set!" && fail=true
    else
        echo "\$SPOTinstall is set to '$SPOTinstall'"
        if [ "$SPOTinstall" == "YES" ]; then
            check_variable "SPOTIuser"
            check_variable "SPOTIpass"
            check_variable "SPOTIclientid"
            check_variable "SPOTIclientsecret"
        fi
    fi
    check_variable "MPDconfig"
    check_variable "DIRaudioFolders"
    check_variable "GPIOconfig"

    # Feature optional. if config not present, defaults to NO
    if [[ -n "${AUTOHOTSPOTconfig}" ]]; then
        echo "\$AUTOHOTSPOTconfig is set to '$AUTOHOTSPOTconfig'"
        if [[ "$AUTOHOTSPOTconfig" == "YES" ]]; then
            check_variable "AUTOHOTSPOTssid"
            check_variable "AUTOHOTSPOTcountryCode"
            check_variable "AUTOHOTSPOTpass"
            check_variable "AUTOHOTSPOTip"
        fi
    fi

    if [ "${fail}" == "true" ]; then
      exit 1
    fi

    echo ""
}

verify_wifi_settings() {
    local dhcpcd_conf="/etc/dhcpcd.conf"
    local wpa_supplicant_conf="/etc/wpa_supplicant/wpa_supplicant.conf"
    printf "\nTESTING WiFi settings...\n"

    # check conf files
    check_file_contains_string "static ip_address=${WIFIip}/24" "${dhcpcd_conf}"
    check_file_contains_string "static routers=${WIFIipRouter}" "${dhcpcd_conf}"
    check_file_contains_string "static domain_name_servers=8.8.8.8 ${WIFIipRouter}" "${dhcpcd_conf}"

    check_file_contains_string "country=${WIFIcountryCode}" "${wpa_supplicant_conf}"
    check_file_contains_string "ssid=\"${WIFIssid}\"" "${wpa_supplicant_conf}"
    check_file_contains_string "psk=\"${WIFIpass}\"" "${wpa_supplicant_conf}"

    # check owner and permissions
    check_chmod_chown 664 root netdev "/etc" "dhcpcd.conf"
    check_chmod_chown 664 root netdev "/etc/wpa_supplicant" "wpa_supplicant.conf"

    # check that dhcpcd service is enabled and started
    check_service_state dhcpcd active
    check_service_enablement dhcpcd enabled
}

verify_autohotspot_settings() {
    if [[ "$AUTOHOTSPOTconfig" == "YES" ]]; then
        printf "\nTESTING autohotspot settings...\n\n"

        local autohotspot_service="autohotspot.service"
        local autohotspot_script="/usr/bin/autohotspot"

        local dnsmasq_conf=/etc/dnsmasq.conf
        local hostapd_conf=/etc/hostapd/hostapd.conf
        local hostapd_deamon=/etc/default/hostapd
        local dhcpcd_conf=/etc/dhcpcd.conf

        check_file_contains_string "${AUTOHOTSPOTip}" "${autohotspot_script}"
        local ip_without_last_segment=$(echo $AUTOHOTSPOTip | cut -d'.' -f1-3)
        check_file_contains_string "dhcp-range=${ip_without_last_segment}.100,${ip_without_last_segment}.200,12h" "${dnsmasq_conf}"
        check_file_contains_string "ssid=${AUTOHOTSPOTssid}" "${hostapd_conf}"
        check_file_contains_string "wpa_passphrase=${AUTOHOTSPOTpass}" "${hostapd_conf}"
        check_file_contains_string "country_code=${AUTOHOTSPOTcountryCode}" "${hostapd_conf}"
        check_file_contains_string "DAEMON_CONF=\"${hostapd_conf}\"" "${hostapd_deamon}"
        check_file_contains_string "nohook wpa_supplicant" "${dhcpcd_conf}"
        check_file_contains_string "ExecStart=${AUTOHOTSPOT_SCRIPT}" "/etc/systemd/system/${autohotspot_service}"

        local crontab_user=$(crontab -l 2>/dev/null)
        if [[ ! $(echo "${crontab_user}" | grep -w "${autohotspot_script}") ]]; then
            echo "  ERROR: crontab for user not installed"
            ((failed_tests++))
        fi
        ((tests++))

        # check owner and permissions
        check_chmod_chown 644 root root "/etc" "dnsmasq.conf hostapd/hostapd.conf default/hostapd"
        check_chmod_chown 664 root netdev "/etc" "dhcpcd.conf"
        check_chmod_chown 644 root root "/etc/systemd/system" "${autohotspot_service}"

        # check that the services are activ
        check_service_enablement "${autohotspot_service}" enabled
        check_service_enablement hostapd disabled
        check_service_enablement dnsmasq disabled
    fi
}

# Reads a textfile and pipes all lines as args to the given command.
# Does filter out comments, egg-prefixes and version suffixes
# Arguments:
#   1    : textfile to read
#   2... : command to receive args (e.g. 'echo', 'apt-get -y install', ...)
call_with_args_from_file() {
    local package_file="$1"
    shift

    sed 's/.*#egg=//g' ${package_file} | sed -E 's/(#|=|>|<).*//g' | xargs "$@"
}

verify_apt_packages() {
    local jukebox_dir="$1"
    local packages=$(call_with_args_from_file "${jukebox_dir}"/packages.txt echo)
    local packages_raspberrypi=$(call_with_args_from_file "${jukebox_dir}"/packages-raspberrypi.txt echo)
    local packages_spotify=$(call_with_args_from_file "${jukebox_dir}"/packages-spotify.txt echo)
    local packages_autohotspot=$(call_with_args_from_file "${jukebox_dir}"/packages-autohotspot.txt echo)

    printf "\nTESTING installed packages...\n\n"

    # also check for spotify packages if it has been installed
    if [[ "${SPOTinstall}" == "YES" ]]; then
        packages="${packages} ${packages_spotify}"
    fi

    if [[ "$AUTOHOTSPOTconfig" == "YES" ]]; then
        packages="${packages} ${packages_autohotspot}"
    fi

    # check for raspberry pi packages only on raspberry pi's but not on test docker containers running on x86_64 machines
    if [[ $(uname -m) =~ ^armv.+$ ]]; then
        packages="${packages} ${packages_raspberrypi}"
    fi

    local apt_list_installed=$(apt -qq list --installed 2>/dev/null)
    for package in ${packages}
    do
        if [[ $(echo "${apt_list_installed}" | grep -i "${package}.*installed") ]]; then
            echo "  ${package} is installed"
        else
            echo "  ERROR: ${package} is not installed"
            ((failed_tests++))
        fi
        ((tests++))
    done
}

verify_pip_packages() {
    local jukebox_dir="$1"
    local modules=$(call_with_args_from_file "${jukebox_dir}"/requirements.txt echo)
    local modules_spotify=$(call_with_args_from_file "${jukebox_dir}"/requirements-spotify.txt echo)
    local modules_pn532=$(call_with_args_from_file "${jukebox_dir}"/components/rfid-reader/PN532/requirements.txt echo)
    local modules_rc522=$(call_with_args_from_file "${jukebox_dir}"/components/rfid-reader/RC522/requirements.txt echo)
    local deviceName="${jukebox_dir}"/scripts/deviceName.txt

    printf "\nTESTING installed pip modules...\n\n"

    # also check for spotify pip modules if it has been installed
    if [[ "${SPOTinstall}" == "YES" ]]; then
        modules="${modules} ${modules_spotify}"
    fi

    if [[ -f "${deviceName}" ]]; then
        # RC522 reader is used
        if grep -Fxq "MFRC522" "${deviceName}"
        then
            modules="${modules} ${modules_rc522}"
        fi

        # PN532 reader is used
        if grep -Fxq "PN532" "${deviceName}"
        then
            modules="${modules} ${modules_pn532}"
        fi
    fi

    local pip_list_installed=$(pip3 list)
    for module in ${modules}
    do
        if [[ $(echo "${pip_list_installed}" | grep -i "${module}") ]]; then
            echo "  ${module} is installed"
        else
            echo "  ERROR: pip module ${module} is not installed"
            ((failed_tests++))
        fi
        ((tests++))
    done
}

verify_samba_config() {
    printf "\nTESTING samba config...\n\n"
    check_chmod_chown 644 root root "/etc/samba" "smb.conf"

    check_file_contains_string "path=${DIRaudioFolders}" "/etc/samba/smb.conf"
}

verify_webserver_config() {
    local phpver="$(ls -1 /etc/php)"
    printf "\nTESTING webserver config...\n\n"
    check_chmod_chown 644 root root "/etc/lighttpd" "lighttpd.conf"
    check_chmod_chown 644 root root "/etc/lighttpd/conf-available" "15-fastcgi-php.conf"
    check_chmod_chown 644 root root "/etc/php/${phpver}/cgi" "php.ini"
    check_chmod_chown 440 root root "/etc" "sudoers"

    # Bonus TODO: check that fastcgi and fastcgi-php mods are enabled
}

verify_systemd_services() {
    printf "\nTESTING systemd services...\n\n"
    # check that services exist
    check_chmod_chown 644 root root "/etc/systemd/system" "phoniebox-rfid-reader.service phoniebox-startup-scripts.service phoniebox-gpio-control.service phoniebox-idle-watchdog.service"

    # check that phoniebox services are enabled
    check_service_enablement phoniebox-idle-watchdog enabled
    check_service_enablement phoniebox-rfid-reader enabled
    check_service_enablement phoniebox-startup-scripts enabled
    check_service_enablement phoniebox-gpio-control enabled
}

verify_spotify_config() {
    local etc_mopidy_conf="/etc/mopidy/mopidy.conf"
    local mopidy_conf="${HOME_DIR}/.config/mopidy/mopidy.conf"

    printf "\nTESTING spotify config...\n\n"

    check_file_contains_string "username = ${SPOTIuser}" "${etc_mopidy_conf}"
    check_file_contains_string "password = ${SPOTIpass}" "${etc_mopidy_conf}"
    check_file_contains_string "client_id = ${SPOTIclientid}" "${etc_mopidy_conf}"
    check_file_contains_string "client_secret = ${SPOTIclientsecret}" "${etc_mopidy_conf}"
    check_file_contains_string "media_dir = ${DIRaudioFolders}" "${etc_mopidy_conf}"

    check_file_contains_string "username = ${SPOTIuser}" "${mopidy_conf}"
    check_file_contains_string "password = ${SPOTIpass}" "${mopidy_conf}"
    check_file_contains_string "client_id = ${SPOTIclientid}" "${mopidy_conf}"
    check_file_contains_string "client_secret = ${SPOTIclientsecret}" "${mopidy_conf}"
    check_file_contains_string "media_dir = ${DIRaudioFolders}" "${mopidy_conf}"

    # check that mopidy service is enabled
    check_service_enablement mopidy enabled
    # check that mpd service is disabled
    check_service_enablement mpd disabled
}

verify_mpd_config() {
    local mpd_conf="/etc/mpd.conf"

    printf "\nTESTING mpd config...\n\n"

    check_file_contains_string "^[[:blank:]]\+mixer_control[[:blank:]]\+\"${AUDIOiFace}\"" "${mpd_conf}"
    check_file_contains_string "^music_directory[[:blank:]]\+\"${DIRaudioFolders}\"" "${mpd_conf}"

    check_chmod_chown 640 mpd audio "/etc" "mpd.conf"

    # check that mpd service is enabled, when Spotify support is not installed
    if [[ "${SPOTinstall}" == "NO" ]]; then
        check_service_enablement mpd enabled
    fi
}

verify_folder_access() {
    local jukebox_dir="$1"
    printf "\nTESTING folder access...\n\n"

    # check owner and permissions
    check_chmod_chown 775 "$USER_NAME" www-data "${jukebox_dir}" "playlists shared htdocs settings"
    # ${DIRaudioFolders} => "testing" "audiofolders"
    check_chmod_chown 775 "$USER_NAME" www-data "${DIRaudioFolders}/.." "audiofolders"

    #find .sh and .py scripts that are NOT executable
    local count=$(find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) ! -executable | wc -l)
    if [[ "${count}" -gt 0 ]]; then
        echo "  ERROR: found ${count} '*.sh' and/or '*.py' files that are NOT executable:"
        find . -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) ! -executable
        ((failed_tests++))
    fi
    ((tests++))
}

main() {
    printf "\nTesting installation:\n"
    verify_installation_exitcode
    verify_conf_file
    if [[ "$WIFIconfig" == "YES" ]]; then
        verify_wifi_settings
    fi
    verify_apt_packages "${JUKEBOX_HOME_DIR}"
    verify_pip_packages "${JUKEBOX_HOME_DIR}"
    verify_samba_config
    verify_webserver_config
    verify_systemd_services
    if [[ "${SPOTinstall}" == "YES" ]]; then
        verify_spotify_config
    fi
    verify_mpd_config
    verify_autohotspot_settings
    verify_folder_access "${JUKEBOX_HOME_DIR}"
}

start=$(date +%s)
main
end=$(date +%s)

runtime=$((end-start))
((h=${runtime}/3600))
((m=($runtime%3600)/60))
((s=$runtime%60))

if [[ "${failed_tests}" -gt 0 ]]; then
    echo "${failed_tests} Test(s) failed (of ${tests} tests) (in ${h}h ${m}m ${s}s)."
    exit 1
else
    echo "${tests} tests done in ${h}h ${m}m ${s}s."
fi

