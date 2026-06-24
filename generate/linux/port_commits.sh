#!/bin/bash
#
# NAME:
#         port_commits.sh - Port a range of commits from parent ACPICA
#                          git repository into locally cloned Linux kernel
#                          tree
#
# SYNOPSIS:
#         port_commits.sh <-d kernel_dir> <-b branch_name> [-a] <A...B>
#
# DESCRIPTION:
#         Processes a specified range of ACPICA commits and updates the
#         respective files in the given local Linux kernel tree, creating a
#         new branch for the ported updates. The script automatically omits
#         merge commits and changes that are not applicable to the Linux
#         kernel. Optional mode -a enables porting of files that do not yet
#         exist in the kernel tree, placing them according to their original
#         directory structure in the ACPICA repository, with the destination
#         directory being dependent on the path inside ACPICA tree.
#
#         Commits that already appear to be ported are skipped: a kernel
#         commit whose subject mentions "ACPICA" and whose message references
#         the short SHA of the ACPICA commit marks it as already ported.
#
#         Each commit message is rewritten for the kernel: the "ACPICA: "
#         subject prefix, a "Link:" to the original ACPICA commit and a
#         "Signed-off-by:" trailer are added automatically.
#
#         When a converted change does not apply cleanly, the script reports
#         the conflict and offers the same choices as an interactive git
#         rebase:
#           continue - pause to let the conflict be resolved manually (e.g.
#                      in another shell), then resume;
#           skip     - discard this commit's partial changes and move on;
#           abort    - restore the kernel repo to its original state (return
#                      to the previous branch and delete the created branch).
#
#         Parameters:
#         -d      Path to Linux kernel tree, to port into
#         -b      New branch name to create in kernel tree
#         A...B   Range of commits from ACPICA to port into kernel tree.
#
#         Options:
#         -a    Whether to add new files that don't yet exist in the kernel
#         -h    This help message
#

set -o pipefail

KERNEL_DIR=""
BRANCH_NAME=""
ADD_NEW=0
SERIE_CNTR=0
PREFIX="ACPICA"
TOOL_DIR=$(dirname "$(realpath "$0")")

help() {
  cat <<EOF
help:
  $0 <-d kernel_dir> <-b branch_name> [-a] <A...B>

Parameters:
  -d      Path to Linux kernel tree, to port into
  -b      New branch name to create in kernel tree
   A...B  Range of commits from ACPICA to port into kernel tree

Options:
  -a    Whether to add new files that don't yet exist in the kernel
  -h    This help message
EOF
}

declare -A DEST_DIRS=(
  ["source/include"]="include/acpi"
  ["source/components/debugger"]="drivers/acpi/acpica"
  ["source/components/disassembler"]="drivers/acpi/acpica"
  ["source/components/dispatcher"]="drivers/acpi/acpica"
  ["source/components/events"]="drivers/acpi/acpica"
  ["source/components/executer"]="drivers/acpi/acpica"
  ["source/components/hardware"]="drivers/acpi/acpica"
  ["source/components/namespace"]="drivers/acpi/acpica"
  ["source/components/parser"]="drivers/acpi/acpica"
  ["source/components/resources"]="drivers/acpi/acpica"
  ["source/components/tables"]="drivers/acpi/acpica"
  ["source/components/utilities"]="drivers/acpi/acpica"
  ["source/os_specific/service_layers"]="tools/power/acpi/os_specific/service_layers"
  ["source/common"]="tools/power/acpi/common"
  ["source/tools/acpidump"]="tools/power/acpi/tools/acpidump"
)

while getopts ":d:b:ah" opt; do
  case ${opt} in
    d ) KERNEL_DIR="$OPTARG" ;;
    b ) BRANCH_NAME="$OPTARG" ;;
    a ) ADD_NEW=1 ;;
    h ) help; exit 0 ;;
    \? ) echo "Invalid option: -$OPTARG" >&2; help; exit 1 ;;
  esac
done

# Remove parsed options from "$@"
shift $((OPTIND - 1))

if [ $# -lt 1 ]; then
  echo "Error: Not specified a range of commits to process."
  echo "Usage: $0 [options] <A...B>"
  exit 1
fi

RANGE="$1"

if ! [[ $RANGE =~ ^[^[:space:]]+\.\.[^[:space:]]+$ ]]; then
  echo "Error: Invalid range of commits to process: ${RANGE}"
  echo "Usage: $0 [options] <A...B>"
  exit 1
fi

if [[ -z "${KERNEL_DIR}" || -z "${BRANCH_NAME}" ]]; then
  echo "Error: values for parameters -d, -b are required."
  help
  exit 1
fi

PARENT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${PARENT_DIR}" ]]; then
  echo "Error: Not in the ACPICA repo."
  exit 2
fi

ACPISRC="${PARENT_DIR}/generate/unix/bin/acpisrc"
if [[ ! -x "${ACPISRC}" ]]; then
  echo "Error: acpisrc not found: ${ACPISRC}"
  exit 2
fi

if ! command -v clang-format >/dev/null 2>&1; then
  echo "Error: clang-format not found in PATH."
  exit 2
fi

TOP_DIR="$(dirname "${PARENT_DIR}")"
SUFFIX="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)"
TMP_ACPICA="${TOP_DIR}/acpica_${SUFFIX}"
TMP_WORK="/dev/shm/port_commits_${SUFFIX}"
mkdir -p "${TMP_WORK}"

# From now on, if anything goes wrong, delete the temporary working directory
# and the temporary working files
cleanup() {
  rm -rf "${TMP_ACPICA}" >/dev/null 2>&1 || true
  rm -rf "${TMP_WORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git clone "${PARENT_DIR}" "${TMP_ACPICA}" > /dev/null 2>&1 || {
  echo "Error: cloning into temp acpica folder failed."
  exit 2
}

cd "${TMP_ACPICA}"

mapfile -t COMMITS < <(git rev-list --reverse --topo-order $RANGE)
if [[ "${#COMMITS[@]}" -eq 0 ]]; then
  echo "Error: could not get list of commits"
  exit 2
fi

cd "${KERNEL_DIR}"

if git show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
  echo "Error: branch already exists ${BRANCH_NAME}"
  exit 2
fi

# Remember the branch we started on, so an abort can restore it.
ORIG_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse HEAD)"

# Restore the kernel repo to the state before porting: discard any work tree
# changes, return to the original branch and delete the branch we created.
abort_port() {
  echo "Aborting: restoring kernel repo to its state before porting."
  cd "${KERNEL_DIR}"
  git reset --hard >/dev/null 2>&1 || true
  git checkout -- . >/dev/null 2>&1 || true
  git checkout -q "${ORIG_BRANCH}" >/dev/null 2>&1 || true
  git branch -D "${BRANCH_NAME}" >/dev/null 2>&1 || true
}

# Discard any partial changes from the current commit and clean up leftovers.
skip_current_commit() {
  cd "${KERNEL_DIR}"
  git reset --hard >/dev/null 2>&1 || true
  find . -type f -name "*.rej" -delete
  find . -type f -name "*.orig" -delete
}

git checkout -b "${BRANCH_NAME}" >/dev/null

# Build the "already ported" lookup once, instead of scanning the whole kernel
# history with `git log --grep` for every commit in the range. We walk the
# kernel history a single time, pick commits whose subject mentions ACPICA, and
# record every short SHA (>=8 hex) referenced in their message, mapped to the
# kernel commit that ported it. Per-commit lookup below is then O(1).
echo "Indexing already-ported ACPICA commits in ${KERNEL_DIR}..."
declare -A PORTED
while IFS=$'\t' read -r prefix khash; do
  [[ -n "${prefix}" ]] && PORTED["${prefix}"]="${khash}"
done < <(
  git -C "${KERNEL_DIR}" log --no-merges -z --format='%H%n%s%n%b' 2>/dev/null \
  | LC_ALL=C awk 'BEGIN { RS="\0" }
    {
      nl1 = index($0, "\n")
      khash = substr($0, 1, nl1 - 1)
      rest = substr($0, nl1 + 1)
      nl2 = index(rest, "\n")
      subject = (nl2 ? substr(rest, 1, nl2 - 1) : rest)
      if (index(subject, "ACPICA") == 0) next
      # Record the first 8 chars of every hex token in subject+body.
      s = rest
      while (match(s, /[0-9a-f]{8,40}/)) {
        print substr(s, RSTART, 8) "\t" khash
        s = substr(s, RSTART + RLENGTH)
      }
    }'
)

for CMT in "${COMMITS[@]}"; do
  ANYTHING_REJECTED=0
  ANYTHING_TO_ADD=0
  SKIP_COMMIT=0

  cd "${TMP_ACPICA}"

  # Skip merge commits (preserve original check but don't abort)
  PARENT_COUNT="$(git rev-list --parents -n 1 "${CMT}" | awk '{print NF-1}')"
  if [[ "${PARENT_COUNT}" -ne 1 ]]; then
    echo "Commit ${CMT}: is a merge commit (parents: ${PARENT_COUNT}), skipping."
    continue
  fi

  # Skip commits already ported: a kernel commit whose subject mentions ACPICA
  # and whose message contains the 8-char SHA of this ACPICA commit.
  CMT_SHORT="${CMT:0:8}"
  ALREADY_PORTED="${PORTED[${CMT_SHORT}]:-}"
  if [[ -n "${ALREADY_PORTED}" ]]; then
    echo "Commit ${CMT}: already ported as kernel commit ${ALREADY_PORTED:0:12}, skipping."
    continue
  fi

  git checkout -- .
  git checkout -q "${CMT}"

  # Automatically edit the commit message
  MESSAGE_SUBJECT="$(git log -1 $CMT --format='%s')"
  MESSAGE_OLD="$(git log -1 "$CMT" --format='%b' | tr -d '\r')"
  MESSAGE_TRAILERS="$(git log -1 $CMT --format='%B' | git interpret-trailers --parse)"
  MESSAGE_AUTHOR="$(git log -1 $CMT --format='%aN <%aE>')"

  if [[ -n "$PREFIX" && "$MESSAGE_SUBJECT" != "$PREFIX"* ]]; then
      MESSAGE_SUBJECT="${PREFIX}: ${MESSAGE_SUBJECT}"
  fi

  MESSAGE_NEW="${MESSAGE_SUBJECT}"$'\n\n'"$(printf '%s' "${MESSAGE_OLD/$MESSAGE_TRAILERS/}" | fmt -s)"

  # If the block doesn't end with new line, add two, so the "Link" doesn't stick to the body
  if [[ $MESSAGE_NEW != *$'\n' ]]; then
    MESSAGE_NEW+=$'\n\n'
  fi

  mapfile -t FIXED < <(
    awk '
      /^Fixes/ {
        if (match($0, /[0-9a-f]{7,40}/, m))
          print m[0]
      }
    ' <<< "$MESSAGE_TRAILERS"
  )

  MESSAGE_NEW+="Link: https://github.com/acpica/acpica/commit/${CMT:0:12}"$'\n'
  MESSAGE_NEW+="${MESSAGE_TRAILERS}"

  for FIX in "${FIXED[@]}"; do
    if ! git -C "${KERNEL_DIR}" cat-file -e "${FIX}^{commit}" 2>/dev/null; then
      MESSAGE_NEW="$(
        sed -E "s/\b${FIX}\b/INVALID_COMMIT/g" <<< "$MESSAGE_NEW"
      )"
    fi
  done

  SIGNED_OFF_BY="Signed-off-by: $(git config user.name) <$(git config user.email)>"

  if ! grep -Fq "$SIGNED_OFF_BY" <<< "$MESSAGE_NEW"; then
      MESSAGE_NEW+=$'\n'"${SIGNED_OFF_BY}"
  fi
  # End of message processing

  # List of changed files
  mapfile -t CHANGED_FILES < <(git diff-tree --no-commit-id --name-status -r "${CMT}" \
    | awk '$1=="A" || $1=="M" {print $2}')

  if [[ "${#CHANGED_FILES[@]}" -eq 0 ]]; then
    echo "Commit ${CMT}: No added/modified files, skipping."
    continue
  fi

  for FILE in "${CHANGED_FILES[@]}"; do
    SRC="${TMP_ACPICA}/${FILE}"
    SRC_DIR="$(dirname -- "$FILE")"
    FILE_NAME="$(basename -- "$FILE")"
    DEST=""

    for key in "${!DEST_DIRS[@]}"; do
      DST_REL="${DEST_DIRS[$key]}"
      KERNEL_COUNTERPART="${KERNEL_DIR}/${DST_REL}/${FILE_NAME}"
      if [[ -f "$KERNEL_COUNTERPART" ]]; then
        DEST="$KERNEL_COUNTERPART"
        break
      fi
    done

    if [[ -z "$DEST" ]]; then
      if [[ "${ADD_NEW}" != 0 && -n "${DEST_DIRS[$SRC_DIR]+_}" ]]; then
        DST_REL="${DEST_DIRS[$SRC_DIR]}"
        DEST="${KERNEL_DIR}/${DST_REL}/${FILE_NAME}"
      fi

      if [[ -z "$DEST" ]]; then
        continue
      fi
    fi

    if ! git -C "$KERNEL_DIR" diff --quiet -- "$DEST"; then
      echo "Warning: destination has uncommitted changes, aborting: ${DEST}"
      exit 1
    fi

    ANYTHING_TO_ADD=1

    TMP_CURRENT=$(mktemp -p "${TMP_WORK}" current_XXXXXX_${FILE_NAME})
    TMP_PARENT=$(mktemp -p "${TMP_WORK}" parent_XXXXXX_${FILE_NAME})

    cd "${TMP_ACPICA}"

    if ! git cat-file -p "${CMT}:${FILE}" > "$TMP_CURRENT" 2>/dev/null; then
      echo "Warning: ${FILE} not found at ${CMT}! Skipping."
      rm -f "$TMP_CURRENT" "$TMP_PARENT" >/dev/null 2>&1 || true
      continue
    fi

    if ! git cat-file -p "${CMT}^:${FILE}" > "$TMP_PARENT" 2>/dev/null; then
        cat /dev/null > "$TMP_PARENT"
        echo "Note: No parent file found for ${CMT}. New addition?"
    fi

    "${ACPISRC}" -ldqy "$TMP_PARENT" > /dev/null
    "${ACPISRC}" -ldqy "$TMP_CURRENT" > /dev/null
    clang-format -i --style="file:${TOOL_DIR}/clang-format" "$TMP_PARENT"
    clang-format -i --style="file:${TOOL_DIR}/clang-format" "$TMP_CURRENT"

    DEST_DIR="$(dirname -- "$DEST")"
    DIFF_RESULT=$(diff --normal -E -p -w -B -b "$TMP_PARENT" "$TMP_CURRENT" || true)
    if [ -n "$DIFF_RESULT" ]; then
        # Probe first: does the patch apply cleanly without touching the tree?
        if patch -l -n -F 4 -f --dry-run -d "${DEST_DIR}" "$FILE_NAME" <<< "$DIFF_RESULT" >/dev/null 2>&1; then
            patch -l -n -F 4 -d "${DEST_DIR}" "$FILE_NAME" <<< "$DIFF_RESULT"
        else
            echo "Conflict: patch does not apply cleanly to ${DEST}:"
            patch -l -n -F 4 -f --dry-run -d "${DEST_DIR}" "$FILE_NAME" <<< "$DIFF_RESULT" || true
            # Offer the same choices as 'git rebase' on a conflict.
            while true; do
                read -p "Choose: [c]ontinue / [s]kip / [a]bort: " ans < /dev/tty
                case "${ans}" in
                    c|continue )
                        # Apply best-effort (may leave .rej). The user resolves
                        # the conflict manually at the post-loop pause below.
                        patch -l -n -F 4 -d "${DEST_DIR}" "$FILE_NAME" <<< "$DIFF_RESULT" || true
                        ANYTHING_REJECTED=1
                        break ;;
                    s|skip )
                        SKIP_COMMIT=1
                        break ;;
                    a|abort )
                        abort_port
                        exit 1 ;;
                    * )
                        echo "Please answer c, s or a." ;;
                esac
            done
        fi
    else
        echo "Warning: no changes applied on ${DEST}!"
    fi

    rm -f "$TMP_CURRENT" "$TMP_PARENT" >/dev/null 2>&1 || true

    if [[ "${SKIP_COMMIT}" != 0 ]]; then
        break
    fi

    cd "${KERNEL_DIR}"
    git add "${DEST}"
  done

  # If 'continue' was chosen on a conflict, pause so the user can resolve the
  # leftover .rej files manually, offering the same skip/abort choices again.
  if [[ "${SKIP_COMMIT}" == 0 && "${ANYTHING_REJECTED}" != 0 ]]; then
    cd "${KERNEL_DIR}"
    echo "Warning! Check the .rej files if any, and apply changes manually before resuming."
    # Offer the same choices as 'git rebase' on a conflict.
    while true; do
      read -p "Choose: [c]ontinue / [s]kip / [a]bort: " ans < /dev/tty
      case "${ans}" in
        c|continue )
          echo "Continuing..."
          find . -type f -name "*.rej" -delete
          find . -type f -name "*.orig" -delete
          break ;;
        s|skip )
          SKIP_COMMIT=1
          break ;;
        a|abort )
          abort_port
          exit 1 ;;
        * )
          echo "Please answer c, s or a." ;;
      esac
    done
  fi

  # Skip requested (either at the conflict prompt or the post-loop pause):
  # discard any partial changes from this commit and move on to the next one.
  if [[ "${SKIP_COMMIT}" != 0 ]]; then
    skip_current_commit
    echo "Commit ${CMT}: skipped on conflict."
    continue
  fi

  if [[ "${ANYTHING_TO_ADD}" != 0 ]]; then
    if git commit --author="${MESSAGE_AUTHOR}" -m "${MESSAGE_NEW}" >> "${TMP_WORK}/log.txt" 2>&1; then
      ((SERIE_CNTR++))
      echo "Commit ${CMT}: ported and committed to '${BRANCH_NAME}'."
    else
      echo "Warning: Commit ${CMT}: Failed!"
    fi
  else
    echo "Commit ${CMT}: no kernel relevant changes to port, skipping."
  fi
done

echo "Branch '${BRANCH_NAME}' created in ${KERNEL_DIR}. Processed ${#COMMITS[@]} commit(s) from ACPICA, ported ${SERIE_CNTR}."
