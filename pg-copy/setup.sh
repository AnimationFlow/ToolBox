#!/usr/bin/env bash
set -e

if ! command -v uv &>/dev/null; then
    echo "uv not found - installing..."
    curl -Ls https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

uv venv
uv pip install -r requirements.txt

if [ -f .env ]; then
    echo ".env already exists - skipping credential setup."
    echo "Delete .env and re-run setup.sh to reconfigure."
else
    read_default() {
        local prompt="$1" default="$2" var="$3" val
        read -rp "  $prompt${default:+ [$default]}: " val
        printf -v "$var" '%s' "${val:-$default}"
    }

    echo
    echo "--- Stage DB ---"
    read_default "Host"     ""          STAGE_HOST
    read_default "Port"     "5432"      STAGE_PORT
    read_default "Database" ""          STAGE_DBNAME
    read_default "User"     ""          STAGE_USER
    read_default "Password" ""          STAGE_PASSWORD

    echo
    echo "--- Local DB ---"
    read_default "Host"     "localhost"  LOCAL_HOST
    read_default "Port"     "5432"       LOCAL_PORT
    read_default "Database" ""           LOCAL_DBNAME
    read_default "User"     "postgres"   LOCAL_USER
    read_default "Password" ""           LOCAL_PASSWORD

    cat > .env <<EOF
STAGE_HOST=$STAGE_HOST
STAGE_PORT=$STAGE_PORT
STAGE_DBNAME=$STAGE_DBNAME
STAGE_USER=$STAGE_USER
STAGE_PASSWORD=$STAGE_PASSWORD

LOCAL_HOST=$LOCAL_HOST
LOCAL_PORT=$LOCAL_PORT
LOCAL_DBNAME=$LOCAL_DBNAME
LOCAL_USER=$LOCAL_USER
LOCAL_PASSWORD=$LOCAL_PASSWORD
EOF

    echo
    echo ".env written."
fi

echo
echo "Setup complete. Run ./start.sh to launch."
