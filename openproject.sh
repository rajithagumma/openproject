#!/bin/bash
set -euo pipefail

DOMAIN="work.justuju.in"
CERT_EMAIL="devs@justuju.in"

# ------------------ INSTALL DOCKER ------------------
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER

# ------------------ PERSIST SECRET KEY ------------------
if [ ! -f /etc/openproject-secret.env ]; then
    sudo mkdir -p /etc
    echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" | sudo tee /etc/openproject-secret.env
fi
source /etc/openproject-secret.env

# ------------------ PREPARE VOLUMES ------------------
sudo mkdir -p /var/lib/openproject/{pgdata,assets}

# ------------------ INSTALL AND CONFIGURE NGINX ------------------
sudo apt install -y nginx certbot python3-certbot-nginx
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host work.justuju.in;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ------------------ OBTAIN SSL CERTIFICATE ------------------
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $CERT_EMAIL
sudo certbot renew --dry-run --non-interactive

# ------------------ PREPARE POST-REBOOT SCRIPT ------------------
cat > /home/ubuntu/openproject-post-reboot.sh <<EOF
#!/bin/bash
set -euo pipefail
source /etc/openproject-secret.env

# Remove any old container (running or stopped)
docker rm -f openproject >/dev/null 2>&1 || true

# Now start fresh
docker run -d -p 8080:80 --name openproject \
  --restart unless-stopped \
  -e OPENPROJECT_HOST__NAME=work.justuju.in \
  -e OPENPROJECT_SECRET_KEY_BASE=66136c766d434846ab46c0444e3f7428c5ae85de46da1868fc680c881f7d272e75e9f23aae8c271951d32c9c64b59adf7bfcdfa84be910c439f81b73019132bd \
  -e OPENPROJECT_HTTPS=true \
  -v /var/lib/openproject/pgdata:/var/openproject/pgdata \
  -v /var/lib/openproject/assets:/var/openproject/assets \
  openproject/openproject:16


sleep 15
echo "✅ OpenProject container started. Access it at: https://$DOMAIN"


EOF

chmod +x /home/ubuntu/openproject-post-reboot.sh

# ------------------ INFORM USER AND REBOOT ------------------
echo "🟡 Docker group permission will apply after reboot."
echo "➡️  After reboot, run:  /home/ubuntu/openproject-post-reboot.sh"
sudo reboot
