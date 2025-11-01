#!/bin/bash

# --------------------------------------------------
# Constants
# --------------------------------------------------
# Get the directory of this script
declare -r CALLER_SOURCE="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
declare -r SCRIPT_DIR="$(cd "$(dirname "${CALLER_SOURCE}")" && pwd)"
declare -r PROJECT_ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
declare -r SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${CALLER_SOURCE}")"

# User's nme (Not root)
declare -r USER_NAME="${SUDO_USER:-$USER}"

# Log file path
declare -r LOG_FILE="/var/log/session_fileserver_setup.log"

# Session-file-server
declare -r GIT_REPO_URL="https://github.com/session-foundation/session-file-server.git"
declare -r SF_SERVER_DIR="${SCRIPT_DIR}/session-file-server"

# uWGSI ini file path
declare -r UWSGI_INI_FILE="/etc/uwsgi-emperor/vassals/sfs.ini"

# Nginx configuration file path
declare -r NGINX_CONF_FILE="/etc/nginx/sites-available/session-file-server"

# Ensure log file exists with secure permissions
sudo touch "$LOG_FILE" || error_exit "Failed to create $LOG_FILE"
sudo chmod 600 "$LOG_FILE" || error_exit "Failed to set permissions on $LOG_FILE"
sudo chown root:root "$LOG_FILE" || error_exit "Failed to set ownership on $LOG_FILE"

# Dependencies to install
declare -a DEPENDENCIES=(
    ufw
    openssl
    python3
    python3-{pip,systemd,flask,uwsgidecorators,coloredlogs,session-util}
    python3.12-venv
    postgresql
    postgresql-client
    nginx
    uwsgi-{emperor,plugin-python3}
)

# --------------------------------------------------
# Functions
# --------------------------------------------------
# Returns the current timestamp
get_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]"
}

# Logs a message with a given level
log() {
    local level="$1"
    local message="$2"
    echo "$(get_timestamp) [$level] $message" | tee -a "$LOG_FILE"
    logger -t "session_fileserver_setup" "[$level] $message"
}

# Logs an error message and exits
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Checks if the script is run with sudo
check_permission() {
    if [ "$EUID" -ne 0 ]; then
        echo "$(get_timestamp) This script must be run with sudo."
        exit 1
    fi
}

# Installs required dependencies
install_dependencies() {
    log "INFO" "Installing dependencies..."

    log "INFO" "Updating package lists..."
    sudo apt update -y && sudo apt upgrade -y || error_exit "Failed to update and upgrade packages."

    log "INFO" "Now obtaining oxen packages list..."
    sudo curl -so /etc/apt/trusted.gpg.d/oxen.gpg https://deb.oxen.io/pub.gpg || error_exit "Failed to download Oxen GPG key."
    echo "deb https://deb.oxen.io $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/oxen.list || error_exit "Failed to add Oxen repository."
    sudo apt update -y && sudo apt upgrade -y || error_exit "Failed to update and upgrade packages after adding Oxen repository."

    log "INFO" "Installing required packages: ${DEPENDENCIES[*]}"
    sudo apt install "${DEPENDENCIES[@]}" -y || error_exit "Failed to install dependencies."
    log "INFO" "Dependencies installed successfully."
}

# Generates a random string of specified length
get_random_string() {
    local length=$1
    local allow_capitals=${2:-true}
    local result
    if [ "$allow_capitals" = true ]; then
        result=$(LC_CTYPE=C tr -dc '[:upper:][:lower:][:digit:]' </dev/urandom | head -c "$length")
    else
        result=$(LC_CTYPE=C tr -dc '[:lower:][:digit:]' </dev/urandom | head -c "$length")
    fi
    echo "$result"
}

check_domain() {
    local domain="$1"
    log "INFO" "Checking domain resolution for $domain"
    local ip
    ip=$(nslookup "$domain" | grep 'Address:' | tail -n1 | awk '{print $2}' || echo "")
    if [ -z "$ip" ]; then
        error_exit "Failed to resolve domain $domain"
    fi
    local machine_ip
    machine_ip=$(curl -s ipinfo.io/ip || echo "")
    if [ -z "$machine_ip" ]; then
        error_exit "Failed to retrieve machine IP"
    fi
    if [ "$ip" != "$machine_ip" ]; then
        error_exit "The domain $domain resolves to $ip, but machine IP is $machine_ip"
    fi
    log "INFO" "Domain $domain resolves correctly to $machine_ip"
    echo "$machine_ip"
}

# Sets up the PostgreSQL database for session-fileserver
setup_sf_database() {
    log "INFO" "Setting up session-fileserver's PostgreSQL database..."

    # Dynamically find the pg_hba.conf file and update authentication method
    log "INFO" "Locating pg_hba.conf file..."
    local pg_hba_conf
    pg_hba_conf=$(find /etc/postgresql/ -name pg_hba.conf)
    if [ -z "$pg_hba_conf" ]; then
        error_exit "Could not find pg_hba.conf file."
    fi

    log "INFO" "Updating pg_hba.conf for local connections..."
    sudo sed -i 's/\(local\s\+all\s\+all\s\+\)peer/\1trust/' "$pg_hba_conf" || error_exit "Failed to update pg_hba.conf."

    log "INFO" "Restarting PostgreSQL service..."
    sudo systemctl restart postgresql || error_exit "Failed to restart PostgreSQL."

    local db_user="$USER_NAME"

    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_user'" | grep -q 1; then
        error_exit "Database user '$db_user' already exists. Please remove the existing user or choose a different username."
    else
        log "INFO" "Creating database user '$db_user'..."
        sudo -u postgres createuser "$db_user" || error_exit "Failed to create database user '$db_user'."
    fi

    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw sessionfiles; then
        error_exit "Database 'sessionfiles' already exists. Please remove the existing database or choose a different name."
    else
        log "INFO" "Creating database 'sessionfiles' with owner '$db_user'..."
        sudo -u postgres createdb -O "$db_user" sessionfiles || error_exit "Failed to create database 'sessionfiles'."
    fi

    log "INFO" "Cloning session-fileserver's repository..."
    if [ ! -d "session-file-server" ]; then
        git clone "$GIT_REPO_URL" || error_exit "Failed to clone session-file-server repository."
    else
        log "INFO" "session-file-server directory already exists. Skipping clone."
    fi

    if sudo -u postgres psql -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'files'" sessionfiles | grep -q 1; then
        log "INFO" "Schema already loaded."
    else
        log "INFO" "Loading database schema..."
        (cd session-file-server && sudo -u postgres psql -f schema.pgsql sessionfiles) || error_exit "Failed to load database schema."

        log "INFO" "Granting all privileges on database 'sessionfiles' to user '$db_user'..."
        sudo -u postgres psql -d sessionfiles -c "GRANT ALL PRIVILEGES ON DATABASE sessionfiles TO $db_user;" || error_exit "Failed to grant all database privileges."

        log "INFO" "Granting all privileges on all tables in schema public to user '$db_user'..."
        sudo -u postgres psql -d sessionfiles -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO $db_user;" || error_exit "Failed to grant all table privileges."

        log "INFO" "Granting all privileges on all sequences in schema public to user '$db_user'..."
        sudo -u postgres psql -d sessionfiles -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO $db_user;" || error_exit "Failed to grant all sequence privileges."
    fi

    log "INFO" "Database setup complete."
}

# Setup session-fileserver
setup_sf_server() {
    log "INFO" "Setting up session-fileserver..."
    local db_user="$1"
    
    # Create a Python virtual environment
    log "INFO" "Creating Python virtual environment for session-fileserver..."
    python3 -m venv --system-site-packages "$SF_SERVER_DIR/venv" || error_exit "Failed to create virtual environment."

    # Use the virtual environment to install requirements directly using pip3
    log "INFO" "Installing Python dependencies in virtual environment for sesison-fileserver..."
    "$SF_SERVER_DIR/venv/bin/pip3" install coloredlogs psycopg psycopg_pool pynacl requests || error_exit "Failed to install Python dependencies."
    
    # Copy the example configuration file
    log "INFO" "Copying example configuration file for session-fileserver..."
    cp "$SF_SERVER_DIR/fileserver/config.py.sample" "$SF_SERVER_DIR/fileserver/config.py" || error_exit "Failed to copy config.py."

    # Update the configuration file with database credentials
    log "INFO" "Updating configuration file with database credentials..."
    perl -i -pe "s/(\"dbname\": \"sessionfiles\")/\$1,\n    \"user\": \"$db_user\"/" "$SF_SERVER_DIR/fileserver/config.py" \
        || error_exit "Failed to update config.py with database credentials."
    
    # Update the code of session-file-server ($SF_SERVER_DIR/fileserver/subrequest.py)
    # Change "CONTENT_LENGTH": content_length, to "CONTENT_LENGTH": str(content_length),
    log "INFO" "Applying necessary code modifications to session-fileserver..."
    perl -i -pe 's/("CONTENT_LENGTH": )content_length,/$1str(content_length),/' "$SF_SERVER_DIR/fileserver/subrequest.py" \
        || error_exit "Failed to modify subrequest.py."

    # Update the code of session-file-server ($SF_SERVER_DIR/fileserver/routes.py)
    # Change to_verify = ts_str.encode() + request.method.encode() + request.path.encode() to to_verify = str(ts_str).encode() + request.method.encode() + request.path.encode()
    perl -i -pe 's/(to_verify = )ts_str.encode\(\) \+ request.method.encode\(\) \+ request.path.encode\(\)/$1str(ts_str).encode() \+ request.method.encode() \+ request.path.encode()/' "$SF_SERVER_DIR/fileserver/routes.py" \
        || error_exit "Failed to modify routes.py."

    log "INFO" "Session-fileserver setup complete."
}

configure_uwsgi() {
    log "INFO" "Configuring uWSGI for session-fileserver..."

    local ini_content=$(cat << EOF
[uwsgi]
# Path to the project directory
chdir = $SF_SERVER_DIR

# WSGI settings
virtualenv = $SF_SERVER_DIR/venv
socket = $SF_SERVER_DIR/sfs.wsgi
chmod-socket = 660
plugins = python3
processes = 4
manage-script-name = true
mount = /=fileserver.web:app

# Logging
logto = $SF_SERVER_DIR/sfs.log
EOF
)

    echo "$ini_content" | sudo tee "$UWSGI_INI_FILE" > /dev/null \
        || error_exit "Failed to create uWSGI ini file."

    sudo chown $USER_NAME:www-data /etc/uwsgi-emperor/vassals/sfs.ini \
        || error_exit "Failed to set ownership for uWSGI ini file."

    log "INFO" "uWSGI configuration complete."
}

setup_nginx() {
    log "INFO" "Configuring Nginx for session-fileserver..."
    local domain="$1"
    
    local nginx_content=$(cat << EOF
server {
    listen 80;
    server_name $domain;

    client_max_body_size 10M;

    location / {
        include uwsgi_params;
        uwsgi_pass unix:$SF_SERVER_DIR/sfs.wsgi;
    }
}
EOF
)
    echo "$nginx_content" | sudo tee "$NGINX_CONF_FILE" > /dev/null \
        || error_exit "Failed to create Nginx configuration file."

    sudo ln -s /etc/nginx/sites-available/session-file-server /etc/nginx/sites-enabled/ \
        || error_exit "Failed to enable Nginx site."

    log "INFO" "Testing Nginx configuration..."
    sudo nginx -t || error_exit "Nginx configuration test failed."

    log "INFO" "Restarting Nginx service..."
    sudo systemctl restart nginx || error_exit "Failed to restart Nginx."

    log "INFO" "Setting permissions for session-fileserver directory..."
    sudo chmod o+x "$(eval echo ~$USER_NAME)" || error_exit "Failed to set execute permission on session-file-server directory."
    sudo chown -R www-data:www-data $SF_SERVER_DIR || error_exit "Failed to set ownership for session-file-server directory."

    log "INFO" "Restarting uWSGI Emperor service..."
    sudo systemctl restart uwsgi-emperor || error_exit "Failed to restart uWSGI Emperor."

    log "INFO" "Configuring UFW to allow Nginx traffic..."
    sudo ufw allow 'Nginx Full' || error_exit "Failed to allow Nginx through UFW."

    log "INFO" "Nginx configuration complete."
}