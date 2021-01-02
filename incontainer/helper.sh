#!/usr/bin/env bash

export NGINX_CONF=/etc/nginx/http-over-all

# parameter expansion (NFS_1_SHARE -> 10.10.0.201:/home)
function var_exp {
    local VAR="${1}"
    local DEFAULT_VALUE="${2}"
    local EXPANDED="${!VAR}"
    if [[ -z "${EXPANDED}" ]]; then 
        if [[ -z "${DEFAULT_VALUE}" ]]; then
            echo "nil"
        else
            echo "${DEFAULT_VALUE}"
        fi
    else
        echo "${EXPANDED}"
    fi
}

function initialize {
    echo "initialize"

    if [[ -d "/local-data" ]]; then
        echo "chown www-data:www-data /local-data"
        chown "www-data:www-data" "/local-data"
    fi

    if [[ -e "/var/run/force-update.lock" ]]; then
        echo "rm -f /var/run/force-update.lock"
        rm -f /var/run/force-update.lock
    fi

    echo "create ${NGINX_CONF}"
    rm -rf ${NGINX_CONF}
    mkdir -p ${NGINX_CONF}
    
    echo "cp /scripts/nginx-config/nginx-default /etc/nginx/sites-enabled/default"
    cp "/scripts/nginx-config/nginx-default" "/etc/nginx/sites-enabled/default"

    echo "cp /scripts/nginx-config/mime.types /etc/nginx/mime.types"
    cp "/scripts/nginx-config/mime.types" "/etc/nginx/mime.types"

    echo "cp /scripts/nginx-config/php/php.ini ${PHP7_ETC}/fpm/php.ini"
    cp "/scripts/nginx-config/php/php.ini" "${PHP7_ETC}/fpm/php.ini"

    echo "cp /scripts/nginx-config/nginx.conf /etc/nginx/nginx.conf"
    cp "/scripts/nginx-config/nginx.conf" "/etc/nginx/nginx.conf"

    configure_nginx_proxy "/etc/nginx/nginx.conf"

    # docker digests (put all docker-digests from processed images into this dir)
    mkdir -p /tmp/docker-digests/
}

function configure_nginx_proxy {
    # http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cache_path
    local NGINX_CONF_FILE=$1
    local MAX_SIZE="${PROXY_MAX_SIZE:-10g}"
    local INACTIVE="${PROXY_INACTIVE:-1d}"

    echo -e "\nconfigure_nginx_proxy"
    echo "sed -i \"s|__MAX_SIZE__|${MAX_SIZE}|g\" ${NGINX_CONF_FILE}"
    sed -i "s|__MAX_SIZE__|${MAX_SIZE}|g" "${NGINX_CONF_FILE}"

    echo "sed -i \"s|__INACTIVE__|${INACTIVE}|g\" ${NGINX_CONF_FILE}"
    sed -i "s|__INACTIVE__|${INACTIVE}|g" "${NGINX_CONF_FILE}"
}

function clean_up {
    echo "clean up -> reinitialize ${HTDOCS}"
    rm -rf "${HTDOCS:?}/"*

    echo "clean up -> reinitialize ${WEBDAV}/web"
    rm -rf "${WEBDAV}/web"
    mkdir -p "${WEBDAV}/web"
    chown "www-data:www-data" "${WEBDAV}/web"
}

# define permitted resources and only link available resources 
function link_permitted_resource {
    local START_PATH="${1}"
    local DST_PATH="${2}"
    # remove leading and trailign whitespaces and tabs
    local PERMITTED_RESOURCE=$(echo ${3} | awk '{$1=$1}1')

    local SRC="${START_PATH%/}/${PERMITTED_RESOURCE}"
    local DST="${DST_PATH%/}/${PERMITTED_RESOURCE}"

    # echo "link_permitted_resource: SRC=${SRC} DST=${DST}"

    if [[ -e "${SRC}" ]]; then
        if [[ ! -e "${DST}" ]]; then
            DST_DIRNAME="$(dirname "${DST}")"
            if [[ ! -d "${DST_DIRNAME}" ]]; then
                mkdir -p "${DST_DIRNAME}"
            fi

            ln -s "${SRC}" "${DST}"
        else 
            echo "${DST} already exists -> ignore"
        fi
    else 
        echo "does not exists -> ignore (${SRC})"
    fi
}

function periodic_job_update_permitted_resources {
    local PERMITTED_RESOURCES_DIR="/tmp/permitted_resources/"
    local RESOURCES_FILE="resources.txt"

    local DIRS=""
    if [ -e "${PERMITTED_RESOURCES_DIR}" ] ;then
        local DIRS="$(find "${PERMITTED_RESOURCES_DIR}" -name "${RESOURCES_FILE}" -exec dirname {} \;)"
    fi

    for DIR in ${DIRS}; do
        echo -e "\nperiodic_job_update_permitted_resources: check sha1sum ${DIR}/${RESOURCES_FILE}"
        if ! sha1sum -c "${DIR}/${RESOURCES_FILE}"; then
            echo "periodic_job_update_permitted_resources: update ${DIR}/${RESOURCES_FILE}"
            local PERMISSION_FILE="$(awk '{print$2}' < "${DIR}/${RESOURCES_FILE}")"
            if [ ! -e "${PERMISSION_FILE}" ]; then
                echo "ERROR: permission_file does not exists -> ${PERMISSION_FILE} ; ignore it for the moment"
            else 
                local START_PATH="$(< "${DIR}/START_PATH")"
                local DST_PATH="$(< "${DIR}/DST_PATH")"
                local ENV_NAME="$(basename "$DIR")"
                process_permitted_resources "update" "${ENV_NAME}" "${PERMISSION_FILE}" "${START_PATH}" "${DST_PATH}"
            fi
        fi
    done
}

function validate_and_process_permitted_resources {
    local ENV_NAME="${1}"
    local RESOURCE_SRC="${2}"
    local DST="${3}"

    local PERMISSION_FILE="$(var_exp "${ENV_NAME}")"
    if [[ ! -e "${PERMISSION_FILE}" ]]; then
        PERMISSION_FILE="${RESOURCE_SRC%/}/${PERMISSION_FILE}"
        echo "validation: try to retrieve resource from resource source: ${PERMISSION_FILE}"
    fi
    if [[ ! -e "${PERMISSION_FILE}" ]]; then
        echo "validation: permitted resource not found -> ignore resource"
    else
        process_permitted_resources "create" "${ENV_NAME}" "${PERMISSION_FILE}" "${RESOURCE_SRC}" "${DST}"
    fi
}

function process_permitted_resources {
    # CREATE | UPDATE
    local TYPE="${1}"
    # e.g. GIT_1_REPO_PERMITTED_RESOURCES
    local ENV_NAME="${2}"
    local PERMISSION_FILE="${3}"
    local START_PATH="${4}"
    local DST_PATH="${5}"

    local PERMITTED_RESOURCES_DIR="/tmp/permitted_resources/"
    local RESOURCES_FILE="resources.txt"

    echo "process_permitted_resources (${TYPE}}: ${PERMISSION_FILE}"

    if [[ "$TYPE" = "create" ]]; then
        mkdir -p "${PERMITTED_RESOURCES_DIR}/${ENV_NAME}"
        sha1sum "${PERMISSION_FILE}" > "${PERMITTED_RESOURCES_DIR}/${ENV_NAME}/${RESOURCES_FILE}"
        echo "${START_PATH}" > "${PERMITTED_RESOURCES_DIR}/${ENV_NAME}/START_PATH"
        echo "${DST_PATH}" > "${PERMITTED_RESOURCES_DIR}/${ENV_NAME}/DST_PATH"

    elif [[ "$TYPE" = "update" ]]; then
        sha1sum "${PERMISSION_FILE}" > "${PERMITTED_RESOURCES_DIR}/${ENV_NAME}/${RESOURCES_FILE}"

        echo "rm -rf ${DST_PATH}"
        rm -rf "${DST_PATH}"
    fi

    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ "$line" != "" ]]; then
            local normalizedResource="$(echo "${line}" | tr -d '\r' | tr -d '\n')"
            link_permitted_resource "${START_PATH}" "${DST_PATH}" "$normalizedResource"
        fi
    done < "$PERMISSION_FILE"
}


function handle_basic_auth {
    # PROXY_${COUNT}_HTTP_AUTH or ${BASE_VAR}_${TYPE}_AUTH
    local AUTH="$(var_exp "${1}")"
    # proxy_${PROXY_NAME} or ${TYPE_LC}_${RESOURCE_NAME}
    local HTPASSWD_FILE_EXT="${2}"
    # /tmp/new_proxy_${PROXY_NAME}
    local TEMP_FILE="${3}"
    
    if [[ "${AUTH}" != "nil" ]]; then
        local AUTH_USER="$(cut -d ':' -f 1 <<< "${AUTH}")"
        local AUTH_PASS="$(cut -d ':' -f 2- <<< "${AUTH}")"
        echo "handle_basic_auth: ${AUTH_USER} / obfuscated"
        echo "/usr/bin/htpasswd -bc /etc/nginx/htpasswd_${HTPASSWD_FILE_EXT} ${AUTH_USER} obfuscated"
        /usr/bin/htpasswd -bc "/etc/nginx/htpasswd_${HTPASSWD_FILE_EXT}" "${AUTH_USER}" "${AUTH_PASS}"
        SED_HTPASSWD="s|#auth_basic|auth_basic|;"            

        echo sed -i "${SED_HTPASSWD}" "${TEMP_FILE}"
        sed -i "${SED_HTPASSWD}" "${TEMP_FILE}"
    fi    
}

# create symlink for the resources. In case of the existing of xxx_SUB_DIR sub-dir handling is done, too
# for smb (mount_smb_shares) and git (connect_or_update_git_repos)
function create_symlinks_for_resources {
    # SMB_MOUNT
    local RESOURCE_SRC="${1}"
    # SMB_${COUNT}_NAME
    local RESOURCE_NAME="${2}"
    # GIT_${COUNT}
    # SMB_${COUNT}
    local BASE="${3}"
    # DAV_ACTIVE
    local DAV_ACTIVE="${4}"
    # HTTP_ACTIVE
    local HTTP_ACTIVE="${5}"

    local MAIN_PATH="${HTDOCS%/}"

    if [[ "${HTTP_ACTIVE}" == "false" ]]; then
        echo "HTTP: not active"
        MAIN_PATH="/tmp/http-over-all/no-http"
        rm -rf "${MAIN_PATH}"
        mkdir -p "${MAIN_PATH}"
    fi

    # clear the webserver directory
    echo rm -rf "${MAIN_PATH}/${RESOURCE_NAME}"
    rm -rf "${MAIN_PATH:?}/${RESOURCE_NAME:?}"

    local COUNT_SUB_DIR='1'
    # no restrictions to sub directories / share the whole thing
    local SUB_DIR="${BASE}_SUB_DIR"

    # permitted files
    if [[ "$(var_exp "${BASE}_PERMITTED_RESOURCES")" != "nil" ]]; then
        local DESTINATION="${MAIN_PATH}/${RESOURCE_NAME}"
        validate_and_process_permitted_resources "${BASE}_PERMITTED_RESOURCES" "${RESOURCE_SRC}" "${DESTINATION}"
    elif [[ "$(var_exp "${SUB_DIR}_PATH_${COUNT_SUB_DIR}")" == "nil" ]]; then
        echo "SUB-DIR-MODE: not active"
        echo "ln -fs ${RESOURCE_SRC} ${MAIN_PATH}/${RESOURCE_NAME}"
        ln -fs "${RESOURCE_SRC}" "${MAIN_PATH}/${RESOURCE_NAME}"
    else
        echo mkdir -p "${MAIN_PATH}/${RESOURCE_NAME}"
        mkdir -p "${MAIN_PATH}/${RESOURCE_NAME}"
        while [[ "$(var_exp "${SUB_DIR}_PATH_${COUNT_SUB_DIR}")" != "nil" ]]; do
            echo "SUB-DIR-MODE: active"
            # SMB_1_SHARE_SUB_DIR_PATH_1=downloads
            local SUB_DIR_PATH="$(var_exp "${SUB_DIR}_PATH_${COUNT_SUB_DIR}")"
            # to support the whole resource as well (=/)
            SUB_DIR_PATH="${SUB_DIR_PATH%/}"
            # SMB_1_SHARE_SUB_DIR_NAME_1=d
            local SUB_DIR_NAME="$(var_exp "${SUB_DIR}_NAME_${COUNT_SUB_DIR}")"
            if [[ -d "${RESOURCE_SRC}/${SUB_DIR_PATH}" ]]; then
                local DESTINATION="${MAIN_PATH}/${RESOURCE_NAME}/${SUB_DIR_NAME}"
                if [[ "$(var_exp "${SUB_DIR}_PERMITTED_RESOURCES_${COUNT_SUB_DIR}")" != "nil" ]]; then
                    echo "${SUB_DIR_NAME}: check permitted resources"
                    validate_and_process_permitted_resources "${SUB_DIR}_PERMITTED_RESOURCES_${COUNT_SUB_DIR}" "${RESOURCE_SRC}" "${DESTINATION}"
                else         
                    echo "${SUB_DIR_NAME}: enabled -> ${SUB_DIR_PATH}/"
                    local LNK_SRC="${RESOURCE_SRC}/${SUB_DIR_PATH}"
                    echo ln -fs "${LNK_SRC}" "${DESTINATION}"
                    ln -fs "${LNK_SRC}" "${DESTINATION}"
                fi
            else
                echo "${SUB_DIR_NAME}: ignore b/c ${RESOURCE_SRC}/${SUB_DIR_PATH} not existing"
            fi
            (( COUNT_SUB_DIR++ ))
        done
    fi

    if [[ "$DAV_ACTIVE" == "true" ]]; then
        echo "DAV: active"
        if [[ -e "${WEBDAV}/web/${RESOURCE_NAME}" ]]; then
            echo "rm -rf ${WEBDAV}/web/${RESOURCE_NAME}"
            rm -rf "${WEBDAV}/web/${RESOURCE_NAME}"
        fi
        echo "ln -fs ${MAIN_PATH}/${RESOURCE_NAME} ${WEBDAV}/web/${RESOURCE_NAME}"
        ln -fs "${MAIN_PATH}/${RESOURCE_NAME}" "${WEBDAV}/web/${RESOURCE_NAME}"
    fi
}

function create_nginx_location {
    # resource base -> LOCAL_1 OR SMB_2
    local BASE_VAR="${1}"
    # HTTP or DAV
    local TYPE="${2}"
    local TYPE_LC="${2,,}"
    local CACHE_ACTIVE=${3:-"true"}

    local RESOURCE_NAME="$(var_exp "${BASE_VAR}_NAME")"
    local TEMPLATE_TYPE=${TYPE_LC}
    if [[ "${CACHE_ACTIVE}" = "false" ]]; then TEMPLATE_TYPE="${TYPE_LC}-no-cache" ; fi
    echo "location $TYPE_LC: $RESOURCE_NAME | CACHE: ${CACHE_ACTIVE}"

    local TEMPLATE="nginx-config/location-${TEMPLATE_TYPE}.template"
    local TEMP_FILE="${NGINX_CONF}/location_${TYPE_LC}_${RESOURCE_NAME}.conf"

    local IP_RESTRICTION=$(var_exp "${BASE_VAR}_${TYPE}_IP_RESTRICTION" "allow all")
    local SED_PATTERN="s|__RESOURCE_NAME__|${RESOURCE_NAME%/}|; s|#IP_RESTRICTION|${IP_RESTRICTION%;};|;"
    if [[ "${TYPE_LC}" = "dav" ]]; then
        SED_PATTERN="${SED_PATTERN} s|__WEBDAV__|${WEBDAV}|;"
        local DAV_METHODS="$(var_exp "${BASE_VAR}_DAV_METHODS")"
        if [[ "${DAV_METHODS}" == "nil" ]]; then
            echo "none of the standard dav_methods (PUT DELETE MKCOL COPY MOVE) active"
        else
            DAV_METHODS_PATTERN="dav_methods ${DAV_METHODS^^};"
            echo "${DAV_METHODS_PATTERN}"
            SED_PATTERN="${SED_PATTERN} s|#DAV_METHODS|${DAV_METHODS_PATTERN}|;"
        fi
    fi
    sed "${SED_PATTERN}" "${TEMPLATE}" > "${TEMP_FILE}"

    handle_basic_auth "${BASE_VAR}_${TYPE}_AUTH" "${TYPE_LC}_${RESOURCE_NAME}" "${TEMP_FILE}"

    # remove comments
    sed -i "/#/d" "${TEMP_FILE}"
    # sed -i "/#NEXT_LOCATION/r $TEMP_FILE" "/etc/nginx/sites-enabled/default"
    #rm "${TEMP_FILE}"
}

function initial_create_symlinks_for_resources {
    local RESOURCE_NAME="$1"
    # NFS_${COUNT}
    local BASE="$2"
    # ${NFS_MOUNT}
    local MOUNT="$3"
    local HTTP_ACTIVE="$4"
    local DAV_ACTIVE="$5"
    local CACHE_ACTIVE=${6:-"true"}

    if [[ "${HTTP_ACTIVE}" == "true" ]]; then create_nginx_location "${BASE}" "HTTP" "${CACHE_ACTIVE}" ; fi
    if [[ "${DAV_ACTIVE}" == "true" ]]; then create_nginx_location "${BASE}" "DAV" ; fi

    create_symlinks_for_resources "${MOUNT}" "${RESOURCE_NAME}" "${BASE}" "${DAV_ACTIVE}" "${HTTP_ACTIVE}"    
}

function clone_git_repo {
    local GIT_REPO_PATH="${1}"
    local REPO_URL="${2}"
    local RESOURCE_NAME="${3}"

    echo mkdir -p "${GIT_REPO_PATH}"
    mkdir -p "${GIT_REPO_PATH}"

    echo git -C "${GIT_REPO_PATH}" clone "${REPO_URL}"
    git -C "${GIT_REPO_PATH}" clone "${REPO_URL}"

    echo "$(date +'%T'): git cloned: ${RESOURCE_NAME}"
}

function clone_git_repo_safe {
    local GIT_REPO_PATH="${1}"
    local REPO_URL="${2}"
    local RESOURCE_NAME="${3}"

    local PATH_SAFE="${GIT_REPO_PATH}_safe" 
    rm -rf "${PATH_SAFE}" 
    mkdir -p "${PATH_SAFE}"

    echo git -C "${PATH_SAFE}" clone "${REPO_URL}"
    if git -C "${PATH_SAFE}" clone "${REPO_URL}" ; then
        echo "clone succeeded"
        rm -f "${GIT_REPO_PATH}.error"
        rm -rf "${GIT_REPO_PATH}"
        echo "mv ${PATH_SAFE} ${GIT_REPO_PATH}"
        mv "${PATH_SAFE}" "${GIT_REPO_PATH}"        
    else
        echo "clone failed"
        rm -rf "${PATH_SAFE}"
    fi

    echo "$(date +'%T'): git safe cloned: ${RESOURCE_NAME}"
}

function periodic_jobs {
    local WAIT_IN_MINUTES="$(var_exp "PERIODIC_JOB_INTERVAL" "5")"
    local LOCK_FILE="/var/run/force-update.lock"
    echo "$(date +'%T'): periodic_jobs -> interval ${WAIT_IN_MINUTES} minute(s)"
    while true; do
        sleep "${WAIT_IN_MINUTES}m"
        echo "$(date +'%T'): periodic_jobs start"
        handle_update_jobs_lock "${LOCK_FILE}" "no-trap"
        connect_or_update_git_repos "update"
        connect_or_update_docker "update"
        periodic_job_update_permitted_resources
        echo "$(date +'%T'): periodic_jobs terminated"
        rm -f "${LOCK_FILE}"
        echo
    done
}

function handle_update_jobs_lock {
    local LOCK_FILE="${1}"
    local TRAP="${2}"
    while [[ -e "${LOCK_FILE}" ]]; do
        echo "$(date +'%T'): ${LOCK_FILE} exists -> another force-update process is running"
        echo "----------------------------------"
        cat "${LOCK_FILE}"
        sleep 2
    done

    echo  "force-update started: $(date)" > "${LOCK_FILE}"
    echo "----------------------------------" >> "${LOCK_FILE}"
    if [[ ${TRAP} == "handle-trap" ]]; then
        trap "echo \"remove ${LOCK_FILE}\" ; rm -f ${LOCK_FILE}" EXIT TERM QUIT
    fi
}


function parse_url() {
    PROJECT_URL=$1
    # Extract the protocol (includes trailing "://").
    PARSED_PROTO="$(echo $PROJECT_URL | sed -nr 's,^(.*://).*,\1,p')"
    P_PROTO="$(echo $PROJECT_URL | sed -nr 's,^(.*)://.*,\1,p')"

    # Remove the protocol from the URL.
    local PARSED_URL="$(echo ${PROJECT_URL/$PARSED_PROTO/})"

    # Extract the user (includes trailing "@").
    local PARSED_USER="$(echo $PARSED_URL | sed -nr 's,^(.*@).*,\1,p')"
    P_USER="$(echo $PARSED_URL | sed -nr 's,^(.*)@.*,\1,p')"

    # Remove the user from the URL.
    local PARSED_URL="$(echo ${PARSED_URL/$PARSED_USER/})"

    # Extract the port (includes leading ":").
    PARSED_PORT="$(echo $PARSED_URL | sed -nr 's,.*(:[0-9]+).*,\1,p')"
    P_PORT="$(echo $PARSED_URL | sed -nr 's,.*:([0-9]+).*,\1,p')"

    # Remove the port from the URL.
    local PARSED_URL="$(echo ${PARSED_URL/$PARSED_PORT/})"

    # Extract the path (includes leading "/" or ":").
    PARSED_PATH="$(echo $PARSED_URL | sed -nr 's,[^/:]*([/:].*),\1,p')"
    P_PATH="$(echo $PARSED_URL | sed -nr 's,[^/:]*[/:](.*),\1,p')"

    # Remove the path from the URL.
    PARSED_HOST="$(echo ${PARSED_URL/$PARSED_PATH/})"  
}

# SIGTERM-handler
# https://blog.codeship.com/trapping-signals-in-docker-containers/
function term_handler() {
    echo "$(date +'%T'): stop http server / EXIT signal detected"
    service nginx stop
    exit 143; # 128 + 15 -- SIGTERM
}