#!/usr/bin/env bash
# Lab harness agent (dummy). It stands in for the real lab agent, so that the whole reader flow can be
# tested before srsRAN goes in: the site creates the Codespace, waits, pairs, runs a scenario, and stops it.
#
#   bash .devcontainer/lab-agent.sh start    (postStartCommand) start the agent in the background, make port 8080 public
#   bash .devcontainer/lab-agent.sh status   show the agent log
#
# Pairing: the site creates the Codespace with the display name "lab-<code>", so the site already knows the
# code. The agent reads its own display name through the GitHub API and uses the same code ("name" mode).
# If it cannot read the name, it falls back to "first-use" mode: the first POST /pair from an allowed site,
# within 15 minutes of start, receives a new code, and every later /pair is refused.
#
# Endpoints (JSON):
#   GET  /health               no code needed: {"agent": "up", "pairing": "name" | "first-use", ...} (no secrets)
#   POST /pair                 first-use mode only: returns the code once
#   GET  /ping                 code needed (X-Lab-Token)
#   GET  /run?scenario=attach  code needed: a dummy attach, as the real agent would return it

set -uo pipefail
PORT=8080
LOG=/tmp/lab-agent.log

start() {
  pkill -f "lab-agent-server" 2>/dev/null
  local name="" code=""
  # The code comes from this Codespace's display name, "lab-<hex>"
  name=$(gh api "/user/codespaces/$CODESPACE_NAME" -q .display_name 2>/tmp/lab-name.err) || name=""
  [[ $name =~ ^lab-([0-9a-f]{8,32})$ ]] && code=${BASH_REMATCH[1]}
  {
    echo "$(date -u +%FT%TZ) start: codespace=$CODESPACE_NAME display_name='${name}' pairing=$([ -n "$code" ] && echo name || echo first-use)"
    [ -n "$code" ] || echo "  (could not read the display name: $(head -c 200 /tmp/lab-name.err))"
  } >> "$LOG"
  LAB_CODE="$code" setsid nohup python3 -u - "$PORT" lab-agent-server >> "$LOG" 2>&1 <<'PY' &
import json, os, secrets, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ORIGINS = set(os.environ.get('LAB_ORIGINS', 'http://localhost:5180').split())
STARTED = time.time()
state = {'code': os.environ.get('LAB_CODE') or None, 'mode': 'name' if os.environ.get('LAB_CODE') else 'first-use'}

# A dummy attach: the messages and the gaps between them, as the real agent will report them from srsRAN
ATTACH = [
    ('UE', 'eNB', 'RRC', 'RRCConnectionRequest', 0), ('eNB', 'UE', 'RRC', 'RRCConnectionSetup', 12),
    ('UE', 'eNB', 'RRC', 'RRCConnectionSetupComplete + Attach Request', 9), ('eNB', 'MME', 'S1AP', 'Initial UE Message', 1),
    ('MME', 'UE', 'NAS', 'Authentication Request', 18), ('UE', 'MME', 'NAS', 'Authentication Response', 14),
    ('MME', 'UE', 'NAS', 'Security Mode Command', 16), ('UE', 'MME', 'NAS', 'Security Mode Complete', 13),
    ('MME', 'UE', 'NAS', 'Attach Accept', 25), ('UE', 'MME', 'NAS', 'Attach Complete', 21),
]

class Agent(BaseHTTPRequestHandler):
    def cors(self):
        origin = self.headers.get('Origin')
        if origin in ORIGINS:
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Vary', 'Origin')
            self.send_header('Access-Control-Allow-Headers', 'X-Lab-Token, Content-Type')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST')
            self.send_header('Access-Control-Allow-Private-Network', 'true')

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.cors()
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print(f'{time.strftime("%H:%M:%S")} {self.command} {urlparse(self.path).path} from {self.headers.get("Origin")} -> {code}', flush=True)

    def authed(self):
        return state['code'] is not None and secrets.compare_digest(self.headers.get('X-Lab-Token', ''), state['code'])

    def do_OPTIONS(self):
        self.send_response(204); self.cors(); self.end_headers()

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == '/health':
            return self.reply(200, {'agent': 'up', 'pairing': state['mode'], 'paired': state['code'] is not None,
                                    'uptime_s': round(time.time() - STARTED, 1)})
        if not self.authed():
            return self.reply(401, {'ok': False, 'error': 'missing or wrong pairing code'})
        if u.path == '/ping':
            return self.reply(200, {'ok': True, 'codespace': os.environ.get('CODESPACE_NAME')})
        if u.path == '/run':
            scenario = parse_qs(u.query).get('scenario', [''])[0]
            if scenario != 'attach':  # named scenarios only: anything else is refused
                return self.reply(400, {'ok': False, 'error': f'unknown scenario {scenario!r}'})
            time.sleep(1.5)  # the real attach takes about 1.6 s
            t, msgs = 0, []
            for src, dst, layer, name, gap in ATTACH:
                t += gap
                msgs.append({'t_ms': t, 'from': src, 'to': dst, 'layer': layer, 'msg': name})
            return self.reply(200, {'ok': True, 'scenario': 'attach', 'dummy': True, 'messages': msgs})
        self.reply(404, {'ok': False, 'error': 'no such path'})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != '/pair':
            return self.reply(404, {'ok': False, 'error': 'no such path'})
        if self.headers.get('Origin') not in ORIGINS:
            return self.reply(403, {'ok': False, 'error': 'site not allowed'})
        if state['mode'] != 'first-use' or state['code'] is not None or time.time() - STARTED > 900:
            return self.reply(409, {'ok': False, 'error': 'pairing is closed'})
        state['code'] = secrets.token_hex(8)
        self.reply(200, {'ok': True, 'code': state['code']})

    def log_message(self, *a):
        pass

ThreadingHTTPServer(('0.0.0.0', int(sys.argv[1])), Agent).serve_forever()
PY
  # Wait for the agent, then make the port public (the reader never opens the Ports panel)
  local i
  for ((i = 0; i < 30; i++)); do curl -fs "http://localhost:$PORT/health" >/dev/null && break; sleep 1; done
  for ((i = 0; i < 10; i++)); do
    if gh codespace ports visibility "$PORT:public" -c "$CODESPACE_NAME" >>"$LOG" 2>&1; then
      echo "$(date -u +%FT%TZ) port $PORT is public" >> "$LOG"; return 0
    fi
    sleep 3
  done
  echo "$(date -u +%FT%TZ) could not make port $PORT public" >> "$LOG"
}

case "${1:-}" in
  start) start ;;
  status) cat "$LOG" ;;
  *) echo "usage: bash .devcontainer/lab-agent.sh start|status"; exit 1 ;;
esac
