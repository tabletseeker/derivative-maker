#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose

if [[ -z "${RELEASE_TAG:-}" ]]; then
  echo "ERROR: RELEASE_TAG environment variable is not defined." >&2
  exit 1
fi

notes_dir="${RUNNER_TEMP}/release-notes"
current_body="${RUNNER_TEMP}/release-body-current.md"
updated_body="${RUNNER_TEMP}/release-body-updated.md"
pattern='^<!-- matrix-build:.* -->$'

mkdir -p "${notes_dir}"

echo "Checking for matrix release note assets..."
# Check if any release notes exist on the release
note_count="$(
  gh release view "${RELEASE_TAG}" \
    --json assets \
    --jq '[.assets[].name | select(endswith("-release-notes.md"))] | length'
)"

if [[ "${note_count}" == "0" ]]; then
  echo "No release notes found to append. Exiting cleanly."
  exit 0
fi

echo "Found ${note_count} asset(s). Downloading..."
# Download the assets directly inside the script
gh release download "${RELEASE_TAG}" \
  --pattern '*-release-notes.md' \
  --dir "${notes_dir}"

# Read current body layout
gh release view "${RELEASE_TAG}" \
  --json body \
  --template '{{.body}}' > "${current_body}"
cp "${current_body}" "${updated_body}"

mapfile -d '' -t note_files < <(
  find "${notes_dir}" -maxdepth 1 -type f \
    -name '*-release-notes.md' -print0 | sort -z
)

for note_file in "${note_files[@]}"; do
  marker="$(head -n 1 "${note_file}")"

  if [[ ! "${marker}" =~ ${pattern} ]]; then
    echo "ERROR: Missing build marker in ${note_file}" >&2
    exit 1
  fi

  if grep -Fq -- "${marker}" "${updated_body}"; then
    echo "Already included: ${marker}"
    continue
  fi

  printf '\n\n---\n\n' >> "${updated_body}"
  cat "${note_file}" >> "${updated_body}"
done

# Push updates up if changes were made
if ! cmp -s "${current_body}" "${updated_body}"; then
  echo "Changes detected. Updating release description..."
  gh release edit "${RELEASE_TAG}" \
    --notes-file "${updated_body}" \
    --prerelease=false
else
  echo "No new build notes to append."
fi

