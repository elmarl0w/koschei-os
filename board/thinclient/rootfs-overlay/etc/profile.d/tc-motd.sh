# SPDX-License-Identifier: GPL-2.0-or-later
# Памятка при входе ОБЫЧНОГО пользователя (интерактивный логин-шелл):
# консоль из меню, SSH. Для root не показывается. Текст — только латиница
# (консольный шрифт tty1 не рисует кириллицу).
if [ -n "$PS1" ] && [ "$(id -u)" != "0" ]; then
    echo ""
    echo "Quick tips:"
    echo "  tc-edit             edit servers.conf on the flash"
    echo "  tc-edit <file>      edit any flash file (auto rw -> edit -> ro)"
    echo "  tc-edit --help      all options and examples"
    echo "  sudo -i             root shell (enter your password)"
    echo ""
fi
