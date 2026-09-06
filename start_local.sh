#!/usr/bin/env bash
# MetaGPT local deploy one-click start script
# usage: bash start_local.sh [mock|real]
set -euo pipefail

PROJECT_DIR="/Volumes/MacSD/GitHub/MetaGPT"
VENV="$PROJECT_DIR/.venv-metagpt"
CONFIG_FILE="$HOME/.metagpt/config2.yaml"
CONFIG_OLLAMA="$HOME/.metagpt/config2.ollama.yaml"
CONFIG_MOCK="$HOME/.metagpt/config2.mock.yaml"
MODEL="qwen2.5:14b"
OLLAMA_PORT=11434
MODE="${1:-mock}"
LOG_DIR="$PROJECT_DIR/tmp"
LOG_FILE="$LOG_DIR/metagpt_${MODE}.log"
mkdir -p "$LOG_DIR"

C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_BLUE="\033[34m"; C_RESET="\033[0m"
log_info()  { echo -e "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }

echo -e "${C_GREEN}=====================================${C_RESET}"
echo -e "${C_GREEN}  MetaGPT local deploy start script  ${C_RESET}"
echo -e "${C_GREEN}=====================================${C_RESET}"
echo "mode: $MODE  (mock=offline smoke / real=local model)"
echo

if [[ "$(pwd)" != "$PROJECT_DIR" ]]; then
  log_error "please run in project root: cd \"$PROJECT_DIR\" && bash start_local.sh $MODE"
  exit 1
fi

log_info "[1] check environment..."
command -v python3.11 >/dev/null 2>&1 || { log_error "python3.11 not found (MetaGPT requires >=3.9, <3.12)"; exit 1; }
[[ -x "$VENV/bin/python" ]] || { log_error "venv not found: $VENV (run deploy first)"; exit 1; }
"$VENV/bin/python" -c "import metagpt" >/dev/null 2>&1 || { log_error "metagpt not installed in venv"; exit 1; }
log_ok "Python 3.11 + venv + metagpt ready"
command -v ollama >/dev/null 2>&1 || { log_error "ollama not installed (needed for real mode)"; exit 1; }
log_ok "ollama installed: $(ollama --version 2>/dev/null | head -1)"

log_info "[2] check and release ollama port ($OLLAMA_PORT)..."
PID="$(lsof -ti tcp:$OLLAMA_PORT -sTCP:LISTEN 2>/dev/null || true)"
if [[ -n "$PID" ]]; then
  log_warn "port $OLLAMA_PORT is used by pid $PID, killing to release..."
  kill "$PID" 2>/dev/null || true
  sleep 1
fi

log_info "start ollama service (background)..."
nohup ollama serve > "$LOG_DIR/ollama.log" 2>&1 &
OLLAMA_PID=$!

ready=0
for _ in $(seq 1 15); do
  if curl -s --max-time 2 "http://localhost:$OLLAMA_PORT/api/tags" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
if [[ $ready -eq 1 ]]; then
  log_ok "ollama service ready (http://localhost:$OLLAMA_PORT)"
else
  log_error "ollama service failed, see $LOG_DIR/ollama.log"
  kill "$OLLAMA_PID" 2>/dev/null || true
  exit 1
fi

# 清理上次异常退出可能残留的配置备份，保证状态干净
rm -f "$CONFIG_FILE.bak"

if [[ "$MODE" == "mock" ]]; then
  log_info "[3] switch to offline mock smoke config..."
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
  cp "$CONFIG_MOCK" "$CONFIG_FILE"
  MOCK_ACTIVE=1
  MODEL_USED="(offline placeholder, no real request)"
else
  log_info "[3] use ollama local model config (real mode)..."
  cp "$CONFIG_OLLAMA" "$CONFIG_FILE"
  MOCK_ACTIVE=0
  MODEL_USED="$MODEL"
  if ! ollama list | grep -q "$MODEL"; then
    log_warn "model $MODEL not found, pulling (may take a while)..."
    ollama pull "$MODEL" || { log_error "model pull failed"; kill "$OLLAMA_PID" 2>/dev/null || true; exit 1; }
  fi
fi

cleanup() {
  echo
  log_warn "interrupt received, cleaning up..."
  [[ -n "${METAGPT_PID:-}" ]] && kill "$METAGPT_PID" 2>/dev/null || true
  kill "$OLLAMA_PID" 2>/dev/null || true
  if [[ "${MOCK_ACTIVE:-0}" -eq 1 ]]; then
    if [[ -f "$CONFIG_FILE.bak" ]]; then
      cp "$CONFIG_FILE.bak" "$CONFIG_FILE" && rm -f "$CONFIG_FILE.bak"
    else
      cp "$CONFIG_OLLAMA" "$CONFIG_FILE"
    fi
    log_info "restored config ($CONFIG_FILE)"
  fi
  log_ok "all stopped"
  exit 0
}
trap cleanup INT TERM

log_info "[4] start MetaGPT ($MODE mode) in background, log: $LOG_FILE"
log_info "tip: tail -f $LOG_FILE to view; press Ctrl+C to stop all"

if [[ "$MODE" == "mock" ]]; then
  nohup "$VENV/bin/python" "$PROJECT_DIR/tmp/run_mock_company.py" > "$LOG_FILE" 2>&1 &
else
  nohup "$VENV/bin/metagpt" "create a command-line snake game" > "$LOG_FILE" 2>&1 &
fi
METAGPT_PID=$!
log_ok "MetaGPT started, PID=$METAGPT_PID, model: $MODEL_USED"

wait
