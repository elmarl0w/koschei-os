/*
 * tc-launcher — консольный интерфейс тонкого клиента (ncurses).
 *
 * Рисует список серверов по центру экрана и полосу действий внизу
 * (в стиле htop). Сам ничего не исполняет: выбранное действие пишет
 * в /tmp/tc-choice и завершается, а обёртка tc-menu выполняет его
 * и перезапускает лаунчер.
 *
 * Протокол в /tmp/tc-choice (одна строка).
 * Главный экран (для пользователя):
 *   CONNECT <ip>            подключиться к серверу
 *   SETTINGS               админ-раздел (сеть/RDP/принтер/диагностика/консоль
 *                          /управление серверами) — всё исполняет tc-menu
 *   REBOOT                  перезагрузка
 *   POWEROFF                выключение
 * Режим управления серверами (--manage, вызывается из Settings через tc-menu):
 *   ADD <name>;<ip>         добавить сервер в servers.conf
 *   EDIT <old>\t<new>       заменить запись сервера
 *   DELETE <name>;<ip>      удалить сервер
 *   BACK                    выйти из экрана управления
 * Обобщённое меню (--menu <title> <file>, для экранов настроек tc-menu):
 *   <N>                     индекс выбранного пункта (0-based среди кликабельных)
 *   BACK                    q/Esc
 * Экран пароля (--password <title> [message]): пароль пишется в файл, код
 *   возврата 0 = введён, 1 = отмена (q/Esc). Звёздочки, красное message.
 *
 * ВАЖНО: набор действий должен совпадать со списком case в tc-menu.
 */
#include <curses.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CONF    "/mnt/flash/servers.conf"
#define OUTFILE "/tmp/tc-choice"
#define MAXSRV  64
#define LIST_W  52
#define NAME_W  32

struct srv {
    char name[64];
    char ip[64];
    char sec[8];      /* протокол RDP: rdp/tls/nla или пусто (=глобальный дефолт) */
};

static struct srv servers[MAXSRV];
static int nsrv;

enum {
    C_NORM = 1,   /* обычный текст */
    C_IP,         /* ip в списке */
    C_SEL,        /* выбранная строка */
    C_BAR,        /* сегменты полосы действий */
    C_KEY,        /* клавиши в полосе действий */
    C_INFO,       /* приглушённый служебный текст */
    C_HOST,       /* hostname и ip в углу */
    C_WARN        /* предупреждение (неверный пароль) — красный */
};

static void load_servers(void)
{
    FILE *f;
    char line[256];

    nsrv = 0;
    f = fopen(CONF, "r");
    if (!f)
        return;
    while (fgets(line, sizeof line, f) && nsrv < MAXSRV) {
        char *sep, *sep2;

        line[strcspn(line, "\r\n")] = 0;
        if (!line[0] || line[0] == '#')
            continue;
        sep = strchr(line, ';');            /* имя;адрес[;протокол] */
        if (!sep || sep == line || !sep[1])
            continue;
        *sep = 0;
        sep2 = strchr(sep + 1, ';');         /* адрес;протокол */
        if (sep2)
            *sep2 = 0;
        snprintf(servers[nsrv].name, sizeof servers[nsrv].name, "%s", line);
        snprintf(servers[nsrv].ip, sizeof servers[nsrv].ip, "%s", sep + 1);
        snprintf(servers[nsrv].sec, sizeof servers[nsrv].sec, "%s",
                 sep2 ? sep2 + 1 : "");
        nsrv++;
    }
    fclose(f);
}

/* "tc-aabbccddeeff  192.168.0.5" для правого угла полосы действий */
static void get_info(char *buf, size_t n)
{
    char host[64] = "?";
    char ip[64] = "no ip";
    struct ifaddrs *ifa0, *ifa;

    gethostname(host, sizeof host);
    host[sizeof host - 1] = 0;
    if (getifaddrs(&ifa0) == 0) {
        for (ifa = ifa0; ifa; ifa = ifa->ifa_next) {
            struct sockaddr_in *sa;

            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
                continue;
            if (strcmp(ifa->ifa_name, "lo") == 0)
                continue;
            sa = (struct sockaddr_in *)ifa->ifa_addr;
            inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof ip);
            break;
        }
        freeifaddrs(ifa0);
    }
    snprintf(buf, n, "%s  %s", host, ip);
}

static void write_choice(const char *fmt, const char *arg1, const char *arg2)
{
    FILE *f = fopen(OUTFILE, "w");

    if (!f)
        return;
    fprintf(f, fmt, arg1 ? arg1 : "", arg2 ? arg2 : "");
    fputc('\n', f);
    fclose(f);
}

/* записать готовую строку в /tmp/tc-choice (для полей с 3 частями) */
static void write_line(const char *s)
{
    FILE *f = fopen(OUTFILE, "w");

    if (!f)
        return;
    fputs(s, f);
    fputc('\n', f);
    fclose(f);
}

/* протокол сервера: допустимы только rdp/tls/nla, иначе пусто (=дефолт) */
static void norm_sec(char *s)
{
    if (strcmp(s, "rdp") && strcmp(s, "tls") && strcmp(s, "nla"))
        s[0] = 0;
}

/* сервисные кнопки — вертикальным столбиком внизу. Главный экран — только
 * для пользователя: выбрать сервер и подключиться. Всё админское (управление
 * серверами, сеть/RDP, диагностика, консоль) — под пунктом Settings, который
 * tc-menu опционально паролит файлом shell.pass. */
#define NBAR 3
static const char *bar_label[NBAR] = { " Settings ", " Reboot ", " PowerOff " };
static int nbar = NBAR;   /* 0 в режиме управления серверами */
static int manage = 0;    /* 1 = экран «Manage servers» (add/edit/delete) */

/* В обычном меню кнопки идут сразу после серверов. В режиме управления есть
 * дополнительный слот "+ Add server" (индекс nsrv), кнопок нет. */
static int addslot(void) { return manage ? 1 : 0; }

static void draw_buttons(int sel, int x0)
{
    int base = LINES - 1 - nbar;
    int i;

    for (i = 0; i < nbar; i++) {
        if (sel == nsrv + addslot() + i)
            attrset(COLOR_PAIR(C_SEL));
        else
            attrset(COLOR_PAIR(C_IP));
        mvaddstr(base + i, x0 + 1, bar_label[i]);
    }
    attrset(COLOR_PAIR(C_NORM));
}

/*
 * Цепочка выбора: 0..nsrv-1 — серверы; дальше в обычном меню сразу кнопки
 * нижней полосы (Settings/Reboot/PowerOff), а в режиме управления — слот
 * "+ Add server" (индекс nsrv). Стрелки вверх/вниз ходят по кругу.
 */
static void draw(int sel)
{
    char info[160];
    int gap = nsrv ? 1 : 0;
    /* в обычном меню высота блока = список серверов (кнопки прибиты к низу);
     * в режиме управления добавляется слот "+ Add server" */
    int height = manage ? nsrv + gap + 1 : nsrv;
    int top = (LINES - 1 - (height ? height : 1)) / 2;
    int x0 = (COLS - LIST_W) / 2;
    int i, y;

    if (top < 1)
        top = 1;
    if (x0 < 0)
        x0 = 0;

    erase();

    /* hostname и ip — в левом верхнем углу */
    get_info(info, sizeof info);
    attrset(COLOR_PAIR(C_HOST));
    mvaddstr(0, 1, info);

    /* версия образа (из /etc/tc-release) — в правом верхнем углу; читаем раз */
    {
        static char ver[48] = "\1";     /* \1 = ещё не читали */
        if (ver[0] == '\1') {
            FILE *vf = fopen("/etc/tc-release", "r");
            ver[0] = 0;
            if (vf) {
                if (fgets(ver, sizeof ver, vf))
                    ver[strcspn(ver, "\r\n")] = 0;
                fclose(vf);
            }
        }
        if (ver[0]) {
            attrset(COLOR_PAIR(C_INFO));
            mvaddstr(0, COLS - (int)strlen(ver) - 1, ver);
        }
    }

    if (!nsrv) {
        attrset(COLOR_PAIR(C_INFO));
        mvaddstr(top - 2, (COLS - 21) / 2, "No servers configured");
    }

    for (i = 0; i < nsrv; i++) {
        char ipdisp[80];

        y = top + i;
        if (servers[i].sec[0])           /* показать протокол, если задан */
            snprintf(ipdisp, sizeof ipdisp, "%s [%s]", servers[i].ip, servers[i].sec);
        else
            snprintf(ipdisp, sizeof ipdisp, "%s", servers[i].ip);
        attrset(COLOR_PAIR(i == sel ? C_SEL : C_NORM));
        mvhline(y, x0, ' ', LIST_W);
        mvaddnstr(y, x0 + 1, servers[i].name, NAME_W);
        if (i != sel)
            attrset(COLOR_PAIR(C_IP));
        mvaddstr(y, x0 + LIST_W - (int)strlen(ipdisp) - 1, ipdisp);
    }

    /* слот "+ Add server" — только в режиме управления серверами */
    if (manage) {
        y = top + nsrv + gap;
        attrset(sel == nsrv ? COLOR_PAIR(C_SEL) : COLOR_PAIR(C_INFO));
        if (sel == nsrv)
            mvhline(y, x0, ' ', LIST_W);
        mvaddstr(y, x0 + 1, "+ Add server");

        attrset(COLOR_PAIR(C_HOST));
        mvaddstr(0, (COLS - 14) / 2, "Manage servers");
        attrset(COLOR_PAIR(C_INFO));
        mvaddstr(LINES - 1, 1, "Enter/e edit  d delete  a add  q/Esc back");
    }

    draw_buttons(sel, x0);
    refresh();
}

/* поле ввода по центру.
 *   allow_empty=0: пустая строка = отмена (возврат 0);
 *   allow_empty=1: пустая строка допустима (возврат 1, buf==""). */
static int prompt(const char *label, char *buf, int n, int allow_empty)
{
    int y = LINES / 2;
    int x = (COLS - 44) / 2;
    int r;

    if (x < 0)
        x = 0;
    attrset(COLOR_PAIR(C_NORM));
    erase();
    mvaddstr(y - 1, x, label);
    attrset(COLOR_PAIR(C_INFO));
    mvaddstr(y + 2, x, allow_empty ? "empty = keep current" : "empty input cancels");
    attrset(COLOR_PAIR(C_NORM));
    move(y, x);
    echo();
    curs_set(1);
    /* блокирующий ввод: общий секундный таймаут перерисовки иначе
       обрывает getnstr через 1с и это выглядит как отмена */
    timeout(-1);
    r = getnstr(buf, n - 1);
    timeout(1000);
    noecho();
    curs_set(0);
    if (r == ERR)
        return 0;
    return allow_empty || buf[0] != 0;
}

/* убрать из поля символы, ломающие формат "имя;ip" и протокол:
 * ';' (разделитель), а также tab и любые control-символы. */
static void strip_bad(char *s)
{
    char *p, *q;

    for (p = q = s; *p; p++)
        if (*p != ';' && (unsigned char)*p >= 0x20)
            *q++ = *p;
    *q = 0;
}

static int do_add(void)
{
    char name[64], ip[64], sec[8] = "";
    char entry[144];

    if (prompt("Server name:", name, sizeof name, 0) &&
        prompt("IP address (ip or ip:port):", ip, sizeof ip, 0)) {
        prompt("Security rdp/tls/nla (empty = default):", sec, sizeof sec, 1);
        strip_bad(name);
        strip_bad(ip);
        strip_bad(sec);
        norm_sec(sec);
        if (!name[0] || !ip[0])
            return 0;
        endwin();
        snprintf(entry, sizeof entry, "ADD %s;%s;%s", name, ip, sec);
        write_line(entry);
        return 1;
    }
    return 0;
}

/* редактировать сервер i: пустое поле = оставить старое значение.
 * Пишем "EDIT old_name;old_ip \t new_name;new_ip" (tab-разделитель). */
static int do_edit(int i)
{
    char name[64] = "", ip[64] = "", sec[8] = "";
    char lbl1[128], lbl2[128], lbl3[128], oldp[136], newp[160], msg[320];

    snprintf(lbl1, sizeof lbl1, "New name [%s]:", servers[i].name);
    snprintf(lbl2, sizeof lbl2, "New IP [%s]:", servers[i].ip);
    snprintf(lbl3, sizeof lbl3, "Security [%s] (rdp/tls/nla, - to clear):",
             servers[i].sec[0] ? servers[i].sec : "default");
    if (!prompt(lbl1, name, sizeof name, 1))
        return 0;
    if (!prompt(lbl2, ip, sizeof ip, 1))
        return 0;
    prompt(lbl3, sec, sizeof sec, 1);
    strip_bad(name);
    strip_bad(ip);
    strip_bad(sec);
    if (!name[0])
        snprintf(name, sizeof name, "%s", servers[i].name);
    if (!ip[0])
        snprintf(ip, sizeof ip, "%s", servers[i].ip);
    /* протокол: пусто = оставить старый; "-" = очистить; иначе новый (валидный) */
    if (!sec[0])
        snprintf(sec, sizeof sec, "%s", servers[i].sec);
    else if (!strcmp(sec, "-"))
        sec[0] = 0;
    else
        norm_sec(sec);
    /* ключ (для поиска строки) — 2 поля имя;адрес; новое значение — 3 поля */
    snprintf(oldp, sizeof oldp, "%s;%s", servers[i].name, servers[i].ip);
    snprintf(newp, sizeof newp, "%s;%s;%s", name, ip, sec);
    endwin();
    snprintf(msg, sizeof msg, "EDIT %s\t%s", oldp, newp);
    write_line(msg);
    return 1;
}

/* удалить сервер i с подтверждением */
static int do_delete(int i)
{
    char oldp[136];
    int y = LINES / 2, x = (COLS - 44) / 2, c;

    if (x < 0)
        x = 0;
    attrset(COLOR_PAIR(C_NORM));
    erase();
    mvprintw(y, x, "Delete server \"%s\" (%s)?", servers[i].name, servers[i].ip);
    attrset(COLOR_PAIR(C_INFO));
    mvaddstr(y + 2, x, "y = delete, any other key = cancel");
    refresh();
    timeout(-1);
    c = getch();
    timeout(1000);
    if (c != 'y' && c != 'Y')
        return 0;
    snprintf(oldp, sizeof oldp, "%s;%s", servers[i].name, servers[i].ip);
    endwin();
    write_choice("DELETE %s", oldp, NULL);
    return 1;
}

static void bar_action(int bsel)
{
    static const char *act[NBAR] = { "SETTINGS", "REBOOT", "POWEROFF" };

    endwin();
    write_choice(act[bsel], NULL, NULL);
}

/* ---- обобщённый режим меню: tc-launcher --menu <title> <file> ----------
 * Рисует вертикальный список стрелками в стиле главного экрана; пункты берёт
 * из файла (строка = пункт). Формат строки:
 *   "#Заголовок"     — некликабельный заголовок секции (приглушённый)
 *   "label"          — пункт
 *   "label\tсправа"  — пункт + правая приглушённая колонка (текущее значение)
 * В /tmp/tc-choice пишет индекс выбранного пункта (0-based среди КЛИКАБЕЛЬНЫХ)
 * либо BACK (q/Esc). Так tc-menu делает настройки настоящим меню, а не
 * «набери цифру». */
#define MAXMENU 64
struct mitem {
    char label[96];
    char right[96];
    int header;
};
static struct mitem mitems[MAXMENU];
static int nmit;
static char menu_title[128];

/* число колонок (примерно): считаем ведущие байты UTF-8, не продолжения */
static int ucols(const char *s)
{
    int n = 0;

    for (; *s; s++)
        if (((unsigned char)*s & 0xC0) != 0x80)
            n++;
    return n;
}

/* напечатать не более maxcols колонок строки (режем по границе символа UTF-8) */
static void addstr_cols(int y, int x, const char *s, int maxcols)
{
    int cols = 0, bytes = 0;

    while (s[bytes] && cols < maxcols) {
        unsigned char ch = (unsigned char)s[bytes];
        int adv = 1;

        if (ch >= 0xF0)
            adv = 4;
        else if (ch >= 0xE0)
            adv = 3;
        else if (ch >= 0xC0)
            adv = 2;
        bytes += adv;
        cols++;
    }
    mvaddnstr(y, x, s, bytes);
}

static void load_menu(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[256];

    nmit = 0;
    if (!f)
        return;
    while (fgets(line, sizeof line, f) && nmit < MAXMENU) {
        char *tab;

        line[strcspn(line, "\r\n")] = 0;
        if (line[0] == '#') {
            mitems[nmit].header = 1;
            snprintf(mitems[nmit].label, sizeof mitems[nmit].label, "%s", line + 1);
            mitems[nmit].right[0] = 0;
        } else {
            mitems[nmit].header = 0;
            tab = strchr(line, '\t');
            if (tab) {
                *tab = 0;
                snprintf(mitems[nmit].right, sizeof mitems[nmit].right, "%s", tab + 1);
            } else {
                mitems[nmit].right[0] = 0;
            }
            snprintf(mitems[nmit].label, sizeof mitems[nmit].label, "%s", line);
        }
        nmit++;
    }
    fclose(f);
}

/* порядковый номер строки row среди кликабельных (заголовки не считаем) */
static int sel_ordinal(int row)
{
    int k = 0, i;

    for (i = 0; i < row; i++)
        if (!mitems[i].header)
            k++;
    return k;
}

static void draw_menu(int sel)
{
    char info[160];
    int top = (LINES - 1 - nmit) / 2;
    int x0 = (COLS - LIST_W) / 2;
    int i, y;

    if (top < 1)
        top = 1;
    if (x0 < 0)
        x0 = 0;

    erase();

    /* hostname/ip слева, заголовок меню по центру — как на главном экране */
    get_info(info, sizeof info);
    attrset(COLOR_PAIR(C_HOST));
    mvaddstr(0, 1, info);
    attrset(COLOR_PAIR(C_HOST));
    addstr_cols(0, (COLS - ucols(menu_title)) / 2, menu_title, COLS);

    for (i = 0; i < nmit; i++) {
        int lcols;

        y = top + i;
        if (mitems[i].header) {
            attrset(COLOR_PAIR(C_INFO));
            addstr_cols(y, x0 + 1, mitems[i].label, LIST_W - 2);
            continue;
        }
        attrset(COLOR_PAIR(i == sel ? C_SEL : C_NORM));
        mvhline(y, x0, ' ', LIST_W);
        addstr_cols(y, x0 + 2, mitems[i].label, NAME_W);

        if (mitems[i].right[0]) {
            int rc = ucols(mitems[i].right);

            lcols = ucols(mitems[i].label);
            if (lcols > NAME_W)
                lcols = NAME_W;
            if (i != sel)
                attrset(COLOR_PAIR(C_IP));
            if (rc <= LIST_W - lcols - 5) {
                addstr_cols(y, x0 + LIST_W - rc - 1, mitems[i].right, rc);
            } else {
                /* не влезает целиком — обрезаем после метки */
                int avail = LIST_W - lcols - 5;

                if (avail > 1)
                    addstr_cols(y, x0 + 3 + lcols, mitems[i].right, avail);
            }
        }
    }

    attrset(COLOR_PAIR(C_INFO));
    mvaddstr(LINES - 1, 1, "Up/Down select   Enter ok   q/Esc back");
    refresh();
}

static void menu_mode(void)
{
    int sel = -1, i;

    for (i = 0; i < nmit; i++)
        if (!mitems[i].header) {
            sel = i;
            break;
        }
    if (sel < 0) {                       /* нет кликабельных пунктов */
        endwin();
        write_choice("BACK", NULL, NULL);
        return;
    }

    for (;;) {
        int c;

        draw_menu(sel);
        c = getch();
        switch (c) {
        case ERR:
            break;
        case KEY_UP:
        case 'k':
            do { sel = (sel + nmit - 1) % nmit; } while (mitems[sel].header);
            break;
        case KEY_DOWN:
        case 'j':
        case '\t':
            do { sel = (sel + 1) % nmit; } while (mitems[sel].header);
            break;
        case '\n':
        case '\r':
        case KEY_ENTER: {
            char buf[16];

            endwin();
            snprintf(buf, sizeof buf, "%d", sel_ordinal(sel));
            write_choice("%s", buf, NULL);
            return;
        }
        case 'q':
        case 'Q':
        case 27:               /* Esc */
            endwin();
            write_choice("BACK", NULL, NULL);
            return;
        default:
            break;
        }
    }
}

/* ---- экран ввода пароля: tc-launcher --password <title> [message] --------
 * Центрированный тёмный экран (в стиле меню) с полем пароля и звёздочками.
 * Enter -> пароль пишется в /tmp/tc-choice, возврат 0. Esc или 'q' на пустом
 * поле -> возврат 1 (отмена). message (если задан) — красная строка снизу
 * (напр. "Wrong password, 2 left"). Так экран пароля выглядит как остальные,
 * а не голым текстом в углу. */
static char pw_msg[80];

static void draw_password(int len)
{
    int y = LINES / 2;
    int x = (COLS - 44) / 2;
    int i;

    if (x < 0)
        x = 0;
    erase();
    attrset(COLOR_PAIR(C_HOST));
    addstr_cols(y - 3, (COLS - ucols(menu_title)) / 2, menu_title, COLS);
    attrset(COLOR_PAIR(C_NORM));
    mvaddstr(y, x, "Password: ");
    for (i = 0; i < len; i++)
        addch('*');
    if (pw_msg[0]) {
        attrset(COLOR_PAIR(C_WARN));
        addstr_cols(y + 2, x, pw_msg, COLS - x - 1);
    }
    attrset(COLOR_PAIR(C_INFO));
    mvaddstr(y + 4, x, "Enter - ok      q / Esc - cancel");
    move(y, x + 10 + len);
    refresh();
}

static int password_mode(void)   /* 0 = введён (в файле), 1 = отмена */
{
    char buf[128];
    int len = 0;

    curs_set(1);
    for (;;) {
        int c;

        draw_password(len);
        c = getch();
        if (c == ERR)
            continue;
        if (c == '\n' || c == '\r' || c == KEY_ENTER) {
            FILE *f;

            buf[len] = 0;
            endwin();
            f = fopen(OUTFILE, "w");
            if (f) { fputs(buf, f); fclose(f); }
            memset(buf, 0, sizeof buf);
            return 0;
        }
        if (c == 27 || ((c == 'q' || c == 'Q') && len == 0)) {
            endwin();
            memset(buf, 0, sizeof buf);
            return 1;                       /* отмена (Esc / q на пустом) */
        }
        if (c == KEY_BACKSPACE || c == 127 || c == 8) {
            if (len > 0)
                len--;
            continue;
        }
        if (c >= 32 && c < 127 && len < (int)sizeof buf - 1)
            buf[len++] = (char)c;
    }
}

/* инициализация ncurses/палитры — общая для главного экрана и меню */
static void ui_init(void)
{
    initscr();
    start_color();
    init_pair(C_NORM, COLOR_WHITE, COLOR_BLACK);
    init_pair(C_IP,   COLOR_CYAN,  COLOR_BLACK);
    init_pair(C_SEL,  COLOR_BLACK, COLOR_CYAN);
    init_pair(C_BAR,  COLOR_BLACK, COLOR_CYAN);
    init_pair(C_KEY,  COLOR_WHITE, COLOR_BLACK);
    init_pair(C_INFO, COLOR_BLUE,  COLOR_BLACK);
    init_pair(C_HOST, COLOR_YELLOW, COLOR_BLACK);
    init_pair(C_WARN, COLOR_RED,   COLOR_BLACK);
    bkgd(COLOR_PAIR(C_NORM));
    cbreak();
    noecho();
    curs_set(0);
    keypad(stdscr, TRUE);
    timeout(1000);          /* раз в секунду перерисовка: обновляет ip в углу */
}

int main(int argc, char **argv)
{
    int sel = 0;
    int total;

    /* обобщённое меню для tc-menu: tc-launcher --menu <title> <file> */
    if (argc > 1 && strcmp(argv[1], "--menu") == 0) {
        if (argc < 4)
            return 1;
        snprintf(menu_title, sizeof menu_title, "%s", argv[2]);
        load_menu(argv[3]);
        ui_init();
        menu_mode();
        return 0;
    }

    /* экран пароля: tc-launcher --password <title> [message] */
    if (argc > 1 && strcmp(argv[1], "--password") == 0) {
        if (argc < 3)
            return 1;
        snprintf(menu_title, sizeof menu_title, "%s", argv[2]);
        if (argc > 3)
            snprintf(pw_msg, sizeof pw_msg, "%s", argv[3]);
        ui_init();
        return password_mode();      /* 0 = пароль в /tmp/tc-choice, 1 = отмена */
    }

    if (argc > 1 && strcmp(argv[1], "--manage") == 0) {
        manage = 1;
        nbar = 0;               /* в режиме управления нет сервис-кнопок */
    }

    load_servers();
    /* main: серверы + кнопки; manage: серверы + слот "+ Add server" */
    total = nsrv + addslot() + nbar;

    ui_init();

    for (;;) {
        int c;

        draw(sel);
        c = getch();
        switch (c) {
        case ERR:
            break;
        case KEY_UP:
        case 'k':
            sel = (sel + total - 1) % total;
            break;
        case KEY_DOWN:
        case 'j':
        case '\t':
            sel = (sel + 1) % total;
            break;
        case '\n':
        case '\r':
        case KEY_ENTER:
            if (sel < nsrv) {
                if (manage) {
                    if (do_edit(sel))
                        return 0;
                    break;
                }
                endwin();
                write_choice("CONNECT %s", servers[sel].ip, NULL);
                return 0;
            }
            if (manage) {                 /* sel == nsrv: слот "+ Add server" */
                if (do_add())
                    return 0;
                break;
            }
            bar_action(sel - nsrv);       /* сервис-кнопки (только main) */
            return 0;
        /* --- клавиши режима управления серверами --- */
        case 'e':
        case 'E':
            if (manage && sel < nsrv && do_edit(sel))
                return 0;
            break;
        case 'a':
        case 'A':
            if (manage && do_add())
                return 0;
            break;
        case 'd':
        case 'D':
        case KEY_DC:
            if (manage && sel < nsrv && do_delete(sel))
                return 0;
            break;
        case 'q':
        case 'Q':
        case 27:               /* Esc */
            if (manage) {
                endwin();
                write_choice("BACK", NULL, NULL);
                return 0;
            }
            break;
        /* F-клавиши: сервис (только main): Settings/Reboot/PowerOff */
        case KEY_F(5):
            if (!manage) { bar_action(0); return 0; }
            break;
        case KEY_F(6):
            if (!manage) { bar_action(1); return 0; }
            break;
        case KEY_F(7):
            if (!manage) { bar_action(2); return 0; }
            break;
        default:
            break;
        }
    }
}
