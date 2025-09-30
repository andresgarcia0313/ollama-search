#!/usr/bin/env bash
# ollama-cli: search/inspect Ollama Library from the terminal.
# Requires: curl, grep, awk, sed
set -euo pipefail

HOST=${OLLAMA_LIBRARY_HOST:-https://ollama.com}
LIB="$HOST/library"
SEARCH_URL="$HOST/search"

# Defaults
LANG_CHOICE=${OLLAMA_CLI_LANG:-en}
LIMIT=50

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'. Please install it."; exit 1; }; }
need curl; need grep; need awk; need sed

# --- i18n (minimal) ---
msg() {
  local key="$1"
  case "$LANG_CHOICE" in
    es)
      case "$key" in
        USAGE) cat <<'EOF'
Uso:
  ollama-cli search <texto|modelo> [--limit N] [--lang en|es]
     - Busca modelos en la librería web y muestra líneas "modelo:tag".
     - Si <texto> es un nombre de modelo exacto, lista todas sus tags.

  ollama-cli exists <modelo>
     - Devuelve "yes"/"no" si existe en la librería remota.

  ollama-cli tags <modelo>
     - Lista sólo las tags de ese modelo (una por línea).

  ollama-cli pull <modelo[:tag]>
     - Hace "ollama pull" si existe y no está instalado.

  ollama-cli installed
     - Muestra modelos locales (equivale a "ollama list").

Opciones:
  --limit N      Limita cuántos modelos procesa en "search" (por defecto 50)
  --lang en|es   Idioma de mensajes (por defecto: en; también OLLAMA_CLI_LANG)
  -h, --help     Muestra esta ayuda
Notas:
  - No hay endpoint oficial para listar el catálogo remoto; se usa HTML de /search y /library/<modelo>.
EOF
        ;; 
        NOT_FOUND) echo "No encontrado en la librería:" ;; 
        DOWNLOADING) echo "Descargando" ;; 
        INSTALLED) echo "Ya instalado:" ;; 
        NEED_ARG) echo "Falta argumento." ;; 
      esac
      ;; 
    *) # en
      case "$key" in
        USAGE) cat <<'EOF'
Usage:
  ollama-cli search <text|model> [--limit N] [--lang en|es]
     - Searches the web library and prints "model:tag" lines.
     - If <text> is an exact model name, prints all its tags.

  ollama-cli exists <model>
     - Prints "yes"/"no" if the model exists in the remote library.

  ollama-cli tags <model>
     - Prints tags of the model (one per line).

  ollama-cli pull <model[:tag]>
     - Runs "ollama pull" if it exists and isn't installed.

  ollama-cli installed
     - Shows local models (same as "ollama list").

Options:
  --limit N      Limit how many models are processed by "search" (default 50)
  --lang en|es   Message language (default: en; also OLLAMA_CLI_LANG)
  -h, --help     Show this help
Notes:
  - There is no official endpoint to list the remote catalog; this scrapes /search and /library/<model>.
EOF
        ;; 
        NOT_FOUND) echo "Not found in library:" ;; 
        DOWNLOADING) echo "Downloading" ;; 
        INSTALLED) echo "Already installed:" ;; 
        NEED_ARG) echo "Missing argument." ;; 
      esac
      ;; 
esac
}

usage() { msg USAGE; }

# --- helpers ---
parse_models() {
  # Extract /library/<name> from HTML and normalize
  grep -oE '/library/[a-zA-Z0-9._:-]+' \
  | sed 's#/library/##' \
  | sed 's#:$##' \
  | sort -u
}

urlencode() { local s="${1}"; python3 - <<EOF 2>/dev/null || echo "${s// /%20}"
import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))
EOF
}

exists_model() {
  local m="$1"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$LIB/$m")
  [[ "$code" == "200" ]]
}

list_tags() {
  local m="$1"
  # Extract occurrences like "<model>:<tag>" from the model page
  curl -fsSL "$LIB/$m" \
  | grep -oE "${m}:[a-zA-Z0-9._-]+" \
  | awk -F: '{print $2}' \
  | sort -u
}

search_models() {
  local q="$1"
  # The site's search (?q=) is too broad, matching descriptions and returning
  # unrelated models. It's more reliable to get the full list from the library
  # and filter it by name with grep.
  curl -fsSL "$LIB" | parse_models | grep -i "$q" || true
}

print_model_details() {
  local m="$1"
  local html
  # Fetch model page, exit on failure
  html=$(curl -fsSL "$LIB/$m") || return

  # To improve parsing, add newlines after some tags
  local parsable_html
  parsable_html=$(echo "$html" | sed 's#</a>#</a>\n#g; s#</span>#</span>\n#g; s#</div>#</div>\n#g')

  local tags
  tags=$(echo "$html" | grep -oE "${m}:[a-zA-Z0-9._-]+" | awk -F: '{print $2}' | sort -u)

  if [[ -z "$tags" ]]; then
    # Fallback for models with no explicit tags found on the page
    echo -e "${m}\tlatest\tN/A\tN/A"
    return
  fi

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue

    # Get the HTML block for this specific tag to find details
    local context
    context=$(echo "$parsable_html" | grep -A 20 "href=\"/library/${m}:${tag}\"")

    # Best-effort extraction of parameter size (e.g., 7B, 70B)
    local params
    params=$(echo "$context" | grep -ioE '[0-9.]+B' | head -n 1)

    # Best-effort extraction of file size (e.g., 3.8 GB)
    local size
    size=$(echo "$context" | grep -ioE '[0-9.]+\s*[MG]B' | head -n 1)

    echo -e "${m}\t${tag}\t${params:-N/A}\t${size:-N/A}"
  done <<< "$tags"
}

# --- arg parsing (simple) ---
ARGS=()
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --lang) LANG_CHOICE="${2:-en}"; shift 2;; 
    --lang=*) LANG_CHOICE="${1#*=}"; shift;; 
    --limit) LIMIT="${2:-50}"; shift 2;; 
    --limit=*) LIMIT="${1#*=}"; shift;; 
    -h|--help|help) usage; exit 0;; 
    *) ARGS+=("$1"); shift;; 
  esac
done
set -- "${ARGS[@]:-}"

cmd="${1:-""}"
arg="${2:-""}"

case "$cmd" in
  search)
    [[ -z "$arg" ]] && { msg NEED_ARG; echo; usage; exit 1; }

    # Search and expand tags for each model found (up to LIMIT)
    results=$(
      count=0
      while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        print_model_details "$m" &
        count=$((count+1))
        [[ "$count" -ge "$LIMIT" ]] && break
      done < <(search_models "$arg")
      wait
    )

    if [[ -n "$results" ]]; then
      (
        echo -e "MODEL\tTAG\tPARAMS\tSIZE"
        # Sort results to keep output consistent
        echo "$results" | sort
      ) | column -t -s $'	'
    fi
    ;; 
  tags)
    [[ -z "$arg" ]] && { msg NEED_ARG; exit 1; }
    exists_model "$arg" || { msg NOT_FOUND; echo "  $LIB/$arg"; exit 2; }
    list_tags "$arg"
    ;; 
  exists)
    [[ -z "$arg" ]] && { msg NEED_ARG; exit 1; }
    if exists_model "$arg"; then echo "yes"; else echo "no"; fi
    ;; 
  pull)
    [[ -z "$arg" ]] && { msg NEED_ARG; exit 1; }
    if command -v ollama >/dev/null 2>&1; then
      if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "${arg}"; then
        msg INSTALLED; echo " ${arg}"; exit 0
      fi
    fi
    base="${arg%%:*}"
    exists_model "$base" || { msg NOT_FOUND; echo "  $LIB/$base"; exit 2; }
    msg DOWNLOADING; echo " ${arg}...";
    exec ollama pull "${arg}"
    ;; 
  installed)
    exec ollama list
    ;; 
  ""|-h|--help|help)
    usage
    ;; 
  *)
    usage; exit 1;; 
esac