#!/usr/bin/env bash
# Verify 16KB page alignment for all .so files in the Android build output.
# Scanner has no custom NDK code — this checks MLKit and RN .so deps bundled
# into the example APK, which must be 16KB-aligned for Android 15+ compatibility.
set -euo pipefail

readelf_cmd=""
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  if command -v llvm-readelf >/dev/null 2>&1; then
    readelf_cmd="llvm-readelf"
  elif command -v readelf >/dev/null 2>&1; then
    readelf_cmd="readelf"
  elif command -v greadelf >/dev/null 2>&1; then
    readelf_cmd="greadelf"
  fi
else
  find_readelf() {
    local candidates=(
      llvm-readelf
      readelf
      greadelf
      /opt/homebrew/opt/llvm/bin/llvm-readelf
      /usr/local/opt/llvm/bin/llvm-readelf
      /opt/homebrew/bin/greadelf
      /usr/local/bin/greadelf
    )
    for candidate in "${candidates[@]}"; do
      if command -v "$candidate" >/dev/null 2>&1; then
        echo "$candidate"
        return 0
      fi
      if [ -x "$candidate" ]; then
        echo "$candidate"
        return 0
      fi
    done
    return 1
  }
  readelf_cmd="$(find_readelf || true)"
fi

if [ -z "$readelf_cmd" ]; then
  echo "ERROR: neither llvm-readelf, readelf, nor greadelf found in PATH" >&2
  if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
    echo "Tip: brew install llvm (llvm-readelf) or binutils (greadelf), or export PATH to include them." >&2
  fi
  exit 1
fi

files=()
if command -v rg >/dev/null 2>&1; then
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(rg --files -g "*.so" example/android/app/build 2>/dev/null || true)
else
  while IFS= read -r line; do
    [ -n "$line" ] && files+=("$line")
  done < <(find example/android/app/build -name "*.so" 2>/dev/null || true)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "NOTE: no .so files found in example/android/app/build — skipping alignment check"
  echo "(build Android first to get a meaningful check)"
  exit 0
fi

failed=()
for so in "${files[@]}"; do
  if ! "$readelf_cmd" -l -W "$so" 2>/dev/null | awk '
    $1=="LOAD" { load=1; if ($NF!="0x4000") bad=1 }
    END { if (!load) exit 2; exit bad }
  '; then
    status=$?
    if [ "$status" -ne 2 ]; then
      failed+=("$so")
    fi
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "ERROR: the following .so files are not 16KB-aligned (expected LOAD alignment 0x4000):" >&2
  for f in "${failed[@]}"; do
    echo "  $f" >&2
    "$readelf_cmd" -l -W "$f" 2>/dev/null | grep -E "LOAD|Align" || true
  done
  exit 1
fi

echo "OK: 16KB alignment verified (${#files[@]} .so file(s) checked)"
