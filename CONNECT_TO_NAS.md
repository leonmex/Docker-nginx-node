sudo mkdir -p /mnt/diskc
sudo mount -t cifs //192.168.178.34/diskc/blablaragsandrigs /mnt/junglenas \
  -o credentials=/etc/nas-credentials,uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0

sudo mount -t cifs //192.168.178.34/diskc/blablaragsandrigs /mnt/junglenas \
  -o guest,uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0  


  sudo mkdir -p /mnt/junglenas

sudo mount -t cifs //192.168.178.34/diskc/blablaragsandrigs /mnt/junglenas \
  -o credentials=/etc/nas-credentials,uid=$(id -u),gid=$(id -g),iocharset=utf8,vers=3.0