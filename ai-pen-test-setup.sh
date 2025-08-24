#!/usr/bin/env bash
# ai-pen-test-setup.sh
# Purpose: Trim a Cubic Ubuntu image and install/categorize AI pen-testing tools.
# Usage (inside Cubic chroot):  sudo bash ai-pen-test-setup.sh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (inside Cubic chroot)."; exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating APT indexes..."
apt-get update -y

# ---------- 1) Remove non-essential desktop apps (safe-ish list) ----------
# NOTE: Avoid purging meta-packages like ubuntu-desktop. Adjust as needed.
REMOVE_PKGS=(
  libreoffice-core libreoffice-common libreoffice-writer libreoffice-calc libreoffice-impress
  thunderbird
  totem rhythmbox shotwell simple-scan cheese
  transmission-gtk
  gnome-tour
  ubuntu-web-launchers
  aisleriot gnome-mahjongg gnome-mines gnome-sudoku
)
echo "[*] Removing non-essential packages..."
apt-get purge -y "${REMOVE_PKGS[@]}" || true
apt-get autoremove -y --purge || true
apt-get clean

# ---------- 2) Base build/runtime dependencies ----------
echo "[*] Installing base dependencies..."
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq pkg-config build-essential \
  python3 python3-venv python3-pip python3-dev \
  libffi-dev libssl-dev libxml2-dev libxslt1-dev zlib1g-dev \
  libjpeg-dev libpng-dev libtiff5 libopenblas-base \
  xdg-utils desktop-file-utils xterm gnome-terminal || true

# ---------- 3) Node.js + promptfoo (LLM eval) ----------
echo "[*] Installing Node.js 18.x and promptfoo CLI (global)..."
if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE '^v1[89]|^v2[0-9]'; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
fi
npm install -g promptfoo || true   # falls back to /usr/local/bin/promptfoo

# ---------- 4) Python virtual env for AI pen-testing ----------
echo "[*] Creating Python virtual environment at /opt/ai-pt/venv ..."
install -d -m 0755 /opt/ai-pt
python3 -m venv /opt/ai-pt/venv
source /opt/ai-pt/venv/bin/activate
python -m pip install --upgrade pip setuptools wheel

# ---------- 5) AI pen-testing toolkits ----------
# Adversarial ML (CV/NLP), LLM red teaming, supply-chain model scanning
echo "[*] Installing Python AI security libraries into venv..."
pip install --no-cache-dir \
  adversarial-robustness-toolbox \
  textattack \
  OpenAttack \
  foolbox \
  "garak>=0.10" \
  modelscan \
  llm-guard

# Microsoft Counterfit (CLI) from source
echo "[*] Installing Microsoft Counterfit (from GitHub, editable)..."
if [[ ! -d /opt/ai-pt/counterfit ]]; then
  git clone https://github.com/Azure/counterfit.git /opt/ai-pt/counterfit
fi
pip install -e /opt/ai-pt/counterfit
python - <<'PY'
try:
  import nltk
  nltk.download('stopwords')
except Exception as e:
  print("[!] NLTK stopwords download failed (ok to ignore):", e)
PY

# Optional: Vigil-LLM (prompt injection/jailbreak detection; experimental)
echo "[*] (Optional) Installing vigil-llm (experimental)..."
if [[ ! -d /opt/ai-pt/vigil-llm ]]; then
  git clone https://github.com/deadbits/vigil-llm.git /opt/ai-pt/vigil-llm || true
fi
pip install -e /opt/ai-pt/vigil-llm || true

deactivate

# ---------- 6) Friendly command wrappers ----------
echo "[*] Creating CLI wrappers in /usr/local/bin ..."
make_wrapper () {
  local cmd_name="$1"; shift
  local target="$*"
  cat >/usr/local/bin/${cmd_name} <<EOF
#!/usr/bin/env bash
exec /opt/ai-pt/venv/bin/${target} "\$@"
EOF
  chmod +x /usr/local/bin/${cmd_name}
}

make_wrapper garak garak
make_wrapper textattack textattack
make_wrapper modelscan modelscan
# Counterfit exposes 'counterfit' entry point after install
make_wrapper counterfit counterfit

# Node global bin often is /usr/bin or /usr/local/bin; ensure symlink
if command -v promptfoo >/dev/null 2>&1; then
  ln -sf "$(command -v promptfoo)" /usr/local/bin/promptfoo
fi

# ---------- 7) Desktop menu entries (XDG) ----------
echo "[*] Creating desktop entries..."
mkdir -p /usr/share/applications
create_desktop () {
  local file="$1" name="$2" comment="$3" exec_line="$4"
  cat >"/usr/share/applications/${file}" <<EOF
[Desktop Entry]
Name=${name}
Comment=${comment}
Exec=${exec_line}
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Security;Education;Development;
EOF
}

create_desktop "garak.desktop" "Garak — LLM Vulnerability Scanner" \
  "Probe LLMs for jailbreaks, prompt injection, leakage, toxicity, etc." \
  "/usr/local/bin/garak --help"

create_desktop "counterfit.desktop" "Counterfit — ML Security CLI" \
  "Run adversarial ML assessments across image, text, and tabular targets." \
  "/usr/local/bin/counterfit"

create_desktop "promptfoo.desktop" "Promptfoo — LLM Evaluator" \
  "Test prompts, assertions, and guardrails for LLM apps." \
  "/usr/local/bin/promptfoo --help"

create_desktop "modelscan.desktop" "ModelScan — Scan ML Models" \
  "Detect unsafe code in serialized ML models (pickle, h5, TF SavedModel)." \
  "/usr/local/bin/modelscan -h"

create_desktop "textattack.desktop" "TextAttack — NLP Attacks" \
  "Generate adversarial text examples for NLP models." \
  "/usr/local/bin/textattack --help"

# Optional (experimental) Vigil-LLM launcher
if [[ -f /opt/ai-pt/vigil-llm/vigil-server.py ]]; then
  cat >"/usr/share/applications/vigil-llm.desktop" <<'EOF'
[Desktop Entry]
Name=Vigil-LLM — Prompt Injection Scanner (Experimental)
Comment=Detect LLM prompt injections and jailbreaks using Vigil
Exec=/usr/bin/env bash -lc "cd /opt/ai-pt/vigil-llm && /opt/ai-pt/venv/bin/python vigil-server.py --conf conf/server.conf"
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Security;Education;Development;
EOF
fi

update-desktop-database || true

# ---------- 8) Category folder (best-effort; not all DEs surface custom menus) ----------
mkdir -p /usr/share/desktop-directories /etc/xdg/menus/applications-merged
cat >/usr/share/desktop-directories/ai-pen-testing.directory <<'EOF'
[Desktop Entry]
Name=AI Pen Testing
Icon=applications-science
Type=Directory
EOF

cat >/etc/xdg/menus/applications-merged/ai-pen-testing.menu <<'EOF'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>AI Pen Testing</Name>
    <Directory>ai-pen-testing.directory</Directory>
    <Include>
      <Category>Security</Category>
    </Include>
  </Menu>
</Menu>
EOF

# ---------- 9) Post-cleanup ----------
echo "[*] Final cleanup..."
apt-get autoremove -y --purge || true
apt-get clean

echo "===================================================================="
echo "[✓] AI pen-testing environment ready."
echo "Tools installed in /opt/ai-pt/venv and exposed via:"
echo "  - garak, counterfit, textattack, modelscan, promptfoo"
echo "Menu entries added under 'AI Pen Testing' (where supported)."
echo "===================================================================="
