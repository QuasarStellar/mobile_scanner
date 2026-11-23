#!/usr/bin/env bash
set -euo pipefail

# Computes, validates, or applies the devolution fork version (`<upstream>+devolution.<N>`)
# and matching git tag (`v<upstream>-devolution.<N>`).

MODE="${1:---check}"

if [[ "$MODE" != "--check" && "$MODE" != "--apply" ]]; then
  echo "[ERROR] Usage: $0 [--check|--apply]" >&2
  exit 2
fi

if ! grep -qE '^version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' pubspec.yaml; then
  echo "[ERROR] Could not parse semantic version from pubspec.yaml" >&2
  exit 1
fi

CURRENT_VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' pubspec.yaml | head -n1)"
BASE_VERSION="${CURRENT_VERSION%%+devolution.*}"
BASE_VERSION="${BASE_VERSION%%+*}"

if git tag --points-at HEAD "v${BASE_VERSION}-devolution.*" | grep -q .; then
  EXISTING_TAG="$(git tag --points-at HEAD "v${BASE_VERSION}-devolution.*" | head -n1)"
  echo "[OK] HEAD already tagged with ${EXISTING_TAG} (pubspec.yaml: ${CURRENT_VERSION})"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "changed=false" >> "$GITHUB_OUTPUT"
    echo "tag=${EXISTING_TAG}" >> "$GITHUB_OUTPUT"
    echo "version=${CURRENT_VERSION}" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

NEEDS_COMMIT="false"
TARGET_VERSION=""
TARGET_TAG=""

if [[ "$CURRENT_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+devolution\.([0-9]+)$ ]]; then
  PARSED_BASE="${BASH_REMATCH[1]}"
  PARSED_NUM="${BASH_REMATCH[2]}"
  CANDIDATE_TAG="v${PARSED_BASE}-devolution.${PARSED_NUM}"
  if ! git rev-parse -q --verify "refs/tags/${CANDIDATE_TAG}" >/dev/null 2>&1; then
    TARGET_VERSION="$CURRENT_VERSION"
    TARGET_TAG="$CANDIDATE_TAG"
  fi
fi

if [[ -z "$TARGET_VERSION" ]]; then
  MAX_NUM=0
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    num="${tag##*devolution.}"
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num > MAX_NUM )); then
      MAX_NUM="$num"
    fi
  done < <(git tag -l "v${BASE_VERSION}-devolution.*")

  NEXT_NUM=$((MAX_NUM + 1))
  TARGET_VERSION="${BASE_VERSION}+devolution.${NEXT_NUM}"
  TARGET_TAG="v${BASE_VERSION}-devolution.${NEXT_NUM}"
  NEEDS_COMMIT="true"
fi

echo "[INFO] current=${CURRENT_VERSION} target_version=${TARGET_VERSION} target_tag=${TARGET_TAG} needs_commit=${NEEDS_COMMIT}"

if [[ "$MODE" == "--check" ]]; then
  echo "[WARNING] HEAD is not tagged for devolution release (${TARGET_TAG})"
  exit 1
fi

if [[ "$NEEDS_COMMIT" == "true" ]]; then
  python3 -c '
import pathlib, re, sys
p = pathlib.Path("pubspec.yaml")
text = p.read_text(encoding="utf-8")
new_text, count = re.subn(r"^(version:\s*)(\S+)", r"\g<1>" + sys.argv[1], text, count=1, flags=re.M)
if count != 1:
    sys.exit("Failed to update version in pubspec.yaml")
p.write_text(new_text, encoding="utf-8")
' "$TARGET_VERSION"

  git add pubspec.yaml
  git commit -m "chore(devolution): release ${TARGET_VERSION}"
fi

git tag -a "$TARGET_TAG" -m "Release ${TARGET_VERSION}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "changed=true" >> "$GITHUB_OUTPUT"
  echo "committed=${NEEDS_COMMIT}" >> "$GITHUB_OUTPUT"
  echo "tag=${TARGET_TAG}" >> "$GITHUB_OUTPUT"
  echo "version=${TARGET_VERSION}" >> "$GITHUB_OUTPUT"
fi

echo "[OK] Prepared ${TARGET_VERSION} (${TARGET_TAG})"
