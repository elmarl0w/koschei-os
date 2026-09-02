# SPDX-License-Identifier: GPL-2.0-or-later
# Короткое уведомление при переходе в root через sudo -i (login-шелл root
# с выставленным SUDO_USER). При прямом root-логине (tty2) не показывается.
# Текст — только латиница (шрифт tty1).
if [ "$(id -u)" = "0" ] && [ -n "$SUDO_USER" ]; then
    echo ""
    echo "You are root now ($SUDO_USER -> root). Use superuser rights wisely:"
    echo " - system runs in RAM: root changes are LOST on reboot"
    echo " - persistent settings live on the flash: use tc-edit or Settings menu"
    echo " - do not format or wipe /mnt/flash and block devices"
    echo " - when done, leave the root shell: exit or Ctrl-D"
    echo ""
fi
