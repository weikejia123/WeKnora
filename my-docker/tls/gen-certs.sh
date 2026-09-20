#!/usr/bin/env bash
# 生成 WeKnora TLS 终端所需的自签证书（CA + 服务器证书）。
#
# 在**目标机**上运行（证书 SAN 要写目标机的访问地址）。
#
# 用法：
#   bash gen-certs.sh                       # 生成到默认目录，IP 自动探测
#   bash gen-certs.sh /mnt/data/weknora-tls 10.168.1.111
#   FORCE=1 bash gen-certs.sh               # 已存在时强制重建
#
# 证书**不进 git**（默认落在 /mnt/data/weknora-tls，私钥权限 600）。
set -euo pipefail

DIR=${1:-/mnt/data/weknora-tls}
IP=${2:-}

if [ -z "$IP" ]; then
  IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}' | head -1)
  [ -n "$IP" ] || IP=10.168.1.111
fi

DAYS_CA=3650
DAYS_SRV=3650

mkdir -p "$DIR"
chmod 700 "$DIR"

if [ -f "$DIR/server.crt" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "证书已存在，跳过生成（重建请用 FORCE=1）：$DIR"
  echo "--- 现有服务器证书 SAN ---"
  openssl x509 -in "$DIR/server.crt" -noout -ext subjectAltName | tail -n +2
  echo "--- 有效期 ---"
  openssl x509 -in "$DIR/server.crt" -noout -dates
  exit 0
fi

# ★ SAN 必须含 IP：现代浏览器做证书主机名匹配时**只看 SAN、忽略 CN**。
#   只写 CN=10.168.1.111 而不写 SAN，Chrome 会判定主机名不匹配。
cat > "$DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no

[dn]
CN = WeKnora ${IP}
O  = WeKnora Self-Signed

[v3_ca]
basicConstraints     = critical, CA:TRUE
keyUsage             = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash

[v3_srv]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature, keyEncipherment
extendedKeyUsage     = serverAuth
subjectKeyIdentifier = hash
subjectAltName       = @san

[san]
IP.1  = ${IP}
IP.2  = 127.0.0.1
DNS.1 = localhost
EOF

echo "=== 生成 CA（有效期 ${DAYS_CA} 天）==="
openssl genrsa -out "$DIR/ca.key" 4096 2>/dev/null
openssl req -new -x509 -key "$DIR/ca.key" -sha256 -days "$DAYS_CA" \
  -subj "/CN=WeKnora Local CA/O=WeKnora Self-Signed" \
  -config "$DIR/openssl.cnf" -extensions v3_ca \
  -out "$DIR/ca.crt"

echo "=== 生成服务器证书 ==="
echo "    SAN: IP:${IP}, IP:127.0.0.1, DNS:localhost"
openssl genrsa -out "$DIR/server.key" 2048 2>/dev/null
openssl req -new -key "$DIR/server.key" -config "$DIR/openssl.cnf" -out "$DIR/server.csr"
openssl x509 -req -in "$DIR/server.csr" \
  -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -days "$DAYS_SRV" -sha256 \
  -extfile "$DIR/openssl.cnf" -extensions v3_srv \
  -out "$DIR/server.crt"
rm -f "$DIR/server.csr"

chmod 600 "$DIR"/*.key
chmod 644 "$DIR/ca.crt" "$DIR/server.crt"

echo ""
echo "=== 校验 ==="
openssl verify -CAfile "$DIR/ca.crt" "$DIR/server.crt"
echo "--- 服务器证书 SAN ---"
openssl x509 -in "$DIR/server.crt" -noout -ext subjectAltName | tail -n +2
echo "--- 有效期 ---"
openssl x509 -in "$DIR/server.crt" -noout -dates
echo ""
echo "=== CA 指纹（导入访问端后请核对一致）==="
openssl x509 -in "$DIR/ca.crt" -noout -fingerprint -sha256 | sed 's/^/  /'
echo ""
echo "完成。下一步："
echo "  1) docker compose -f my-docker/tls/docker-compose.yml up -d"
echo "  2) 把 $DIR/ca.crt 导入访问端（Mac）并设为「始终信任」"
