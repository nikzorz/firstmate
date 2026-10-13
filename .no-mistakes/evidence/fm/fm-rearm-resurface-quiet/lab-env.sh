# Sourced by the live-lab drivers: every firstmate script runs against the lab home only.
lab() {  # <command...>
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE -u HERDR_SESSION \
    TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30 \
    "$@"
}
