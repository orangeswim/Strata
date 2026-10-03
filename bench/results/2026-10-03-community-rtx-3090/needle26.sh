#!/bin/bash
set -eo pipefail

# The 26-needle retrieval suite of bench/results/2026-10-03-community-rtx-3090.
# 1) Insert 26 needles ([SECRET: WORD-KEY-nnnnn]) at even, seed-shuffled depths in a
#    plain-text corpus trimmed to the target token count, plus one fact-check paragraph
#    at 60% depth if the trim dropped it
# 2) Ask the model for all keys as a JSON array (greedy, thinking off) - the cold run
# 3) Re-send the prompt with 36 appended tokens - the cached follow-up
#
# HAYSTACK1/2/3 are any large plain-text corpus files (ours are wiki text; the three
# are concatenated and trimmed, so anything with enough text works).
#
# Usage: HAYSTACK1=... HAYSTACK2=... HAYSTACK3=... needle26.sh [--host H] [--port P]
#        [--tokens N] [--seed S] [--temp T]

PORT=8080
HOST="127.0.0.1"
API_KEY=""
CHARS_PER_TOKEN=3.27
TARGET_TOKENS=20000
SEED=42
TEMP=0
TOP_P=1.0
TOP_K=0
MAX_OUTPUT_TOKENS=512
HAYSTACK1="${HAYSTACK1:?set HAYSTACK1/2/3 to plain-text corpus files}"
HAYSTACK2="${HAYSTACK2:?}"
HAYSTACK3="${HAYSTACK3:?}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --tokens) TARGET_TOKENS="$2"; shift 2 ;;
        --seed) SEED="$2"; shift 2 ;;
        --temp) TEMP="$2"; shift 2 ;;
        --top-p) TOP_P="$2"; shift 2 ;;
        --top-k) TOP_K="$2"; shift 2 ;;
        *) shift ;;
    esac
done
CHAT_URL="http://$HOST:$PORT/v1/chat/completions"
AUTH=()
[[ -n "$API_KEY" ]] && AUTH=(-H "Authorization: Bearer $API_KEY")
curl -sf "http://$HOST:$PORT/health" > /dev/null

# 26 NATO words; needle values seeded, insertion order a seeded Fisher-Yates shuffle
WORDS=(ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA JULIET KILO LIMA MIKE NOVEMBER OSCAR PAPA QUEBEC ROMEO SIERRA TANGO UNIFORM VICTORY WHISKEY XRAY YANKEE ZULU)
N=${#WORDS[@]}
RANDOM=$SEED
NEEDLES=()
for i in $(seq 0 $((N - 1))); do
    NEEDLES+=("${WORDS[$i]}-KEY-$((RANDOM % 90000 + 10000))")
done
RANDOM=$SEED
INDICES=($(seq 0 $((N - 1))))
for i in $(seq $((N - 1)) -1 1); do
    J=$((RANDOM % (i + 1)))
    TMP=${INDICES[$J]}; INDICES[$J]=${INDICES[$i]}; INDICES[$i]=$TMP
done

# haystack: the three corpora concatenated (repeated if short), trimmed to size
TARGET_CHARS=$(awk "BEGIN {printf \"%.0f\", $TARGET_TOKENS * $CHARS_PER_TOKEN}")
BIGFILE=$(mktemp); COMBO=$(mktemp); HAYFILE=$(mktemp); PROMPTFILE=$(mktemp); ESC=$(mktemp); BODY=$(mktemp)
trap 'rm -f "$BIGFILE" "$COMBO" "$HAYFILE" "$PROMPTFILE" "$ESC" "$BODY"' EXIT
cat "$HAYSTACK1" "$HAYSTACK3" "$HAYSTACK2" > "$BIGFILE"
COMBINED=$(wc -c < "$BIGFILE")
if [[ "$COMBINED" -lt "$TARGET_CHARS" ]]; then
    REPEATS=$(awk "BEGIN {printf \"%.0f\", ($TARGET_CHARS / $COMBINED) + 1}")
    for i in $(seq 1 "$REPEATS"); do cat "$BIGFILE" >> "$COMBO"; done
    mv "$COMBO" "$BIGFILE"
fi
head -c "$TARGET_CHARS" "$BIGFILE" | iconv -f UTF-8 -t UTF-8 -c > "$HAYFILE"

# the fact-check paragraph (asked about in the follow-up), inserted at 60% if absent
FACTCHECK_TEXT="On 3 June 2026, the [[United States House of Representatives|US House]] passed an act with a vote of 215-208 requiring the United States' war efforts to cease or gain approval from Congress to continue fighting.<ref>{{cite news |date=3 June 2026 |title= House Passes Measure to End Iran War, a Rebuke of President |url= https://www.nytimes.com/live/2026/06/03/us/trump-administration-news?smid=nytcore-ios-share|url-status=live|access-date=3 June 2026 |work=[[NYT]]}}</ref>"
if ! grep -qF "215-208" "$HAYFILE"; then
    ACTUAL_CHARS=$(wc -c < "$HAYFILE")
    INSERT_AT=$(awk "BEGIN {printf \"%.0f\", $ACTUAL_CHARS * 0.60}")
    BEFORE=$(mktemp); AFTER=$(mktemp)
    head -c "$INSERT_AT" "$HAYFILE" > "$BEFORE"
    tail -c "+$((INSERT_AT + 1))" "$HAYFILE" > "$AFTER"
    { cat "$BEFORE"; echo -e "\n\n${FACTCHECK_TEXT}\n\n"; cat "$AFTER"; } > "$HAYFILE.new"
    mv "$HAYFILE.new" "$HAYFILE"; rm -f "$BEFORE" "$AFTER"
fi

# needles at even depths, inserted back-to-front so earlier offsets stay valid
ACTUAL_CHARS=$(wc -c < "$HAYFILE")
SORTED=$(mktemp)
for p in $(seq 0 $((N - 1))); do
    NI=${INDICES[$p]}
    POS=$(awk "BEGIN {printf \"%.0f\", $ACTUAL_CHARS * ($p + 1) / ($N + 1)}")
    echo "$POS ${NEEDLES[$NI]}" >> "$SORTED"
done
sort -t' ' -k1 -rn "$SORTED" | while read -r POS NEEDLE; do
    BEFORE=$(mktemp); AFTER=$(mktemp)
    head -c "$POS" "$HAYFILE" > "$BEFORE"
    tail -c "+$((POS + 1))" "$HAYFILE" > "$AFTER"
    { cat "$BEFORE"; echo -e "\n\n[SECRET: ${NEEDLE}]\n\n"; cat "$AFTER"; } > "$HAYFILE.new"
    mv "$HAYFILE.new" "$HAYFILE"
    rm -f "$BEFORE" "$AFTER"
done
rm -f "$SORTED"

TASK='Find all secret keys inside [SECRET: ...] markers in the document. Return JSON only as an array: ["secretValue1", ...] Only include keys you are confident in remembering. Do not return markdown.'
{ echo -n "$TASK"; echo -n '\n\nBEGIN_DOCUMENT\n'; cat "$HAYFILE"; echo -n '\nEND_DOCUMENT\n\n'"$TASK"; } > "$PROMPTFILE"
python3 -c "
import json, sys
open(sys.argv[2], 'w', encoding='utf-8').write(json.dumps(open(sys.argv[1], encoding='utf-8', errors='replace').read())[1:-1])
" "$PROMPTFILE" "$ESC"

# ---- request 1: the cold retrieval run ----
{
    printf '{"model":"local","messages":[{"role":"system","content":"You are a precise retrieval assistant."},{"role":"user","content":"'
    cat "$ESC"
    printf '"}],"temperature":%s,"top_p":%s,"top_k":%s,"max_tokens":%d,"stream":false,"chat_template_kwargs":{"enable_thinking":false}}\n' \
        "$TEMP" "$TOP_P" "$TOP_K" "$MAX_OUTPUT_TOKENS"
} > "$BODY"
RESP1=$(curl -sf -X POST "$CHAT_URL" -H "Content-Type: application/json" "${AUTH[@]}" -d @"$BODY" --max-time 900)
echo "input_tokens=$(echo "$RESP1" | jq '.usage.prompt_tokens') cached=$(echo "$RESP1" | jq '.usage.prompt_tokens_details.cached_tokens // 0')"
echo "prompt_ms=$(echo "$RESP1" | jq -r '.timings.prompt_ms | round') prefill_tok_s=$(echo "$RESP1" | jq -r '.timings.prompt_per_second | round')"
echo "output_tokens=$(echo "$RESP1" | jq '.usage.completion_tokens') decode_ms=$(echo "$RESP1" | jq -r '.timings.predicted_ms | round') decode_tok_s=$(echo "$RESP1" | jq '.timings.predicted_per_second')"
ANSWER1=$(echo "$RESP1" | jq -r '.choices[0].message.content')

FOUND=0; RESULTS=(); MISSED=()
for p in $(seq 0 $((N - 1))); do
    NI=${INDICES[$p]}
    NEEDLE="${NEEDLES[$NI]}"
    if echo "$ANSWER1" | grep -qi "$NEEDLE"; then
        RESULTS+=("found"); FOUND_COUNT=$((FOUND + 1)); FOUND=$FOUND_COUNT
    else
        RESULTS+=("miss"); MISSED+=("slot${p}@$(awk "BEGIN {printf \"%d\", ($p + 1) * 100 / ($N + 1)}"):${NEEDLE}")
    fi
done
echo "needles=${FOUND}/${N} (${RESULTS[*]})"
[[ ${#MISSED[@]} -gt 0 ]] && echo "missed: ${MISSED[*]}"

# ---- request 2: the cached follow-up ----
FOLLOWUP="What was the vote count in Y-N format when House Passes Measure to End Iran War and what was the date?"
ANS_ESC=$(ANSWER1="$ANSWER1" python3 -c "
import json, os, sys
open(sys.argv[1], 'w', encoding='utf-8').write(json.dumps(os.environ['ANSWER1'])[1:-1])
" "$BODY.ans")
{
    printf '{"model":"local","messages":[{"role":"system","content":"You are a precise retrieval assistant."},{"role":"user","content":"'
    cat "$ESC"
    printf '"},{"role":"assistant","content":"'
    cat "$BODY.ans"
    printf '"},{"role":"user","content":"%s"}],"temperature":%s,"top_p":%s,"top_k":%s,"max_tokens":256,"stream":false,"chat_template_kwargs":{"enable_thinking":false}}\n' \
        "$FOLLOWUP" "$TEMP" "$TOP_P" "$TOP_K"
} > "$BODY"
RESP2=$(curl -sf -X POST "$CHAT_URL" -H "Content-Type: application/json" "${AUTH[@]}" -d @"$BODY" --max-time 900)
rm -f "$BODY.ans"
echo "followup: input_tokens=$(echo "$RESP2" | jq '.usage.prompt_tokens') cached=$(echo "$RESP2" | jq '.usage.prompt_tokens_details.cached_tokens // 0') prompt_ms=$(echo "$RESP2" | jq -r '.timings.prompt_ms | round')"
ANSWER2=$(echo "$RESP2" | jq -r '.choices[0].message.content')
if echo "$ANSWER2" | grep -qi "215-208\|215–208" && echo "$ANSWER2" | grep -qi "3 June 2026\|June 3, 2026"; then
    echo "fact_check=CORRECT"
else
    echo "fact_check=INCORRECT: $ANSWER2"
fi
