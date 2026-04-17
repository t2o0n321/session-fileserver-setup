# Session File Server Deployment

This repo provides an automated setup script for deploying the [Session File Server](https://github.com/session-foundation/session-file-server) on Ubuntu.

## Prerequisites

- Fresh Ubuntu server (20.04 LTS or newer)
- A non-root user with `sudo` privileges
- A domain name pointed at your server's IP address

---

## Automated Setup

Run the setup script with your domain:

```bash
sudo ./setup.sh --domain your_domain.com
```

Or with the short flag:

```bash
sudo ./setup.sh -d your_domain.com
```

The script will:
1. Install all required system packages (Python, PostgreSQL, Nginx, uWSGI, Oxen packages)
2. Create the PostgreSQL database and user
3. Load the database schema and seed a default storage pool
4. Clone the `session-file-server` repository
5. Create and configure a Python virtual environment
6. Apply required code patches
7. Configure uWSGI (vassal under uWSGI Emperor)
8. Configure Nginx as a reverse proxy
9. Restart all services

---

## Manual Setup

If you prefer to set things up manually, follow these steps.

### 1. Install Dependencies

```bash
sudo apt update && sudo apt upgrade -y

sudo curl -so /etc/apt/trusted.gpg.d/oxen.gpg https://deb.oxen.io/pub.gpg
echo "deb https://deb.oxen.io $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/oxen.list
sudo apt update && sudo apt upgrade -y

sudo apt install -y python3 python3-pip python3.12-venv \
    postgresql postgresql-client nginx uwsgi-emperor uwsgi-plugin-python3 git \
    python3-{systemd,flask,uwsgidecorators,coloredlogs,session-util}
```

### 2. Database Setup

```bash
sudo su - postgres
createuser youruser          # replace with your Ubuntu username
createdb -O youruser sessionfiles
exit
```

Edit `/etc/postgresql/XX/main/pg_hba.conf` (where `XX` is your PostgreSQL version). Find the line for `local` connections and change `peer` to `trust`:

```
local   all   all   trust
```

Then restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

Clone the repository and load the schema:

```bash
git clone https://github.com/session-foundation/session-file-server.git
cd session-file-server
psql -f schema.pgsql sessionfiles
```

Insert a default storage pool (required — the schema does not seed this):

```bash
psql -d sessionfiles -c "INSERT INTO storage_pools (name, active) VALUES ('default', true);"
```

### 3. Application Setup

```bash
python3 -m venv --system-site-packages venv
source ./venv/bin/activate
pip3 install coloredlogs psycopg psycopg_pool pynacl requests
```

Copy and edit the config:

```bash
cp fileserver/config.py.sample fileserver/config.py
```

Set your database user in `fileserver/config.py`:

```python
pgsql_connect_opts = {
    "dbname": "sessionfiles",
    "user": "youruser",
}
```

Apply a required code fix in `fileserver/subrequest.py`. Find:

```python
"CONTENT_LENGTH": content_length,
```

Change it to:

```python
"CONTENT_LENGTH": str(content_length),
```

### 4. uWSGI Configuration

Create `/etc/uwsgi-emperor/vassals/sfs.ini`:

```ini
[uwsgi]
chdir = /home/youruser/session-file-server

virtualenv = /home/youruser/session-file-server/venv
socket = /home/youruser/session-file-server/sfs.wsgi
chmod-socket = 660
plugins = python3
processes = 4
manage-script-name = true
mount = /=fileserver.web:app

enable-threads = true

logto = /home/youruser/session-file-server/sfs.log
```

```bash
sudo chown youruser:www-data /etc/uwsgi-emperor/vassals/sfs.ini
```

### 5. Nginx Configuration

Create `/etc/nginx/sites-available/session-file-server`:

```nginx
server {
    listen 80;
    server_name your_domain.com;

    client_max_body_size 10M;

    location / {
        include uwsgi_params;
        uwsgi_pass unix:/home/youruser/session-file-server/sfs.wsgi;
    }
}
```

Enable the site and restart services:

```bash
sudo ln -s /etc/nginx/sites-available/session-file-server /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

sudo chmod o+x /home/youruser
sudo chown -R www-data:www-data /home/youruser/session-file-server/
sudo systemctl restart uwsgi-emperor
```

---

## Verification

Test the server is running:

```bash
curl -s 'http://your_domain.com/session_version?platform=desktop' | jq
```

A successful response returns JSON with the latest Session desktop version.

---

## Operations

**Read logs:**

```bash
sudo tail -f /home/youruser/session-file-server/sfs.log
```

**Restart the application** after code changes:

```bash
touch /etc/uwsgi-emperor/vassals/sfs.ini
```
