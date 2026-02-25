#!/bin/sh

# Default values
INPUT_FILE=""
GEN_IPV4=1
GEN_IPV6=1
TIMESTAMP=""
DEBUG=0

OUT_IPV4_BASE="IPv4_object_list"
OUT_IPV6_BASE="IPv6_object_list"

# Help message
show_help() {
    cat <<EOF
Usage: $0 -f <input.txt> [options]

Options:
  -f <file>    Specify input text file
  -v4          Generate only IPv4 list
  -v6          Generate only IPv6 list
  -t           Append timestamp (_MM-DD_HH_MM) to output filenames
  -d           Enable debug mode (prints operations)
  -h           Show this help message
  -e           Show examples of usage

Output:
  IPv4 list -> ${OUT_IPV4_BASE}.csv
  IPv6 list -> ${OUT_IPV6_BASE}.csv
EOF
}

# Examples message
show_examples() {
    cat <<EOF
Examples:
  Generate both lists:
    $0 -f "Azure IP Ranges.txt"

  Generate both lists with timestamp and debug:
    $0 -f "Azure IP Ranges.txt" -t -d

  Generate only IPv4 list:
    $0 -f "Azure IP Ranges.txt" -v4

  Generate only IPv6 list:
    $0 -f "Azure IP Ranges.txt" -v6
EOF
}

# Parse flags
while [ $# -gt 0 ]; do
    case "$1" in
        -f)
            INPUT_FILE="$2"
            shift 2
            ;;
        -v4)
            GEN_IPV6=0
            shift
            ;;
        -v6)
            GEN_IPV4=0
            shift
            ;;
        -t)
            TIMESTAMP="_$(date '+%m-%d_%H_%M')"
            shift
            ;;
        -d)
            DEBUG=1
            shift
            ;;
        -h)
            show_help
            exit 0
            ;;
        -e)
            show_examples
            exit 0
            ;;
        *)
            echo "Invalid option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate input file
if [ -z "$INPUT_FILE" ]; then
    echo "Error: Input file not specified. Use -f <file>"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File '$INPUT_FILE' not found."
    exit 1
fi

# Output filenames
OUT_IPV4="${OUT_IPV4_BASE}${TIMESTAMP}.csv"
OUT_IPV6="${OUT_IPV6_BASE}${TIMESTAMP}.csv"

# Clear old files if generating
[ "$GEN_IPV4" -eq 1 ] && : > "$OUT_IPV4"
[ "$GEN_IPV6" -eq 1 ] && : > "$OUT_IPV6"

[ "$DEBUG" -eq 1 ] && echo "Processing file: $INPUT_FILE"
[ "$DEBUG" -eq 1 ] && echo "Output IPv4: $OUT_IPV4"
[ "$DEBUG" -eq 1 ] && echo "Output IPv6: $OUT_IPV6"

current_service="Unknown"
in_prefix_block=0

# Normalize input (remove CR and quotes) and process
tr -d '\r"' < "$INPUT_FILE" | while IFS= read -r line; do
    case "$line" in
        *systemService*)
            # Extract systemService value
            current_service=$(echo "$line" | awk -F'systemService' '{print $2}' | awk -F'[:, ]+' '{print $2}')
            [ "$DEBUG" -eq 1 ] && echo "Detected systemService: $current_service"
            ;;
        *addressPrefixes*)
            in_prefix_block=1
            [ "$DEBUG" -eq 1 ] && echo "Starting addressPrefixes block"
            continue
            ;;
        *platform*|*name*|*id*|*properties*|*region*|*networkFeatures*)
            in_prefix_block=0
            continue
            ;;
    esac

    if [ "$in_prefix_block" -eq 1 ]; then
        for prefix in $line; do
            case "$prefix" in
                *:*)
                    if [ "$GEN_IPV6" -eq 1 ]; then
                        echo "$prefix,Azure,$current_service" >> "$OUT_IPV6"
                        [ "$DEBUG" -eq 1 ] && echo "IPv6 added: $prefix"
                    fi
                    ;;
                */*)
                    if [ "$GEN_IPV4" -eq 1 ]; then
                        echo "$prefix,Azure,$current_service" >> "$OUT_IPV4"
                        [ "$DEBUG" -eq 1 ] && echo "IPv4 added: $prefix"
                    fi
                    ;;
            esac
        done
    fi
done

echo "Done!"
[ "$GEN_IPV4" -eq 1 ] && echo "IPv4 list: $OUT_IPV4"
[ "$GEN_IPV6" -eq 1 ] && echo "IPv6 list: $OUT_IPV6"
