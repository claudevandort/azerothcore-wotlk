#!/bin/bash
set -euo pipefail
exec > /var/log/wow-setup.log 2>&1

echo "=== Emerald Dream Server Setup ==="

# Install Docker
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

# Ensure SSM Agent is running
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent || true

# Clone repo
echo "=== Cloning repository ==="
git clone --depth 1 --branch Playerbot https://github.com/claudevandort/azerothcore-wotlk.git /opt/wow-server

# Clone modules
git clone --depth 1 https://github.com/claudevandort/mod-playerbots.git /opt/wow-server/modules/mod-playerbots
git clone --depth 1 https://github.com/claudevandort/mod-mount-scaling.git /opt/wow-server/modules/mod-mount-scaling

# Fix permissions: user data runs as root, but containers run as uid 1000
mkdir -p /opt/wow-server/env/dist/etc /opt/wow-server/env/dist/logs
chown -R 1000:1000 /opt/wow-server/env/dist/etc /opt/wow-server/env/dist/logs

# Generate random MySQL password
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

# Create .env file
cat > /opt/wow-server/.env <<EOF
DOCKER_DB_ROOT_PASSWORD=${DB_PASSWORD}
EOF
chmod 600 /opt/wow-server/.env

# Create docker-compose.override.yml to mount playerbots module
cat > /opt/wow-server/docker-compose.override.yml <<'OVERRIDE'
services:
  ac-worldserver:
    volumes:
      - ./modules/mod-playerbots:/azerothcore/modules/mod-playerbots
      - ./modules/mod-mount-scaling:/azerothcore/modules/mod-mount-scaling
  ac-db-import:
    volumes:
      - ./modules/mod-playerbots:/azerothcore/modules/mod-playerbots
      - ./modules/mod-mount-scaling:/azerothcore/modules/mod-mount-scaling
OVERRIDE

# Start services
echo "=== Starting Docker Compose ==="
cd /opt/wow-server
docker compose up -d --build

# Background task: wait for healthy containers, then update realmlist
(
  echo "=== Waiting for containers to be healthy ==="
  # Wait up to 45 minutes for worldserver to be running
  for i in $(seq 1 270); do
    if docker inspect ac-worldserver --format='{{.State.Status}}' 2>/dev/null | grep -q running; then
      echo "Worldserver container is running"
      break
    fi
    echo "Waiting for worldserver... attempt $i/270"
    sleep 10
  done

  # Wait for database to be healthy
  for i in $(seq 1 60); do
    if docker inspect ac-database --format='{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
      echo "Database is healthy"
      break
    fi
    echo "Waiting for database... attempt $i/60"
    sleep 5
  done

  # Give worldserver time to finish DB migrations
  sleep 30

  # Get IPs from EC2 metadata (IMDSv2)
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
  PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

  echo "Public IP: $PUBLIC_IP"
  echo "Private IP: $PRIVATE_IP"

  # Update realmlist
  docker exec ac-database mysql -uroot -p"${DB_PASSWORD}" acore_auth -e "
    UPDATE realmlist SET
      name = 'Emerald Dream',
      address = '${PUBLIC_IP}',
      localAddress = '${PRIVATE_IP}',
      localSubnetMask = '255.255.0.0',
      port = 8085
    WHERE id = 1;
  "

  echo "=== Realmlist updated successfully ==="
  echo "Address: ${PUBLIC_IP}"
  echo "Local Address: ${PRIVATE_IP}"
) &>> /var/log/wow-setup.log &

echo "=== Setup script complete (realmlist update running in background) ==="
