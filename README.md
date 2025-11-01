# How to use
Simply run：
```bash
sudo ./setup --domain|-d yourdomain.com
```

# Read log
```bash
sudo tail -f path_to_session-fileserver-setup/session-fileserver-setup/session-file-server/sfs.log
```

# Restart the service
```bash
touch /etc/uwsgi-emperor/vassals/sfs.ini
```