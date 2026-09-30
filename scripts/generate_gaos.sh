#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Works both in GitHub repo root (scripts/..) and google3 (third_party/py/google/genai/..)
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse optional CLI flags
SPEC_FILE_CLI=""
SPEAKEASY_CONFIG_DIR_CLI=""
TARGET_GAOS_DIR_CLI=""
GENERATOR_BIN_CLI=""
SYNC_GAOS_OUTPUT_BIN_CLI=""
SKIP_COMPILE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec|-s)
      SPEC_FILE_CLI="$2"
      shift 2
      ;;
    --speakeasy-config)
      SPEAKEASY_CONFIG_DIR_CLI="$2"
      shift 2
      ;;
    --output-dir|-o)
      TARGET_GAOS_DIR_CLI="$2"
      shift 2
      ;;
    --generator-bin)
      GENERATOR_BIN_CLI="$2"
      shift 2
      ;;
    --sync-bin)
      SYNC_GAOS_OUTPUT_BIN_CLI="$2"
      shift 2
      ;;
    --no-skip-compile)
      SKIP_COMPILE=false
      shift 1
      ;;
    --skip-compile)
      SKIP_COMPILE=true
      shift 1
      ;;
    *)
      echo "Warning: Unknown option '$1', skipping." >&2
      shift 1
      ;;
  esac
done

# Locate spec file: CLI arg > in GitHub repo (.speakeasy/openapi.json) > in google3
if [[ -n "${SPEC_FILE_CLI}" && -f "${SPEC_FILE_CLI}" ]]; then
  SPEC_FILE="${SPEC_FILE_CLI}"
elif [[ -f "${REPO_ROOT}/.speakeasy/openapi.json" ]]; then
  SPEC_FILE="${REPO_ROOT}/.speakeasy/openapi.json"
elif [[ -f "${REPO_ROOT}/../../../../labs/language/genai/interactions/openapi/genai-next/specs/genai/openapi.with-overlays.gaos.json" ]]; then
  SPEC_FILE="${REPO_ROOT}/../../../../labs/language/genai/interactions/openapi/genai-next/specs/genai/openapi.with-overlays.gaos.json"
elif [[ -f "${REPO_ROOT}/../../../../labs/language/genai/interactions/openapi/genai-next/specs/genai/openapi.with-overlays.json" ]]; then
  SPEC_FILE="${REPO_ROOT}/../../../../labs/language/genai/interactions/openapi/genai-next/specs/genai/openapi.with-overlays.json"
else
  echo "Error: Could not locate OpenAPI spec file." >&2
  exit 1
fi

# Locate Speakeasy config: CLI arg > in GitHub repo (.speakeasy/gen.yaml) > in google3
if [[ -n "${SPEAKEASY_CONFIG_DIR_CLI}" && -d "${SPEAKEASY_CONFIG_DIR_CLI}" ]]; then
  SPEAKEASY_CONFIG_DIR="${SPEAKEASY_CONFIG_DIR_CLI}"
elif [[ -f "${REPO_ROOT}/.speakeasy/gen.yaml" ]]; then
  SPEAKEASY_CONFIG_DIR="${REPO_ROOT}/.speakeasy"
elif [[ -f "${REPO_ROOT}/../../../../labs/language/genai/interactions/openapi/genai-next/dist/sp_python/.speakeasy/gen.yaml" ]]; then
  SPEAKEASY_CONFIG_DIR="${REPO_ROOT}/../../../../labs/language/genai/interactions/openapi/genai-next/dist/sp_python/.speakeasy"
else
  echo "Error: Could not locate Speakeasy configuration." >&2
  exit 1
fi

# Find generator binary: CLI arg > SPEAKEASY_GENERATOR_BIN > path lookups
GENERATOR_BIN="${GENERATOR_BIN_CLI:-${SPEAKEASY_GENERATOR_BIN:-}}"
if [[ -z "${GENERATOR_BIN}" ]]; then
  if command -v generate >/dev/null 2>&1; then
    GENERATOR_BIN="generate"
  elif [[ -x "${HOME}/go/bin/generate" ]]; then
    GENERATOR_BIN="${HOME}/go/bin/generate"
  elif [[ -n "${GOPATH:-}" && -x "${GOPATH}/bin/generate" ]]; then
    GENERATOR_BIN="${GOPATH}/bin/generate"
  elif [[ -x "${REPO_ROOT}/../../../../blaze-bin/third_party/golang/github_com/speakeasy_api/openapi_generation/v/v2/cmd/generate/generate" ]]; then
    # google3: //third_party/golang/github_com/speakeasy_api/openapi_generation/v/v2/cmd/generate
    GENERATOR_BIN="${REPO_ROOT}/../../../../blaze-bin/third_party/golang/github_com/speakeasy_api/openapi_generation/v/v2/cmd/generate/generate"
  else
    echo "Error: Speakeasy generator binary 'generate' not found. Run:" >&2
    echo "  git clone --depth 1 --branch \${SPEAKEASY_VERSION} https://github.com/speakeasy-api/openapi-generation.git /tmp/openapi-generation && (cd /tmp/openapi-generation && go install ./cmd/generate)" >&2
    exit 1
  fi
fi

# Determine target directory: CLI arg > GitHub repo (google/genai/_gaos) > google3 (_gaos)
if [[ -n "${TARGET_GAOS_DIR_CLI}" ]]; then
  TARGET_GAOS_DIR="${TARGET_GAOS_DIR_CLI}"
elif [[ -d "${REPO_ROOT}/google/genai" ]]; then
  TARGET_GAOS_DIR="${REPO_ROOT}/google/genai/_gaos"
elif [[ -d "${REPO_ROOT}/_gaos" || "${REPO_ROOT}" =~ /third_party/py/google/genai$ ]]; then
  TARGET_GAOS_DIR="${REPO_ROOT}/_gaos"
else
  TARGET_GAOS_DIR="${REPO_ROOT}/google/genai/_gaos"
fi

STAGING_DIR="$(mktemp -d -t gaos_gen.XXXXXX)"
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

# Stage .speakeasy config in staging dir
mkdir -p "${STAGING_DIR}/.speakeasy"
cp -r "${SPEAKEASY_CONFIG_DIR}/." "${STAGING_DIR}/.speakeasy/"

GEN_OPTS=("-skip-versioning")
if [[ "${SKIP_COMPILE}" == "true" ]]; then
  GEN_OPTS+=("-skip-compile")
fi

# The generator wants SPEAKEASY_LICENSE_TOKEN to be a signed license JWT. Those
# expire after 30 days, so CI stores a Speakeasy API key instead. If the value
# is not a JWT (header.payload.signature), exchange it for one using the same
# endpoint as the generator's own `./zero` bootstrap
# (internal/licensebootstrap/fetch.go: GET /v1/auth/validate -> license_jwt).
TOKEN_CANDIDATE="${SPEAKEASY_LICENSE_TOKEN:-${SPEAKEASY_API_KEY:-}}"
if [[ -n "${TOKEN_CANDIDATE}" && "${TOKEN_CANDIDATE}" != *.*.* ]]; then
  echo "Exchanging Speakeasy API key for a signed license token..."
  # The key is passed through the environment (not the command line or the
  # script source) so it doesn't show up in the process list or break quoting.
  # -I keeps the current directory off sys.path (e.g. genai/types.py would
  # shadow the stdlib `types` module).
  if ! FETCHED_TOKEN="$(SPEAKEASY_KEY_TO_EXCHANGE="${TOKEN_CANDIDATE}" python3 -I - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

url = "https://app.speakeasy.com/v1/auth/validate"
req = urllib.request.Request(
    url,
    headers={
        "x-api-key": os.environ["SPEAKEASY_KEY_TO_EXCHANGE"],
        "Accept": "application/json",
    },
)
try:
  with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.load(resp)
except urllib.error.HTTPError as e:
  sys.exit(f"Speakeasy license exchange failed: HTTP {e.code} from {url}")
except (urllib.error.URLError, OSError, ValueError) as e:
  sys.exit(f"Speakeasy license exchange failed: {e}")

token = data.get("license_jwt")
if not token:
  sys.exit(
      "Speakeasy license exchange failed: no license_jwt in the response"
      " (is the API key for a workspace with a commercial license?)"
  )
print(token)
PY
  )"; then
    echo "Error: could not get a Speakeasy license token (see above)." >&2
    exit 1
  fi
  export SPEAKEASY_LICENSE_TOKEN="${FETCHED_TOKEN}"
fi

echo "Generating Python GAOS SDK using ${GENERATOR_BIN}..."
"${GENERATOR_BIN}" \
  -s "${SPEC_FILE}" \
  -o "${STAGING_DIR}" \
  -l python \
  "${GEN_OPTS[@]}"

# Locate generated source inside staging dir
SRC_GEN=""
for candidate in "${STAGING_DIR}/src/google/genai" "${STAGING_DIR}/google/genai"; do
  if [[ -d "${candidate}" ]]; then
    SRC_GEN="${candidate}"
    break
  fi
done

if [[ -z "${SRC_GEN}" ]]; then
  echo "Error: Generator did not produce expected output under ${STAGING_DIR}" >&2
  exit 1
fi

SYNC_BIN="${SYNC_GAOS_OUTPUT_BIN_CLI:-${SYNC_GAOS_OUTPUT_BIN:-}}"
SYNC_EXTRA_ARGS=()
if [[ -d "${REPO_ROOT}/google/genai" && ! "${REPO_ROOT}" =~ /third_party/py/google/genai$ ]]; then
  SYNC_EXTRA_ARGS+=("--httpx2-fallback")
fi

echo "Syncing and rewriting imports to ${TARGET_GAOS_DIR}..."
if [[ -n "${SYNC_BIN}" && -x "${SYNC_BIN}" ]]; then
  "${SYNC_BIN}" \
    --input-dir="${SRC_GEN}" \
    --output-dir="${TARGET_GAOS_DIR}" \
    "${SYNC_EXTRA_ARGS[@]}"
elif command -v python3 >/dev/null 2>&1; then
  python3 "${SCRIPT_DIR}/sync_gaos_output.py" \
    --input-dir="${SRC_GEN}" \
    --output-dir="${TARGET_GAOS_DIR}" \
    "${SYNC_EXTRA_ARGS[@]}"
elif command -v python >/dev/null 2>&1; then
  python "${SCRIPT_DIR}/sync_gaos_output.py" \
    --input-dir="${SRC_GEN}" \
    --output-dir="${TARGET_GAOS_DIR}" \
    "${SYNC_EXTRA_ARGS[@]}"
else
  echo "Error: Neither SYNC_GAOS_OUTPUT_BIN nor python3/python found." >&2
  exit 1
fi

echo "GAOS SDK generation finished successfully!"
