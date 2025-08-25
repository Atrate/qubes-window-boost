#!/bin/bash --posix

# ------------------------------------------------------------------------------
# Copyright (C) 2025 Atrate
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# This script is designed for QubesOS. It automatically reads the current
# focused window's parent VM and pins the VM to all CPU cores (or to performance
# cores, this only needs one line's worth of changes). The assumption is that
# all VMs are by default pinned to E-cores on asymmetrical CPUs and they get
# given access to all cores when in focus for additional snappiness and
# performance. See https://forum.qubes-os.org/t/cpu-pinning-alder-lake/17949 for
# information on how to set up the prerequisite core pinning required for this
# script to run well.
# --------------------
# Version: 0.9.0
# --------------------
# Exit code listing:
#   0: All good
#   1: Unspecified
#   2: Error in environment configuration or arguments
# ------------------------------------------------------------------------------

## -----------------------------------------------------------------------------
## SECURITY SECTION
## NO EXECUTABLE CODE CAN BE PRESENT BEFORE THIS SECTION
## -----------------------------------------------------------------------------

# Set POSIX-compliant mode for security and unset possible overrides
# NOTE: This does not mean that we are restricted to POSIX-only constructs
# ------------------------------------------------------------------------
POSIXLY_CORRECT=1
set -o posix
readonly POSIXLY_CORRECT
export POSIXLY_CORRECT

# Set IFS explicitly. POSIX does not enforce whether IFS should be inherited
# from the environment, so it's safer to set it expliticly
# --------------------------------------------------------------------------
IFS=$' \t\n'
export IFS

# ------------------------------------------------------------------------------
# For additional security, you may want to specify hard-coded values for:
#   SHELL, PATH, HISTFILE, ENV, BASH_ENV
# They will be made read-only by set -r later in the script.
# ------------------------------------------------------------------------------

# Populate this array with **all** commands used in the script for security.
# The following builtins do not need to be included, POSIX mode handles that:
# break : . continue eval exec exit export readonly return set shift trap unset
# The following keywords are also supposed not to be overridable in bash itself
# ! case  coproc  do done elif else esac fi for function if in
# select then until while { } time [[ ]]
# ------------------------------------------------------------------------------
UTILS=(
    '['
    '[['
    'awk'
    'cat'
    'command'
    'declare'
    'echo'
    'false'
    'getopt'
    'grep'
    'hash'
    'local'
    'logger'
    'pgrep'
    'read'
    'stdbuf'
    'tee'
    'true'
    'stdbuf'
    'xl'
    'xargs'
    'xprop'
)

# Unset all commands used in the script - prevents exported functions
# from overriding them, leading to unexpected behavior
# -------------------------------------------------------------------
for util in "${UTILS[@]}"
do
    \unset -f -- "$util"
done

# Clear the command hash table
# ----------------------------
hash -r

# Set up fd 3 for discarding output, necessary for set -r
# -------------------------------------------------------
exec 3>/dev/null

# Set up fd 4 for non-busy waiting for signals
# --------------------------------------------
exec 4<> <(:)

# ------------------------------------------------------------------------------
# Options description:
#   -o pipefail: exit on error in any part of pipeline
#   -eE:         exit on any error, go through error handler
#   -u:          exit on accessing uninitialized variable
#   -r:          set bash restricted mode for security
# The restricted mode option necessitates the usage of tee
# instead of simple output redirection when writing to files
# ------------------------------------------------------------------------------
set -o pipefail -eEur

## -----------------------------------------------------------------------------
## END OF SECURITY SECTION
## Make sure to populate the $UTILS array above
## -----------------------------------------------------------------------------

# Speed up script by not using unicode
# ------------------------------------
export LC_ALL=C
export LANG=C

# Globals
# -------

# Whether to print additional debug info
# --------------------------------------
readonly VERBOSE="false"

# The script will skip pinning cores for qubes pinned to IGNORE_PIN cores
# -----------------------------------------------------------------------
readonly IGNORE_PIN="all"

# Which cores to pin focused qubes to. Can be set to e.g. a range of p-cores
# --------------------------------------------------------------------------
readonly TARGET_CORES="all"

# Whether to pin/unpin dom0's cores as well
# -----------------------------------------
readonly PIN_DOM0="false"


# Generic error handling
# ----------------------
trap 'error_handler $? $LINENO' ERR

error_handler()
{
    trap - ERR
    err "Error: ($1) occurred on line $2"

    # Print part of code where error occured if VERBOSE=true
    # ------------------------------------------------------
    if [ "$VERBOSE" = "true" ]
    then
        # Save to variable to split by lines properly
        # shellcheck disable=SC2155,SC2086
        # -------------------------------------------
        local error_in_code=$(awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L=$2 $0 )
        debug "$error_in_code"
    fi

    # Exit with caught error code
    # ---------------------------
    exit "$1"
}


# Print to stderr and user.debug
# ------------------------------
debug()
{
    if [ "$VERBOSE" = "true" ]
    then
        echo "$@" | tee --output-error=warn /dev/fd/2 | logger --priority user.debug --tag "$0" || true
    fi
}


# Print to stderr and user.info
# -----------------------------
inform()
{
    echo "$@" | tee --output-error=warn /dev/fd/2 | logger --priority user.info --tag "$0" || true
}


# Print to stderr and user.warn
# -----------------------------
warn()
{
    echo "$@" | tee --output-error=warn /dev/fd/2 | logger --priority user.warning --tag "$0" || true
}


# Print to stderr and user.err
# ----------------------------
err()
{
    echo "$@" | tee --output-error=warn /dev/fd/2 | logger --priority user.err --tag "$0" || true
}


# Check the environment the script is running in
# ----------------------------------------------
check_environment()
{
    # Check whether script is already running
    # ---------------------------------------
    if [ "$(pgrep -- "$(basename "$0")" | wc -l)" -gt 2 ]
    then
        err "Another instance of the script is already running!"
        exit 1
    fi

    # Check available utilities
    # -------------------------
    for util in "${UTILS[@]}"
    do
        command -v -- "$util" >&3 || { err "This script requires $util to be installed and in PATH!"; exit 2; }
    done

    return
}


# Get window focused/window closed events. Format: for window focus changes,
# output is just the name of the VM that got focus. Domain-0 = dom0. Special
# thanks to Qubes Forum user Talkabout for providing the xprop method.
# ---------------------------------------------------------------------------
get_focused_domid()
{
    xprop -spy -root -notype _NET_ACTIVE_WINDOW \
        | stdbuf -oL cut -d ' ' -f 5 \
        | xargs -n 1 xprop -notype _QUBES_VMNAME -id 2>&1 \
        | stdbuf -oL sed -n -r -e 's/[^"]+"([^"]+)"[^"]*/\1/gp' \
                               -e 's/[^0]+0x0.$/Domain-0/gp' \
                               -e 's/_QUBES_VMNAME:\s+not\s+found./Domain-0/gp'
}


# Pin a VM to all CPU cores and wait for SIGTERM to unpin it
# ----------------------------------------------------------
pin()
{
    # Sanity check variables
    # ----------------------
    if [ -z "$2" ]
    then
        warn "pin() was called without arguments!"
    fi
    local _domid="$1"

    # Don't handle USR1 in child processes
    # ------------------------------------
    trap '' USR1

    # Helper function and signal trap for returning pins to the original state
    # ------------------------------------------------------------------------
    _reset_pin()
    {
        debug "Re-pinning $_domid from all cores to $old_cpus"
        debug xl vcpu-pin -- "$_domid" all "$old_cpus"
        xl vcpu-pin -- "$_domid" all "$old_cpus"
        return
    }
    trap _reset_pin TERM QUIT INT

    # Pin VM to chosen CPU cores
    # --------------------------
    inform "Pinning $_domid to all cores"
    debug xl vcpu-pin -- "$_domid" all "$TARGET_CORES"
    xl vcpu-pin -- "$_domid" all "$TARGET_CORES"

    # Wait on SIGTERM to reset pins
    # -----------------------------
    debug "Waiting to reset pins"
    read <&4
}


# Reset pins to their state before modifications by this script - one VM
# ----------------------------------------------------------------------
reset_pin()
{
    local job
    debug "Trying to reset pinning for $1"

    # Check if VM has even been pinned by this script
    # -----------------------------------------------
    if [[ -v jobs_list["$1"] ]]
    then
        debug "Key $1 found in jobs list"
        inform "Resetting pinning for $1"

        # Reset pins in all running jobs. There should only be one job per VM,
        # but it does not hurt to wrap this in a loop.
        # --------------------------------------------------------------------
        for job in ${jobs_list["$1"]}
        do
            debug kill -TERM -- "$job"
            kill -TERM -- "$job" || true
        done

        # Remove the job from the jobs list
        # ---------------------------------
        unset "jobs_list[$1]"
    else
        debug "Key $1 not found in jobs list"
    fi
}


# Reset pins to their state before modifications by this script - wrapper
# -----------------------------------------------------------------------
reset_all_pins()
{
    local _domid
    debug "Resetting all pins"
    debug "Jobs list: ${jobs_list[*]}"
    for _domid in "${!jobs_list[@]}"
    do
        reset_pin "$_domid"
    done
    return 0
}


# Clean up and exit cleanly
# -------------------------
clean_up()
{
    inform "Cleaning up and exiting..."
    reset_all_pins
    trap - EXIT
    exit
}


# Main program functionality
# --------------------------
main()
{
    # Exit cleanly on SIGTERM, INT, QUIT
    # ----------------------------------
    trap clean_up TERM INT QUIT

    # Reset all pins on SIGUSR1
    # -------------------------
    trap reset_all_pins USR1

    # Don't fall over on writing to closed pipe (on terminal detach)
    # --------------------------------------------------------------
    trap '' SIGPIPE

    # Variables
    # ---------
    local old_domid=""
    declare -A jobs_list

    # Read window focus/close events
    # ------------------------------
    while read -r domid
    do
        # Focus change event
        # ------------------
        debug "Detected focus change: $domid"
        if [ "$domid" = "$old_domid" ]
        then
            debug "Ignoring multi-focus event for: $domid"
            continue
        fi

        # Get pinned CPU list
        # -------------------
        if old_cpus="$(xl vcpu-list -- "$domid" 2>&3 \
            | tr -s ' ' \
            | cut -d ' ' -f7 \
            | tail -n +2 \
            | uniq \
            | grep -E '^[a-zA-Z0-9_\s,-]+$')"
        then
            # Reset pinning for previous domain
            # ---------------------------------
            if [ "$old_domid" != "Domain-0" ] || [ "$PIN_DOM0" = "true" ]
            then
                [ -n "$old_domid" ] && reset_pin "$old_domid"
            fi

            # Save old somain ID to reset it in the future
            # --------------------------------------------
            old_domid="$domid"

            # Skip iteration if focused domain = dom0 and PIN_DOM0 != true
            # ------------------------------------------------------------
            if [ "$domid" = "Domain-0" ] && [ "$PIN_DOM0" != "true" ]
            then
                debug "Skipping pinning cores for dom0 as \$PIN_DOM0 != \"true\""
                continue
            fi

            if [ "$old_cpus" = "$IGNORE_PIN" ]
            then
                # Skip loop for domains without custom pins
                # -----------------------------------------
                debug "Skipping iteration as cpu_pin = $old_cpus"
                continue
            else
                # Pin domain to all cores
                # -----------------------
                pin "$domid" "$old_cpus" &
                jobs_list["$domid"]+=" $!"
            fi
        else
            debug "Ignoring invalid domain: $domid"
        fi
        # When reading domain names, perform a value sanity check with grep
        # -----------------------------------------------------------------
    done < <(get_focused_domid | stdbuf -oL grep -E '^[a-zA-Z0-9_-]+$')
}

check_environment

# Execute main in a loop to facilitate returining from signal traps
# -----------------------------------------------------------------
while :
do
    main
done

exit

## END OF FILE #################################################################
# vim: set tabstop=4 softtabstop=4 expandtab shiftwidth=4 smarttab:
# End:
