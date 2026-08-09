## First step
echo "=== sshd service status ===" && systemctl status ssh 2>&1 || systemctl status sshd 2>&1
echo "=== is sshd installed ===" && which sshd 2>&1; dpkg -l | grep -i openssh-server 2>&1
echo "=== listening ports ===" && sudo ss -tlnp 2>&1 | grep -E ':22|ssh' || ss -tlnp 2>&1 | grep -E ':22|ssh'

echo "=== apt package check ===" 
dpkg -l 2>/dev/null | grep -i openssh
echo "=== ufw status (if present) ==="
sudo ufw status 2>&1 || echo "ufw not available/no sudo"

echo "=== openssh-server installed? ===" 
dpkg -l | grep -i openssh-server
echo "=== ssh service status ==="
systemctl status ssh --no-pager 2>&1
echo "=== ssh service enabled? ==="
systemctl is-enabled ssh 2>&1
echo "=== listening on 22? ==="
ss -tlnp 2>&1 | grep -E ':22'

echo "Run these yourself in a terminal (needs your sudo password):"
echo "  sudo apt update"
echo "  sudo apt install -y openssh-server"
echo "  sudo systemctl enable --now ssh"
echo "  sudo systemctl status ssh --no-pager"
