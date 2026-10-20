#!/bin/sh
set -eu

# Xcode supplies the resolved build setting, including command-line overrides.
: "${MARKETING_VERSION:?MARKETING_VERSION is required}"
: "${SCRIPT_INPUT_FILE_0:?The manifest template input is required}"
: "${SCRIPT_OUTPUT_FILE_0:?The generated manifest output is required}"

# WebExtension versions contain one to four integers in the range 0...65535.
# Validate before substitution so the value is also safe inside JSON and sed.
if ! printf '%s\n' "$MARKETING_VERSION" | /usr/bin/awk -F '[.]' '
    NF < 1 || NF > 4 { exit 1 }
    {
        for (i = 1; i <= NF; i++) {
            if ($i !~ /^(0|[1-9][0-9]*)$/ || $i > 65535) exit 1
        }
        if ($0 ~ /^0(\.0)*$/) exit 1
    }
'; then
    echo 'error: MARKETING_VERSION must be a valid WebExtension version.' >&2
    exit 1
fi

# Publish only a complete file; leave the source template untouched.
output="$SCRIPT_OUTPUT_FILE_0"
mkdir -p "$(dirname "$output")"
temporary=$(mktemp "$output.XXXXXX")
trap 'rm -f "$temporary"' EXIT
/usr/bin/sed "s/@MARKETING_VERSION@/$MARKETING_VERSION/g" "$SCRIPT_INPUT_FILE_0" > "$temporary"
mv -f "$temporary" "$output"
