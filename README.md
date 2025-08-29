# Qubes Window Boost

[![License: AGPL v3](https://img.shields.io/badge/License-AGPLv3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0.en.html) 

## Description

This script is designed for QubesOS. It automatically reads the current
focused window's parent VM and pins the VM to all CPU cores (or to performance
cores, this only needs one line's worth of changes). The default assumption is that
all VMs are by default pinned to E-cores on asymmetrical CPUs and they get
given access to all cores when in focus for additional snappiness and
performance. See https://forum.qubes-os.org/t/cpu-pinning-alder-lake/17949 for
information on how to set up the prerequisite core pinning required for this
script to run well.

When the `USR1` signal is received by the script, it resets all dynamic pins, that is
it reset the pinning state to whatever it was before running the script. This does not
make the script exit.

## Usage

1. Set up automatic CPU pinning based on information in [this Qubes forum thread](https://forum.qubes-os.org/t/cpu-pinning-alder-lake/17949)
2. Decide on the cores you want to pin focused windows' VMs to (`TARGET_CORES` variable)
3. Decide on the VMs you want to ignore based on their current pins (`IGNORE_PIN` variable)
4. Download `window_boost.sh` and move it to `dom0` (e.g. to `/usr/local/bin/window_boost.sh`
5. Make it executable (`sudo chmod +x /usr/local/bin/window_boost.sh`)
6. Launch the script (`/usr/local/bin/window_boost.sh`)
7. Optional: launch the script automatically (example for autostart on `i3`: `exec_always --no-startup-id /usr/local/bin/window_boost.sh`)
8. Optional: configure keybind to clear all dynamic pins (e.g. before locking screen) (example for `i3`: `bindsym $mod+l exec --no-startup-id "pkill -USR1 window_boost.sh"`)

You can check whether the script works with this command in `dom0`:

```
watch -d -n 0.5 "xl vcpu-list | tr -s ' ' | cut -d' ' -f 1,7- | uniq | column -t -l 2"
```

## Limitations

1. If you have more specific pins defined for a VM (such as "vCPU 1 to CPUs 2, 3 and 4, vCPU 2 to CPUs 4, 6, 7), the script will probably not work well.

PRs to fix those issues are welcome :).

## Other Utilities

See [the qubes-utils repo](https://github.com/Atrate/qubes-utils) for links to other utilities I've written for Qubes.

## License
This project is licensed under the [AGPL-3.0-or-later](https://www.gnu.org/licenses/agpl-3.0.html).

[![License: AGPLv3](https://www.gnu.org/graphics/agplv3-with-text-162x68.png)](https://www.gnu.org/licenses/agpl-3.0.html)
