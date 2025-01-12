#!/bin/bash

#### config ####

CONFIG_PATH=/data/options.json

DEPLOYMENT_KEY=$(jq --raw-output ".deployment_key[]" $CONFIG_PATH)
DEPLOYMENT_KEY_PROTOCOL=$(jq --raw-output ".deployment_key_protocol" $CONFIG_PATH)
DEPLOYMENT_USER=$(jq --raw-output ".deployment_user" $CONFIG_PATH)
DEPLOYMENT_PASSWORD=$(jq --raw-output ".deployment_password" $CONFIG_PATH)
GIT_BRANCH=$(jq --raw-output '.git_branch' $CONFIG_PATH)
GIT_COMMAND=$(jq --raw-output '.git_command' $CONFIG_PATH)
GIT_REMOTE=$(jq --raw-output '.git_remote' $CONFIG_PATH)
GIT_PRUNE=$(jq --raw-output '.git_prune' $CONFIG_PATH)
REPOSITORY=$(jq --raw-output '.repository' $CONFIG_PATH)
AUTO_RESTART=$(jq --raw-output '.auto_restart' $CONFIG_PATH)
RESTART_IGNORED_FILES=$(jq --raw-output '.restart_ignore | join(" ")' $CONFIG_PATH)
REPEAT_ACTIVE=$(jq --raw-output '.repeat.active' $CONFIG_PATH)
REPEAT_INTERVAL=$(jq --raw-output '.repeat.interval' $CONFIG_PATH)
################

#### functions ####
function log {
    local level="$2"
    local message="$2"
    echo "[$level][$(date '+%Y-%m-%d %H:%M:%S')] $message"
}

function log_i {
    log "Info" "$1"
}

function log_e {
    log "Error" "$1"
}

function log_w {
    log "Warn" "$1"
}

function add-ssh-key {
    log_i "Start adding SSH key"
    mkdir -p ~/.ssh

    (
        echo "Host *"
        echo "    StrictHostKeyChecking no"
    ) > ~/.ssh/config

    log_i "Setup deployment_key on id_${DEPLOYMENT_KEY_PROTOCOL}"
    rm -f "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    while read -r line; do
        echo "$line" >> "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    done <<< "$DEPLOYMENT_KEY"

    chmod 600 "${HOME}/.ssh/config"
    chmod 600 "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
}

function git-clone {
    # create backup
    BACKUP_LOCATION="/tmp/config-$(date +%Y-%m-%d_%H-%M-%S)"
    log_i "Backup configuration to $BACKUP_LOCATION"

    mkdir "${BACKUP_LOCATION}" || { echo "[Error] Creation of backup directory failed"; exit 1; }
    cp -rf /config/* "${BACKUP_LOCATION}" || { echo "[Error] Copy files to backup directory failed"; exit 1; }

    # remove config folder content
    rm -rf /config/{,.[!.],..?}* || { echo "[Error] Clearing /config failed"; exit 1; }

    # git clone
    log_i "Start git clone"
    git clone "$REPOSITORY" /config || { echo "[Error] Git clone failed"; exit 1; }

    # try to copy non yml files back
    cp "${BACKUP_LOCATION}" "!(*.yaml)" /config 2>/dev/null

    # try to copy secrets file back
    cp "${BACKUP_LOCATION}/secrets.yaml" /config 2>/dev/null
}

function check-ssh-key {
if [ -n "$DEPLOYMENT_KEY" ]; then
    log_i "Check SSH connection"
    IFS=':' read -ra GIT_URL_PARTS <<< "$REPOSITORY"
    # shellcheck disable=SC2029
    DOMAIN="${GIT_URL_PARTS[0]}"
    if OUTPUT_CHECK=$(ssh -T -o "StrictHostKeyChecking=no" -o "BatchMode=yes" "$DOMAIN" 2>&1) || { [[ $DOMAIN = *"@github.com"* ]] && [[ $OUTPUT_CHECK = *"You've successfully authenticated"* ]]; }; then
        log_i "Valid SSH connection for $DOMAIN"
    else
        log_w "No valid SSH connection for $DOMAIN"
        add-ssh-key
    fi
fi
}

function setup-user-password {
if [ -n "$DEPLOYMENT_USER" ]; then
    cd /config || return
    log_i "setting up credential.helper for user: ${DEPLOYMENT_USER}"
    git config --system credential.helper 'store --file=/tmp/git-credentials'

    # Extract the hostname from repository
    h="$REPOSITORY"

    # Extract the protocol
    proto=${h%%://*}

    # Strip the protocol
    h="${h#*://}"

    # Strip username and password from URL
    h="${h#*:*@}"
    h="${h#*@}"

    # Strip the tail of the URL
    h=${h%%/*}

    # Format the input for git credential commands
    cred_data="\
protocol=${proto}
host=${h}
username=${DEPLOYMENT_USER}
password=${DEPLOYMENT_PASSWORD}
"

    # Use git commands to write the credentials to ~/.git-credentials
    log_i "Saving git credentials to /tmp/git-credentials"
    # shellcheck disable=SC2259
    git credential fill | git credential approve <<< "$cred_data"
fi
}

function git-synchronize {
    # is /config a local git repo?
    if git rev-parse --is-inside-work-tree &>/dev/null
    then
        log_i "Local git repository exists"

        # Is the local repo set to the correct origin?
        CURRENTGITREMOTEURL=$(git remote get-url --all "$GIT_REMOTE" | head -n 1)
        if [ "$CURRENTGITREMOTEURL" = "$REPOSITORY" ]
        then
            log_i "Git origin is correctly set to $REPOSITORY"
            OLD_COMMIT=$(git rev-parse HEAD)

            # Always do a fetch to update repos
            log_i "Start git fetch..."
            git fetch "$GIT_REMOTE" || { echo "[Error] Git fetch failed"; return 1; }

            # Prune if configured
            if [ "$GIT_PRUNE" == "true" ]
            then
              log_i "Start git prune..."
              git prune || { echo "[Error] Git prune failed"; return 1; }
            fi

            # Do we switch branches?
            GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
            if [ -z "$GIT_BRANCH" ] || [ "$GIT_BRANCH" == "$GIT_CURRENT_BRANCH" ]; then
              log_i "Staying on currently checked out branch: $GIT_CURRENT_BRANCH..."
            else
              log_i "Switching branches - start git checkout of branch $GIT_BRANCH..."
              git checkout "$GIT_BRANCH" || { echo "[Error] Git checkout failed"; exit 1; }
              GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
            fi

            # Pull or reset depending on user preference
            case "$GIT_COMMAND" in
                pull)
                    log_i "Start git pull..."
                    git pull || { log_e "Git pull failed"; return 1; }
                    ;;
                reset)
                    log_i "Start git reset..."
                    git reset --hard "$GIT_REMOTE"/"$GIT_CURRENT_BRANCH" || { log_e "Git reset failed"; return 1; }
                    ;;
                *)
                    log_e "Git command is not set correctly. Should be either 'reset' or 'pull'"
                    exit 1
                    ;;
            esac
        else
            echo "[Error] git origin does not match $REPOSITORY!"; exit 1;
        fi

    else
        log_w "Git repository doesn't exist"
        git-clone
    fi
}

function validate-config {
    log_i "Checking if something has changed..."
    # Compare commit ids & check config
    NEW_COMMIT=$(git rev-parse HEAD)
    if [ "$NEW_COMMIT" != "$OLD_COMMIT" ]; then
        log_i "Something has changed, checking Home-Assistant config..."
        if ha --no-progress core check; then
            if [ "$AUTO_RESTART" == "true" ]; then
                DO_RESTART="false"
                CHANGED_FILES=$(git diff "$OLD_COMMIT" "$NEW_COMMIT" --name-only)
                log_i "Changed Files: $CHANGED_FILES"
                if [ -n "$RESTART_IGNORED_FILES" ]; then
                    for changed_file in $CHANGED_FILES; do
                        restart_required_file=""
                        for restart_ignored_file in $RESTART_IGNORED_FILES; do
                            if [ -d "$restart_ignored_file" ]; then
                                # file to be ignored is a whole dir
                                restart_required_file=$(echo "${changed_file}" | grep "^${restart_ignored_file}")
                            else
                                restart_required_file=$(echo "${changed_file}" | grep "^${restart_ignored_file}$")
                            fi
                            # break on first match
                            if [ -n "$restart_required_file" ]; then break; fi
                        done
                        if [ -z "$restart_required_file" ]; then
                            DO_RESTART="true"
                            log_i "Detected restart-required file: $changed_file"
                        fi
                    done
                else
                    DO_RESTART="true"
                fi
                if [ "$DO_RESTART" == "true" ]; then
                    log_i "Restart Home-Assistant"
                    ha --no-progress core restart 2&> /dev/null
                else
                    log_i "No Restart Required, only ignored changes detected"
                fi
            else
                log_i "Local configuration has changed. Restart required."
            fi
        else
            log_e "Configuration updated but it does not pass the config check. Do not restart until this is fixed!"
        fi
    else
        log_i "Nothing has changed."
    fi
}

###################

#### Main program ####
cd /config || { log_e "Failed to cd into /config"; exit 1; }

while true; do
    check-ssh-key
    setup-user-password
    if git-synchronize ; then
        validate-config
    fi
     # do we repeat?
    if [ ! "$REPEAT_ACTIVE" == "true" ]; then
        exit 0
    fi
    sleep "$REPEAT_INTERVAL"
done

###################
