#!/usr/bin/env bash
E=~/.no-mistakes/evidence/01M5TBZCMYY117N0QBSWXWFC3S
W=$(pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
printf 'window=sess:fm-t1\nkind=ship\n' > "$LAB/state/t1.meta"
reset(){ printf 'needs-decision [key=nm-x-review]: ask-user round=1 findings=review-1 file=f\n' > "$LAB/state/t1.status"; rm -rf "$LAB/state/t1.inbox"; }
run(){ reset; echo "=== $1"; echo "msg: $2"
 env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH="$E/fb:$PATH" FM_HOME="$LAB" FM_SEND_SETTLE=0 "$W/bin/fm-send.sh" t1 --resolve-key nm-x-review "$2"; echo "exit=$?"; ls "$LAB/state/t1.inbox" 2>/dev/null | sed 's/^/inbox: /'; }
run S1-closed-list-fix-round 'Ruling: send review-1 to a fix round; add a, b, c.'
run S2-escape-named-in-refusal 'Ruling: approve review-1; do not fix, filed #12.'
run S3-property-none-accepted $'Ruling: approve review-1; do not fix, filed #12.\nProperty: none; this rules no finding fix.'
run S4-control-approve 'Ruling: approve review-1.'
rm -rf "$LAB"
