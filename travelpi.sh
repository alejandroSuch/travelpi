#!/bin/bash
#===============================================================================
# PiTravel Router v2 - Script de instalación completo
# WiFi Manager + Media Server (nginx) + Battery + Jellyfin Sync
#
# Ejecutar como root: sudo bash install.sh
#===============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           PiTravel Router v2 - Instalador                 ║"
echo "║     WiFi Manager + Media Server + Battery + Sync          ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Verificar root
[[ $EUID -ne 0 ]] && err "Ejecuta como root: sudo bash install.sh"

#===============================================================================
# CONFIGURACIÓN
#===============================================================================
AP_SSID="PiTravel"
AP_PASS="travel1234"
AP_IP="192.168.50.1"
MEDIA_PATH="/media/usb/videos"
INSTALL_DIR="/opt/pitravel"

echo "Configuración del Access Point:"
read -p "  SSID [$AP_SSID]: " input && AP_SSID="${input:-$AP_SSID}"
read -p "  Contraseña [$AP_PASS]: " input && AP_PASS="${input:-$AP_PASS}"
echo ""

read -p "¿Instalar soporte PiSugar (batería)? [s/N]: " INSTALL_PISUGAR
read -p "¿Configurar sincronización Jellyfin? [s/N]: " INSTALL_SYNC

if [[ "$INSTALL_SYNC" == "s" ]]; then
    echo ""
    echo "Configuración Jellyfin (dejar vacío para configurar después):"
    read -p "  API Key: " JELLYFIN_API_KEY
    read -p "  User ID: " JELLYFIN_USER_ID
    JELLYFIN_URL="http://10.0.0.1:8096"
    read -p "  URL Jellyfin [$JELLYFIN_URL]: " input && JELLYFIN_URL="${input:-$JELLYFIN_URL}"
fi

echo ""
echo "Configuración WireGuard (dejar vacío para configurar después):"
read -p "  Public key del servidor: " WG_PEER_PUBKEY
read -p "  Endpoint (ej: tudominio.duckdns.org:51820): " WG_PEER_ENDPOINT

echo ""
echo "Resumen:"
echo "  AP: $AP_SSID / $AP_PASS"
echo "  IP: $AP_IP"
echo "  Media: $MEDIA_PATH"
echo "  PiSugar: ${INSTALL_PISUGAR:-n}"
echo "  Jellyfin Sync: ${INSTALL_SYNC:-n}"
[[ -n "$WG_PEER_PUBKEY" ]] && echo "  WireGuard: $WG_PEER_ENDPOINT"
echo ""
read -p "¿Continuar? [s/N]: " confirm
[[ "$confirm" != "s" ]] && exit 0

#===============================================================================
# 1. SISTEMA BASE
#===============================================================================
log "Actualizando sistema..."
apt update && apt upgrade -y

log "Instalando dependencias..."
apt install -y \
    hostapd dnsmasq wireguard iptables-persistent \
    python3-flask nginx \
    wireless-tools net-tools curl wget i2c-tools

#===============================================================================
# 2. CREAR ESTRUCTURA DE DIRECTORIOS
#===============================================================================
log "Creando directorios..."
mkdir -p $INSTALL_DIR/templates
mkdir -p $MEDIA_PATH/.posters
mkdir -p /var/log/pitravel

#===============================================================================
# 3. DETECTAR INTERFACES WIFI
#===============================================================================
log "Detectando interfaces WiFi..."

# wlan0 = integrado (cliente), wlanX = USB (AP)
USB_WIFI=$(iw dev | grep Interface | awk '{print $2}' | grep -v wlan0 | head -1)
[[ -z "$USB_WIFI" ]] && warn "Adaptador USB no detectado, usando wlan1 por defecto" && USB_WIFI="wlan1"
log "  Cliente: wlan0"
log "  AP: $USB_WIFI"

#===============================================================================
# 4. CONFIGURAR RED
#===============================================================================
log "Configurando red..."

cat > /etc/dhcpcd.conf << EOF
interface $USB_WIFI
    static ip_address=$AP_IP/24
    nohook wpa_supplicant
EOF

#===============================================================================
# 5. HOSTAPD (Access Point)
#===============================================================================
log "Configurando hostapd..."

cat > /etc/hostapd/hostapd.conf << EOF
interface=$USB_WIFI
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
country_code=ES
EOF

sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl unmask hostapd
systemctl enable hostapd

#===============================================================================
# 6. DNSMASQ (DHCP)
#===============================================================================
log "Configurando dnsmasq..."

mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null || true

cat > /etc/dnsmasq.conf << EOF
interface=$USB_WIFI
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
domain=local
address=/pitravel.local/$AP_IP
EOF

systemctl enable dnsmasq

#===============================================================================
# 7. IP FORWARDING Y FIREWALL
#===============================================================================
log "Configurando firewall..."

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-pitravel.conf
sysctl -w net.ipv4.ip_forward=1

iptables -t nat -F
iptables -F FORWARD

# NAT por WireGuard (preferido)
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
iptables -A FORWARD -i $USB_WIFI -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o $USB_WIFI -m state --state RELATED,ESTABLISHED -j ACCEPT

# Fallback: NAT por wlan0
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i $USB_WIFI -o wlan0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o $USB_WIFI -m state --state RELATED,ESTABLISHED -j ACCEPT

netfilter-persistent save

#===============================================================================
# 8. WIREGUARD
#===============================================================================
log "Configurando WireGuard..."

if [ ! -f /etc/wireguard/privatekey ]; then
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    chmod 600 /etc/wireguard/privatekey
fi

PRIV_KEY=$(cat /etc/wireguard/privatekey)
PUB_KEY=$(cat /etc/wireguard/publickey)

if [[ -n "$WG_PEER_PUBKEY" && -n "$WG_PEER_ENDPOINT" ]]; then
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.2/24

[Peer]
PublicKey = $WG_PEER_PUBKEY
Endpoint = $WG_PEER_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
else
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.2/24

# [Peer]
# PublicKey = <clave_publica_servidor>
# Endpoint = tudominio.duckdns.org:51820
# AllowedIPs = 0.0.0.0/0
# PersistentKeepalive = 25
EOF
    warn "Edita /etc/wireguard/wg0.conf con los datos de tu servidor VPN"
fi

chmod 600 /etc/wireguard/wg0.conf

#===============================================================================
# 9. NGINX (Media Server)
#===============================================================================
log "Configurando nginx (media server)..."

cat > /etc/nginx/sites-available/pitravel-media << EOF
server {
    listen 8080;
    server_name _;

    root $MEDIA_PATH;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    
    # Charset para nombres con acentos
    charset utf-8;
    
    # Tipos MIME para vídeo
    types {
        video/mp4 mp4 m4v;
        video/x-matroska mkv;
        video/webm webm;
        video/x-msvideo avi;
    }
    
    location / {
        try_files \$uri \$uri/ =404;
        
        # Headers para streaming
        add_header Accept-Ranges bytes;
        add_header Access-Control-Allow-Origin *;
    }
    
    # Optimización para archivos grandes
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    
    # Buffer para vídeos
    client_max_body_size 0;
    proxy_buffering off;
}
EOF

ln -sf /etc/nginx/sites-available/pitravel-media /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl enable nginx

#===============================================================================
# 10. APLICACIÓN FLASK
#===============================================================================
log "Instalando aplicación web..."

cat > $INSTALL_DIR/app.py << 'PYEOF'
#!/usr/bin/env python3
from flask import Flask, render_template, jsonify, request
import subprocess, os, re, json, shlex

app = Flask(__name__)
MEDIA_PATH = "__MEDIA_PATH__"
AP_IFACE = "__USB_WIFI__"

def run_cmd(cmd):
    try:
        if isinstance(cmd, str):
            cmd = shlex.split(cmd)
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip()
    except:
        return ""

def run_shell(cmd):
    """Only for commands that need shell features (pipes, redirects)."""
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30).stdout.strip()
    except:
        return ""

def get_battery():
    try:
        r = run_shell("echo 'get battery' | nc -q 0 127.0.0.1 8423 2>/dev/null")
        if r:
            m = re.search(r'(\d+\.?\d*)', r)
            if m: return {"percent": int(float(m.group(1))), "charging": "charging" in r.lower()}
    except: pass
    return {"percent": None, "charging": False}

def scan_wifi():
    out = run_shell("sudo iwlist wlan0 scan 2>/dev/null")
    nets, cur = [], {}
    for line in out.split('\n'):
        line = line.strip()
        if 'Address:' in line:
            if cur.get('ssid'): nets.append(cur)
            cur = {}
        elif 'ESSID:' in line:
            cur['ssid'] = line.split('ESSID:')[-1].strip('"')
        elif 'Signal level=' in line:
            m = re.search(r'(-?\d+)', line)
            if m: cur['signal'] = int(m.group(1))
        elif 'WPA2' in line: cur['security'] = 'WPA2'
        elif 'WPA' in line and cur.get('security') != 'WPA2': cur['security'] = 'WPA'
        elif 'WEP' in line and 'security' not in cur: cur['security'] = 'WEP'
    if cur.get('ssid'): nets.append(cur)
    seen = set()
    return [n for n in sorted(nets, key=lambda x: x.get('signal',-100), reverse=True) 
            if n['ssid'] not in seen and not seen.add(n['ssid'])]

def get_ssid(): return run_cmd("iwgetid -r wlan0") or None
def check_portal():
    try: return subprocess.run(["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time","5",
        "http://detectportal.firefox.com/success.txt"], capture_output=True, text=True).stdout != "200"
    except: return True
def check_vpn(): return "interface" in run_shell("sudo wg show wg0 2>/dev/null").lower()
def get_clients():
    return [{'ip': p[0], 'mac': p[2].upper()} for line in run_shell(f"arp -i {AP_IFACE} -n | grep -v Address").split('\n')
            if (p := line.split()) and len(p) >= 3 and ':' in p[2]]

def format_size(b):
    for u in ['B','KB','MB','GB']:
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} TB"

def media_stats():
    if not os.path.exists(MEDIA_PATH): return {"movies":0,"series":0,"size":"0 B"}
    files, size, series = [], 0, set()
    for r, d, fs in os.walk(MEDIA_PATH):
        for f in fs:
            if f.lower().endswith(('.mp4','.mkv','.avi','.m4v')):
                files.append(f)
                size += os.path.getsize(os.path.join(r,f))
                m = re.search(r'[Ss]\d+[Ee]\d+', f)
                if m: series.add(f[:m.start()].replace('.',' ').strip())
    return {"movies": len(files)-len(series), "series": len(series), "size": format_size(size)}

@app.route('/')
def home(): return render_template('home.html')

@app.route('/wifi')
def wifi(): return render_template('wifi.html')

@app.route('/api/status')
def status():
    clients = get_clients()
    ssid = get_ssid()
    storage = None
    try:
        st = os.statvfs(MEDIA_PATH)
        total, used = st.f_blocks * st.f_frsize, (st.f_blocks - st.f_bavail) * st.f_frsize
        storage = {"used": format_size(used), "total": format_size(total), "percent": round(used/total*100)}
    except: pass
    return jsonify({
        "ssid": ssid, "portal": check_portal() if ssid else False, "vpn": check_vpn(),
        "battery": get_battery(), "devices": len(clients), "storage": storage,
        "media": media_stats(), "client_mac": next((c['mac'] for c in clients if c['ip']==request.remote_addr), None)
    })

@app.route('/api/wifi/scan')
def api_scan():
    nets = scan_wifi()
    cur = get_ssid()
    for n in nets: n['connected'] = n.get('ssid') == cur
    return jsonify({"networks": nets})

@app.route('/api/wifi/connect', methods=['POST'])
def api_connect():
    d = request.json
    ssid, pw = d.get('ssid'), d.get('password')
    if not ssid: return jsonify({"success": False, "error": "SSID requerido"})
    # Create a new network to avoid assuming network 0 exists
    net_id = run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "add_network"]).strip()
    if not net_id.isdigit():
        return jsonify({"success": False, "error": "Error creando red"})
    run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "disconnect"])
    run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "set_network", net_id, "ssid", f'"{ssid}"'])
    if pw:
        run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "set_network", net_id, "psk", f'"{pw}"'])
    else:
        run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "set_network", net_id, "key_mgmt", "NONE"])
    run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "enable_network", net_id])
    run_cmd(["sudo", "wpa_cli", "-i", "wlan0", "select_network", net_id])
    import time
    for _ in range(15):
        time.sleep(1)
        if get_ssid() == ssid:
            run_cmd("sudo dhclient wlan0")
            time.sleep(2)
            portal = check_portal()
            if not portal: run_cmd("sudo systemctl restart wg-quick@wg0")
            return jsonify({"success": True, "portal": portal})
    return jsonify({"success": False, "error": "No se pudo conectar"})

@app.route('/api/wifi/clone', methods=['POST'])
def api_clone():
    mac = next((c['mac'] for c in get_clients() if c['ip']==request.remote_addr), None)
    if not mac: return jsonify({"success": False, "error": "MAC no detectada"})
    run_cmd("sudo wpa_cli -i wlan0 disconnect")
    run_cmd("sudo ip link set wlan0 down")
    run_cmd(["sudo", "ip", "link", "set", "wlan0", "address", mac])
    run_cmd("sudo ip link set wlan0 up")
    run_cmd("sudo wpa_cli -i wlan0 reconnect")
    import time; time.sleep(3)
    return jsonify({"success": True, "mac": mac})

@app.route('/api/wifi/reconnect', methods=['POST'])
def api_reconnect():
    run_cmd("sudo wpa_cli -i wlan0 reconnect")
    import time; time.sleep(4)
    if get_ssid() and not check_portal():
        run_cmd("sudo systemctl restart wg-quick@wg0")
        time.sleep(2)
        return jsonify({"success": True, "vpn": check_vpn()})
    return jsonify({"success": False, "error": "Portal sigue activo"})

@app.route('/api/sync', methods=['POST'])
def api_sync():
    if not check_vpn(): return jsonify({"success": False, "error": "VPN no activa"})
    import threading
    threading.Thread(target=lambda: subprocess.run(["python3", "/opt/pitravel/sync.py"])).start()
    return jsonify({"success": True})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, use_reloader=False)
PYEOF

# Replace placeholders with actual config values
sed -i "s|__MEDIA_PATH__|$MEDIA_PATH|g" $INSTALL_DIR/app.py
sed -i "s|__USB_WIFI__|$USB_WIFI|g" $INSTALL_DIR/app.py

#===============================================================================
# 11. TEMPLATES HTML
#===============================================================================
log "Creando templates..."

cat > $INSTALL_DIR/templates/home.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>PiTravel</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0a0a0a;--card:#161616;--border:#2a2a2a;--text:#fff;--text2:#888;--blue:#3b82f6;--green:#22c55e;--amber:#f59e0b}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;padding:16px}
.container{max-width:400px;margin:0 auto}
.header{text-align:center;padding:20px 0 24px}
.logo{width:56px;height:56px;background:var(--blue);border-radius:16px;margin:0 auto 12px;display:flex;align-items:center;justify-content:center}
.logo svg{width:28px;height:28px;stroke:#fff;fill:none;stroke-width:2}
h1{font-size:22px;font-weight:600}
.subtitle{color:var(--text2);font-size:13px;margin-top:4px}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:20px}
.stat{background:var(--card);border-radius:12px;padding:12px;text-align:center}
.stat-label{font-size:11px;color:var(--text2)}
.stat-value{font-size:18px;font-weight:600;margin-top:4px}
.stat-value.green{color:var(--green)}
.services{display:flex;flex-direction:column;gap:10px}
.service{background:var(--card);border-radius:14px;padding:16px;display:flex;align-items:center;gap:14px;cursor:pointer;text-decoration:none;color:inherit;transition:background .2s}
.service:hover{background:#1f1f1f}
.service-icon{width:44px;height:44px;border-radius:12px;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.service-icon svg{width:22px;height:22px;stroke-width:2;fill:none}
.service-icon.blue{background:#1e3a5f}.service-icon.blue svg{stroke:#60a5fa}
.service-icon.purple{background:#312e81}.service-icon.purple svg{stroke:#a78bfa}
.service-icon.teal{background:#134e4a}.service-icon.teal svg{stroke:#5eead4}
.service-info{flex:1;min-width:0}
.service-title{font-size:15px;font-weight:500}
.service-desc{font-size:13px;color:var(--text2);margin-top:2px}
.service-badge{padding:4px 10px;border-radius:12px;font-size:12px;font-weight:500}
.badge-green{background:#14532d;color:#86efac}
.badge-amber{background:#78350f;color:#fcd34d}
.chevron{stroke:var(--text2);width:20px;height:20px}
.storage{margin-top:16px;padding:12px 16px;background:var(--card);border-radius:12px}
.storage-header{display:flex;justify-content:space-between;font-size:12px;color:var(--text2)}
.storage-bar{height:6px;background:#2a2a2a;border-radius:3px;margin-top:8px;overflow:hidden}
.storage-fill{height:100%;background:var(--blue);border-radius:3px;transition:width .3s}
</style>
</head>
<body>
<div class="container">
<div class="header">
<div class="logo"><svg viewBox="0 0 24 24"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg></div>
<h1>PiTravel</h1>
<p class="subtitle">Router de viaje personal</p>
</div>
<div class="stats">
<div class="stat"><p class="stat-label">Batería</p><p class="stat-value green" id="battery">--%</p></div>
<div class="stat"><p class="stat-label">Dispositivos</p><p class="stat-value" id="devices">-</p></div>
<div class="stat"><p class="stat-label">VPN</p><p class="stat-value" id="vpn">--</p></div>
</div>
<div class="services">
<a href="/wifi" class="service">
<div class="service-icon blue"><svg viewBox="0 0 24 24"><path d="M5 12.55a11 11 0 0114.08 0M1.42 9a16 16 0 0121.16 0M8.53 16.11a6 6 0 016.95 0M12 20h.01"/></svg></div>
<div class="service-info"><p class="service-title">Conectar WiFi</p><p class="service-desc" id="wifi-status">Sin conexión</p></div>
<span class="service-badge badge-amber" id="wifi-badge" style="display:none">Portal</span>
<svg class="chevron" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6" stroke-width="2" fill="none"/></svg>
</a>
<a href="http://192.168.50.1:8080" class="service">
<div class="service-icon purple"><svg viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg></div>
<div class="service-info"><p class="service-title">Media center</p><p class="service-desc" id="media-status">-</p></div>
<svg class="chevron" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6" stroke-width="2" fill="none"/></svg>
</a>
<div class="service" onclick="sync()">
<div class="service-icon teal"><svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 01-9 9m0 0a9 9 0 01-9-9m9 9V3m0 0L8 8m4-5l4 5"/></svg></div>
<div class="service-info"><p class="service-title">Sincronizar</p><p class="service-desc" id="sync-status">Con Jellyfin de casa</p></div>
<svg class="chevron" viewBox="0 0 24 24"><path d="M9 18l6-6-6-6" stroke-width="2" fill="none"/></svg>
</div>
</div>
<div class="storage">
<div class="storage-header"><span>Almacenamiento</span><span id="storage-text">-- / --</span></div>
<div class="storage-bar"><div class="storage-fill" id="storage-fill" style="width:0%"></div></div>
</div>
</div>
<script>
async function load(){
try{
const r=await fetch('/api/status');const d=await r.json();
document.getElementById('battery').textContent=d.battery.percent?d.battery.percent+'%':'N/A';
document.getElementById('devices').textContent=d.devices;
document.getElementById('vpn').textContent=d.vpn?'On':'Off';
document.getElementById('vpn').className='stat-value'+(d.vpn?' green':'');
document.getElementById('wifi-status').textContent=d.ssid||'Sin conexión';
document.getElementById('wifi-badge').style.display=d.portal?'inline':'none';
if(d.media)document.getElementById('media-status').textContent=d.media.movies+' películas, '+d.media.series+' series';
if(d.storage){document.getElementById('storage-text').textContent=d.storage.used+' / '+d.storage.total;
document.getElementById('storage-fill').style.width=d.storage.percent+'%';}
}catch(e){console.error(e)}}
async function sync(){
if(!confirm('¿Iniciar sincronización con Jellyfin?'))return;
try{const r=await fetch('/api/sync',{method:'POST'});const d=await r.json();
alert(d.success?'Sincronización iniciada':'Error: '+d.error);}catch(e){alert('Error');}}
load();setInterval(load,10000);
</script>
</body>
</html>
HTMLEOF

cat > $INSTALL_DIR/templates/wifi.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<title>WiFi - PiTravel</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0a0a0a;--card:#161616;--text:#fff;--text2:#888;--blue:#3b82f6;--green:#22c55e;--amber:#f59e0b;--red:#ef4444}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;padding:16px}
.container{max-width:400px;margin:0 auto}
.header{display:flex;align-items:center;gap:12px;margin-bottom:20px}
.back{width:36px;height:36px;border-radius:10px;background:var(--card);display:flex;align-items:center;justify-content:center;text-decoration:none}
.back svg{width:20px;height:20px;stroke:var(--text2)}
h1{font-size:20px;font-weight:600}
.alert{padding:14px;border-radius:12px;margin-bottom:16px}
.alert.warning{background:#78350f;border:1px solid #92400e}
.alert.success{background:#14532d;border:1px solid #166534}
.alert-title{font-weight:600;font-size:14px;margin-bottom:4px}
.alert-text{font-size:13px;opacity:.85}
.btn{width:100%;padding:12px;border:none;border-radius:10px;font-size:14px;font-weight:600;cursor:pointer;margin-top:10px}
.btn-amber{background:var(--amber);color:#000}
.btn-blue{background:var(--blue);color:#fff}
.btn-outline{background:transparent;border:1px solid #333;color:var(--text2)}
.section{display:flex;justify-content:space-between;align-items:center;margin:16px 0 12px}
.section-title{font-size:14px;font-weight:500}
.networks{display:flex;flex-direction:column;gap:8px}
.network{background:var(--card);border-radius:12px;padding:14px;display:flex;align-items:center;gap:12px;cursor:pointer}
.network.connected{background:#1e3a5f;border:2px solid var(--blue)}
.network-icon svg{width:20px;height:20px;stroke:var(--text2)}
.network.connected .network-icon svg{stroke:var(--blue)}
.network-info{flex:1}
.network-name{font-size:14px;font-weight:500}
.network-sec{font-size:12px;color:var(--text2)}
.network-signal{font-size:12px;color:var(--text2)}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.7);display:none;align-items:center;justify-content:center;padding:16px;z-index:100}
.modal.active{display:flex}
.modal-box{background:var(--card);border-radius:16px;padding:20px;width:100%;max-width:300px}
.modal-title{font-size:18px;font-weight:600;margin-bottom:16px}
.input{width:100%;padding:12px;border:1px solid #333;border-radius:10px;font-size:14px;background:var(--bg);color:var(--text);margin-bottom:12px}
.modal-btns{display:flex;gap:8px}
.modal-btns .btn{flex:1;margin:0}
.mac{font-size:12px;color:var(--text2);text-align:center;margin-top:8px}
</style>
</head>
<body>
<div class="container">
<div class="header">
<a href="/" class="back"><svg viewBox="0 0 24 24" fill="none" stroke-width="2"><path d="M15 18l-6-6 6-6"/></svg></a>
<h1>Conectar WiFi</h1>
</div>
<div id="alert-portal" class="alert warning" style="display:none">
<p class="alert-title">Captive portal detectado</p>
<p class="alert-text">La red requiere autenticación web</p>
<button class="btn btn-amber" onclick="cloneMac()">Clonar mi MAC</button>
<p class="mac" id="my-mac"></p>
</div>
<div id="alert-clone" class="alert success" style="display:none">
<p class="alert-title">MAC clonada</p>
<p class="alert-text">1. Desconecta de PiTravel<br>2. Conéctate al WiFi del hotel<br>3. Pasa el portal<br>4. Vuelve y pulsa Reconectar</p>
<button class="btn btn-blue" onclick="reconnect()">Reconectar</button>
</div>
<div class="section">
<span class="section-title">Redes disponibles</span>
<button class="btn-outline" style="width:auto;padding:6px 12px;font-size:12px" onclick="scan()">Escanear</button>
</div>
<div id="networks" class="networks"><p style="color:var(--text2);text-align:center;padding:20px">Cargando...</p></div>
</div>
<div id="modal" class="modal">
<div class="modal-box">
<p class="modal-title">Conectar a <span id="modal-ssid"></span></p>
<input type="password" id="pwd" class="input" placeholder="Contraseña">
<div class="modal-btns">
<button class="btn btn-outline" onclick="closeModal()">Cancelar</button>
<button class="btn btn-blue" onclick="doConnect()">Conectar</button>
</div>
</div>
</div>
<script>
let selNet=null;
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML;}
async function scan(){
document.getElementById('networks').innerHTML='<p style="color:var(--text2);text-align:center;padding:20px">Escaneando...</p>';
const r=await fetch('/api/wifi/scan');const d=await r.json();
const container=document.getElementById('networks');container.innerHTML='';
d.networks.forEach(n=>{
const el=document.createElement('div');el.className='network'+(n.connected?' connected':'');
el.addEventListener('click',()=>selectNet(n.ssid,!!n.security));
const signal=n.signal>-50?'<path d="M5 12.55a11 11 0 0114.08 0M1.42 9a16 16 0 0121.16 0M8.53 16.11a6 6 0 016.95 0M12 20h.01"/>':
n.signal>-70?'<path d="M5 12.55a11 11 0 0114.08 0M8.53 16.11a6 6 0 016.95 0M12 20h.01"/>':
'<path d="M8.53 16.11a6 6 0 016.95 0M12 20h.01"/>';
el.innerHTML=`<div class="network-icon"><svg viewBox="0 0 24 24" fill="none" stroke-width="2">${signal}</svg></div>
<div class="network-info"><p class="network-name">${esc(n.ssid)}</p><p class="network-sec">${n.connected?'Conectado':esc(n.security||'Abierta')}</p></div>
<span class="network-signal">${n.signal} dBm</span>`;
container.appendChild(el);})}
async function checkStatus(){
const r=await fetch('/api/status');const d=await r.json();
document.getElementById('alert-portal').style.display=d.portal?'block':'none';
if(d.client_mac)document.getElementById('my-mac').textContent='Tu MAC: '+d.client_mac;}
function selectNet(ssid,sec){selNet={ssid,sec};if(sec){document.getElementById('modal-ssid').textContent=ssid;document.getElementById('pwd').value='';document.getElementById('modal').classList.add('active');}else{connect(ssid,null);}}

function closeModal(){document.getElementById('modal').classList.remove('active');}
async function doConnect(){closeModal();await connect(selNet.ssid,document.getElementById('pwd').value);}
async function connect(ssid,pw){
const r=await fetch('/api/wifi/connect',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid,password:pw})});
const d=await r.json();if(d.success){scan();checkStatus();}else{alert('Error: '+d.error);}}
async function cloneMac(){
const r=await fetch('/api/wifi/clone',{method:'POST'});const d=await r.json();
if(d.success){document.getElementById('alert-portal').style.display='none';document.getElementById('alert-clone').style.display='block';}else{alert('Error: '+d.error);}}
async function reconnect(){
const r=await fetch('/api/wifi/reconnect',{method:'POST'});const d=await r.json();
if(d.success){document.getElementById('alert-clone').style.display='none';alert('¡Conectado! VPN: '+(d.vpn?'Activa':'Inactiva'));scan();}else{alert('Error: '+d.error);}}
scan();checkStatus();
</script>
</body>
</html>
HTMLEOF

#===============================================================================
# 12. SERVICIO SYSTEMD
#===============================================================================
log "Configurando servicios..."

cat > /etc/systemd/system/pitravel.service << EOF
[Unit]
Description=PiTravel Web Interface
After=network.target hostapd.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pitravel

#===============================================================================
# 13. PISUGAR (opcional)
#===============================================================================
if [[ "$INSTALL_PISUGAR" == "s" ]]; then
    log "Instalando PiSugar..."
    curl -sSL http://cdn.pisugar.com/release/pisugar-power-manager.sh | bash
fi

#===============================================================================
# 14. JELLYFIN SYNC (opcional)
#===============================================================================
if [[ "$INSTALL_SYNC" == "s" ]]; then
    log "Configurando Jellyfin sync..."
    
    cat > $INSTALL_DIR/sync.py << 'SYNCEOF'
#!/usr/bin/env python3
import requests, os, subprocess, re, json
from pathlib import Path

JELLYFIN_URL = "__JELLYFIN_URL__"
API_KEY = "__JELLYFIN_API_KEY__"
USER_ID = "__JELLYFIN_USER_ID__"
MEDIA = "__MEDIA_PATH__"

def log(m): print(f"[SYNC] {m}")

def get_favorites():
    try:
        r = requests.get(f"{JELLYFIN_URL}/Users/{USER_ID}/Items",
            headers={"X-Emby-Token": API_KEY},
            params={"Filters": "IsFavorite", "IncludeItemTypes": "Movie,Episode", "Recursive": True})
        return r.json().get("Items", [])
    except Exception as e:
        log(f"Error: {e}")
        return []

def download(item):
    name = item["Name"]
    if item["Type"] == "Episode":
        name = f"{item.get('SeriesName','')}.S{item.get('ParentIndexNumber',0):02d}E{item.get('IndexNumber',0):02d}"
    fname = "".join(c for c in name if c.isalnum() or c in ' .-_').strip() + ".mp4"
    path = os.path.join(MEDIA, fname)
    if os.path.exists(path):
        log(f"Ya existe: {fname}")
        return
    log(f"Descargando: {fname}")
    subprocess.run(["wget", "-q", "--header", f"X-Emby-Token: {API_KEY}",
        "-O", path, f"{JELLYFIN_URL}/Items/{item['Id']}/Download"], timeout=7200)

if __name__ == "__main__":
    os.makedirs(MEDIA, exist_ok=True)
    items = get_favorites()[:20]
    log(f"Favoritos: {len(items)}")
    for i in items: download(i)
    log("Completado")
SYNCEOF

    chmod +x "$INSTALL_DIR/sync.py"

    # Inject config values
    sed -i "s|__JELLYFIN_URL__|$JELLYFIN_URL|g" $INSTALL_DIR/sync.py
    sed -i "s|__JELLYFIN_API_KEY__|$JELLYFIN_API_KEY|g" $INSTALL_DIR/sync.py
    sed -i "s|__JELLYFIN_USER_ID__|$JELLYFIN_USER_ID|g" $INSTALL_DIR/sync.py
    sed -i "s|__MEDIA_PATH__|$MEDIA_PATH|g" $INSTALL_DIR/sync.py

    [[ -z "$JELLYFIN_API_KEY" ]] && warn "Edita $INSTALL_DIR/sync.py con tu API_KEY y USER_ID de Jellyfin"

    #============================================================================
    # 14b. CRONTAB + LOGROTATE (sync automático)
    #============================================================================
    log "Configurando sync automático..."

    cat > $INSTALL_DIR/sync_cron.sh << 'EOF'
#!/bin/bash
if sudo wg show wg0 2>/dev/null | grep -q "interface"; then
    /usr/bin/python3 /opt/pitravel/sync.py >> /var/log/pitravel/sync.log 2>&1
else
    echo "$(date): VPN no activa, sync cancelado" >> /var/log/pitravel/sync.log
fi
EOF

    chmod +x $INSTALL_DIR/sync_cron.sh

    # Añadir al crontab de root si no existe ya
    CRON_JOB="0 3 * * * /bin/bash /opt/pitravel/sync_cron.sh"
    ( sudo crontab -l 2>/dev/null | grep -v "sync_cron"; echo "$CRON_JOB" ) | sudo crontab -

    # Logrotate
    cat > /etc/logrotate.d/pitravel << 'EOF'
/var/log/pitravel/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

    log "  Cron: sync diario a las 3am"
    log "  Logrotate: rotación semanal, 4 semanas"
fi

#===============================================================================
# 15. MONTAR USB AUTOMÁTICAMENTE
#===============================================================================
log "Configurando automount USB..."

mkdir -p /media/usb
grep -q '/media/usb' /etc/fstab || echo '/dev/sda1 /media/usb auto defaults,nofail,x-systemd.device-timeout=5 0 0' >> /etc/fstab

#===============================================================================
# FINALIZADO
#===============================================================================
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              ¡Instalación completada!                     ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo -e "${GREEN}Tu Access Point:${NC}"
echo "  SSID: $AP_SSID"
echo "  Pass: $AP_PASS"
echo "  IP:   $AP_IP"
echo ""
echo -e "${GREEN}Tu clave pública WireGuard:${NC}"
cat /etc/wireguard/publickey
echo ""
echo -e "${YELLOW}Próximos pasos:${NC}"
STEP=1
[[ -z "$WG_PEER_PUBKEY" ]] && echo "  $((STEP++)). Edita /etc/wireguard/wg0.conf con datos de tu servidor VPN"
[[ "$INSTALL_SYNC" == "s" && -z "$JELLYFIN_API_KEY" ]] && echo "  $((STEP++)). Edita $INSTALL_DIR/sync.py con API_KEY de Jellyfin"
echo "  $((STEP++)). Conecta SSD/pendrive USB"
echo "  $((STEP++)). Reinicia: sudo reboot"
echo ""
echo -e "${GREEN}Acceso:${NC}"
echo "  Panel:  http://$AP_IP"
echo "  Media:  http://$AP_IP:8080 (para Infuse/VLC)"
echo ""