#!/usr/bin/env python3
"""
Curses TUI wrapper for nexsoft_update_qc.sh
- Configure flags/env vars
- Run the Bash updater and stream logs
- Non-invasive: keeps the shell script as the single source of truth

Keys:
  ↑/↓ (j/k)  : navigate fields
  ←/→        : toggle booleans
  Enter      : edit field / start on "▶ Start"
  F5 or s    : start
  t          : toggle theme (Dark/Light)
  q or ESC   : quit (asks confirmation if a job is running)
"""
import curses
import subprocess
import threading
import os
from datetime import datetime
from typing import List, Dict


SCRIPT_PATH = os.path.join(os.path.dirname(__file__), 'nexsoft_update_qc.sh')

import re

# --- Helper: try to read a default Download URL from the shell script ---
def detect_download_url_from_sh(script_path: str) -> str:
    """Parse the updater shell script to find a default/embedded Download URL.
    Looks for patterns like DEFAULT_DOWNLOAD_URL= or DOWNLOAD_URL= with http(s).
    Returns an empty string if not found."""
    try:
        with open(script_path, 'r', encoding='utf-8', errors='ignore') as f:
            text = f.read()
        m = re.search(r"^\s*DEFAULT_DOWNLOAD_URL\s*=\s*['\"]([^'\"]+)['\"]", text, re.MULTILINE)
        if m and m.group(1).startswith(('http://', 'https://')):
            return m.group(1).strip()
        m = re.search(r"^\s*DOWNLOAD_URL\s*=\s*['\"]([^'\"]+)['\"]", text, re.MULTILINE)
        if m and m.group(1).startswith(('http://', 'https://')):
            return m.group(1).strip()
        m = re.search(r"https?://\S+", text)
        if m:
            return m.group(0).strip().rstrip(')')
    except Exception:
        pass
    return ''

# --- Helpers: detect Product Serial Number from the machine ---
def detect_serial() -> str:
    """Best-effort detection of a device/Product Serial Number.
    Tries several common sources and returns an empty string if not found."""
    # 1) DietPi product file format: KEY=VALUE
    try:
        path = '/etc/dietpi/.product_id'
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if line.startswith('SERIAL_NUMBER='):
                        val = line.split('=', 1)[1].strip().strip('"\'')
                        if val:
                            return val
    except Exception:
        pass
    # 2) DMI (x86/arm servers)
    try:
        path = '/sys/class/dmi/id/product_serial'
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                val = f.read().strip()
                if val and val.upper() != 'UNKNOWN':
                    return val
    except Exception:
        pass
    # 3) /proc/cpuinfo (Raspberry Pi etc.)
    try:
        path = '/proc/cpuinfo'
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    if line.lower().startswith('serial') and ':' in line:
                        val = line.split(':', 1)[1].strip()
                        if val:
                            return val
    except Exception:
        pass
    # 4) Fallback: environment variable already set
    try:
        val = os.environ.get('SERIAL_NUMBER', '').strip()
        if val:
            return val
    except Exception:
        pass
    return ''

class UIState:
    def __init__(self):
        self.theme_dark = True
        self.mode = 'neutral'   # neutral | work | ok
        self.message = 'Ready'
        self.env: Dict[str, str] = {
            'DOWNLOAD_URL': os.environ.get('DOWNLOAD_URL', ''),
            'DOWNLOAD_UA': os.environ.get('DOWNLOAD_UA', 'Mozilla/5.0'),
            'DOWNLOAD_REFERER': os.environ.get('DOWNLOAD_REFERER', ''),
            'SERVICE_NAME': os.environ.get('SERVICE_NAME', 'nexSoft'),
            'TARGET_DIR': os.environ.get('TARGET_DIR', '/opt/nexSoft'),
            'TIMESHIFT_SCRIPT': os.environ.get('TIMESHIFT_SCRIPT', '/opt/scripts/TimeShift_FactorySettings.sh'),
            'STATE_DIR': os.environ.get('STATE_DIR', '/var/lib/nex'),
            'SERVICE_START_TIMEOUT': os.environ.get('SERVICE_START_TIMEOUT', '20'),
            'SERVICE_POST_START_WAIT': os.environ.get('SERVICE_POST_START_WAIT', '5'),
            'SERVICE_LOG_LOOKBACK': os.environ.get('SERVICE_LOG_LOOKBACK', '300'),
            'WEBMIN_HTTP_TIMEOUT': os.environ.get('WEBMIN_HTTP_TIMEOUT', '5'),
            'NEXSOFT_CERT_DIR': os.environ.get('NEXSOFT_CERT_DIR', '/opt/nexSoft/cert'),
            'CERT_GROUP': os.environ.get('CERT_GROUP', 'nexroot'),
            'SERIAL_DEV': os.environ.get('SERIAL_DEV', '/dev/ttyUSB0'),
            'SERIAL_BAUD': os.environ.get('SERIAL_BAUD', '115200'),
            'SERIAL_TIMEOUT_SEC': os.environ.get('SERIAL_TIMEOUT_SEC', '5'),
            'LOOPBACK_BYTES': os.environ.get('LOOPBACK_BYTES', '64'),
            'SERIAL_NUMBER': os.environ.get('SERIAL_NUMBER', ''),
        }
        # Auto-detect Product Serial Number on startup (mandatory field)
        if not self.env.get('SERIAL_NUMBER'):
            self.env['SERIAL_NUMBER'] = detect_serial()
        # Auto-import default Download URL from the shell script when not provided
        if not self.env.get('DOWNLOAD_URL'):
            self.env['DOWNLOAD_URL'] = detect_download_url_from_sh(SCRIPT_PATH)
        self.flags = {
            'ENABLE_RS232_TEST': True,
            'ENABLE_RS232_MODEM': False,
            'NO_TIMESHIFT': False,
            'NO_UPDATE': False,
            'CLEAR_LOGS': False,
            'NO_NEXSOFT_BKP': False,
            'REMOVE_STATIC_IP_SERVICE': True,
            'ENABLE_SECONDARY_IP_SERVICE': True,
            'OVERWRITE_IDS': False,
            'NON_INTERACTIVE': False,
        }
        self.field_index = 0
        self.edit_mode = False
        self.input_buffer = ''
        self.logs: List[str] = []
        self.proc: subprocess.Popen | None = None

    def log(self, line: str):
        ts = datetime.now().strftime('%H:%M:%S')
        self.logs.append(f"[{ts}] {line}")
        self.logs = self.logs[-500:]

    def set_mode(self, mode: str, msg: str = ''):
        self.mode = mode
        if msg:
            self.message = msg

class TUI:
    def __init__(self, stdscr, state: UIState):
        self.stdscr = stdscr
        self.state = state
        curses.curs_set(0)
        # Initialize colors robustly (some TERM/ttys don't support default colors)
        curses.start_color()
        has_default_bg = False
        if curses.has_colors():
            try:
                curses.use_default_colors()
                has_default_bg = True
            except curses.error:
                has_default_bg = False
        bg_default = -1 if has_default_bg else curses.COLOR_BLACK

        # Light theme pairs
        curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)      # neutral
        curses.init_pair(2, curses.COLOR_WHITE, curses.COLOR_RED)       # work
        curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_GREEN)     # ok
        curses.init_pair(4, curses.COLOR_CYAN, bg_default)              # title
        curses.init_pair(5, curses.COLOR_YELLOW, bg_default)            # field value
        curses.init_pair(6, curses.COLOR_WHITE, curses.COLOR_BLACK)     # neutral dark
        curses.init_pair(7, curses.COLOR_WHITE, curses.COLOR_MAGENTA)   # work dark
        curses.init_pair(8, curses.COLOR_BLACK, curses.COLOR_CYAN)      # ok dark

        self.fields_order = [
            ('DOWNLOAD_URL', 'Download URL'),
            ('DOWNLOAD_REFERER', 'HTTP Referer (optional)'),
            ('SERVICE_NAME', 'Service name'),
            ('TARGET_DIR', 'Target dir'),
            ('SERIAL_DEV', 'Serial device'),
            ('SERIAL_BAUD', 'Serial baud'),
            ('SERIAL_NUMBER', 'Product Serial Number'),
            ('TIMESHIFT_SCRIPT', 'Timeshift script path'),
            ('SERVICE_START_TIMEOUT', 'Service start timeout (s)'),
            ('SERVICE_POST_START_WAIT', 'Post-start log delay (s)'),
            ('SERVICE_LOG_LOOKBACK', 'Log lookback (s w/o restart)'),
            ('WEBMIN_HTTP_TIMEOUT', 'Webmin HTTP timeout (s)'),
        ]
        self.toggle_order = [
            ('ENABLE_RS232_TEST', 'RS232 loopback test'),
            ('ENABLE_RS232_MODEM', 'RS232 modem-lines test'),
            ('NO_UPDATE', 'Skip update (QC only)'),
            ('NO_TIMESHIFT', 'Disable Timeshift snapshot'),
            ('CLEAR_LOGS', 'Clear journald before restart'),
            ('NO_NEXSOFT_BKP', 'Skip /opt/nexSoft backup'),
            ('REMOVE_STATIC_IP_SERVICE', 'Remove add-static-ip.service'),
            ('ENABLE_SECONDARY_IP_SERVICE', 'Enable secondary-ip.service'),
            ('OVERWRITE_IDS', 'Overwrite existing IDs'),
            ('NON_INTERACTIVE', 'Non-interactive prompts'),
        ]

    def _bg_pair(self):
        dark = self.state.theme_dark
        if self.state.mode == 'work':
            return curses.color_pair(7 if dark else 2)
        if self.state.mode == 'ok':
            return curses.color_pair(8 if dark else 3)
        return curses.color_pair(6 if dark else 1)

    def draw(self):
        st = self.state
        h, w = self.stdscr.getmaxyx()
        self.stdscr.bkgd(' ', self._bg_pair())
        self.stdscr.erase()
        title = 'nexSoft Update & QC – TUI'
        self.stdscr.attron(curses.color_pair(4))
        self.stdscr.addstr(0, max(0, (w - len(title)) // 2), title)
        self.stdscr.attroff(curses.color_pair(4))

        left_w = 64
        total_lines = len(self.fields_order) + len(self.toggle_order) + 7
        start_y = max(1, (h - total_lines) // 2)
        x0 = max(2, (w - left_w) // 2)
        y = start_y
        self.stdscr.addstr(y, x0, 'Configuration', curses.A_BOLD); y += 2

        for i, (key, label) in enumerate(self.fields_order):
            val = st.env.get(key, '')
            sel = curses.A_REVERSE if self.state.field_index == i else curses.A_NORMAL
            label_txt = label
            value_txt = str(val)
            attr_val = sel | curses.color_pair(5)
            # Emphasize required field if empty (do not alter label width)
            if key == 'SERIAL_NUMBER' and (not val or str(val).strip() == ''):
                value_txt = '<REQUIRED>'
                # Use the "work" color as a warning (red/magenta depending on theme)
                attr_val = sel | (curses.color_pair(7) if self.state.theme_dark else curses.color_pair(2)) | curses.A_BOLD
            self.stdscr.addstr(y, x0, f"{label_txt:30}", sel)
            self.stdscr.addstr(y, x0 + 31, value_txt[: left_w-33], attr_val)
            y += 1

        y += 1
        self.stdscr.addstr(y, x0, 'Options', curses.A_BOLD); y += 1
        for j, (tkey, tlabel) in enumerate(self.toggle_order):
            idx = len(self.fields_order) + j
            sel = curses.A_REVERSE if self.state.field_index == idx else curses.A_NORMAL
            flag = st.flags.get(tkey, False)
            self.stdscr.addstr(y, x0, f"{tlabel:30}", sel)
            self.stdscr.addstr(y, x0 + 31, 'ON ' if flag else 'OFF', sel | curses.color_pair(5))
            y += 1

        y += 1
        idx_start = len(self.fields_order) + len(self.toggle_order)
        sel = curses.A_REVERSE if self.state.field_index == idx_start else curses.A_NORMAL
        self.stdscr.addstr(y, x0, '▶ Start', sel | curses.A_BOLD)
        y += 2

        self.stdscr.addstr(y, x0, f"Status: {st.message}")
        y += 1
        max_logs = h - y - 2
        logs = st.logs[-max_logs:]
        for i, line in enumerate(logs):
            line = (line[: (w - x0 - 5)] + '…') if len(line) > (w - x0 - 2) else line
            self.stdscr.addstr(y + i, x0, line)

        help_text = '↑/↓(j/k) navigate • Enter edit/start • ←/→ toggle • F5/s start • t theme • q quit'
        self.stdscr.addstr(h-1, max(0, (w - len(help_text)) // 2), help_text)
        self.stdscr.refresh()

        if self.state.edit_mode:
            self._draw_edit_popup()

    def _draw_edit_popup(self):
        h, w = self.stdscr.getmaxyx()
        box_w = min(80, w - 4)
        box_h = 5
        box_y = max(1, (h - box_h) // 2)
        box_x = max(2, (w - box_w) // 2)
        bg = self._bg_pair()
        for by in range(box_y, box_y + box_h):
            self.stdscr.addstr(by, box_x, ' ' * box_w, bg)
        for bx in range(box_x, box_x + box_w):
            self.stdscr.addch(box_y, bx, ord(' '), curses.A_REVERSE)
            self.stdscr.addch(box_y + box_h - 1, bx, ord(' '), curses.A_REVERSE)
        for by in range(box_y, box_y + box_h):
            self.stdscr.addch(by, box_x, ord(' '), curses.A_REVERSE)
            self.stdscr.addch(by, box_x + box_w - 1, ord(' '), curses.A_REVERSE)
        prompt = 'Enter value and press Enter to confirm'
        self.stdscr.addstr(box_y + 1, box_x + 2, prompt)
        self.stdscr.addstr(box_y + 2, box_x + 2, self.state.input_buffer[: box_w - 4], curses.A_BOLD)
        self.stdscr.refresh()

    def handle_input(self):
        ch = self.stdscr.getch()
        if ch == -1:
            return None
        total_items = len(self.fields_order) + len(self.toggle_order) + 1
        if ch in (ord('t'), ord('T')) and not self.state.edit_mode:
            self.state.theme_dark = not self.state.theme_dark
            return None
        if ch in (ord('q'), 27) and not self.state.edit_mode:
            if self._confirm_quit():
                return 'quit'
            return None
        if ch in (curses.KEY_F5, ord('s')) and not self.state.edit_mode:
            # Require Product Serial Number before starting
            if not self.state.env.get('SERIAL_NUMBER'):
                self.state.message = 'Product Serial Number is required.'
                # Focus the SERIAL_NUMBER field and open edit mode with best-guess prefill
                try:
                    idx_sn = [k for k, _ in self.fields_order].index('SERIAL_NUMBER')
                    self.state.field_index = idx_sn
                    self.state.input_buffer = detect_serial() or ''
                    self.state.edit_mode = True
                except ValueError:
                    pass
                return None
            return 'start'
        if ch in (curses.KEY_UP, ord('k')) and not self.state.edit_mode:
            self.state.field_index = (self.state.field_index - 1) % total_items
            return None
        if ch in (curses.KEY_DOWN, ord('j')) and not self.state.edit_mode:
            self.state.field_index = (self.state.field_index + 1) % total_items
            return None
        if ch in (curses.KEY_LEFT, curses.KEY_RIGHT) and not self.state.edit_mode:
            if self.state.field_index >= len(self.fields_order):
                i = self.state.field_index - len(self.fields_order)
                key = self.toggle_order[i][0]
                self.state.flags[key] = not self.state.flags[key]
            return None
        if ch in (curses.KEY_ENTER, 10, 13) and not self.state.edit_mode:
            if self.state.field_index == len(self.fields_order) + len(self.toggle_order):
                if not self.state.env.get('SERIAL_NUMBER'):
                    self.state.message = 'Product Serial Number is required.'
                    try:
                        idx_sn = [k for k, _ in self.fields_order].index('SERIAL_NUMBER')
                        self.state.field_index = idx_sn
                        self.state.input_buffer = detect_serial() or ''
                        self.state.edit_mode = True
                    except ValueError:
                        pass
                    return None
                return 'start'
            key = self.fields_order[self.state.field_index][0]
            self.state.input_buffer = str(self.state.env.get(key, ''))
            self.state.edit_mode = True
            return None
        if self.state.edit_mode:
            if ch in (27,):
                self.state.edit_mode = False
                return None
            if ch in (10, 13):
                key = self.fields_order[self.state.field_index][0]
                self.state.env[key] = self.state.input_buffer
                self.state.edit_mode = False
                return None
            if ch in (curses.KEY_BACKSPACE, 127, 8):
                self.state.input_buffer = self.state.input_buffer[:-1]
                return None
            if 32 <= ch <= 126:
                self.state.input_buffer += chr(ch)
                return None
        return None

    def _confirm_quit(self) -> bool:
        if self.state.proc and self.state.proc.poll() is None:
            h, w = self.stdscr.getmaxyx()
            msg = 'A job is still running. Quit anyway? (y/N)'
            self.stdscr.addstr(h-2, max(0, (w - len(msg)) // 2), msg, curses.A_BOLD)
            self.stdscr.refresh()
            ch = self.stdscr.getch()
            return ch in (ord('y'), ord('Y'))
        return True

    def start_job(self):
        st = self.state
        # Final guard: Serial Number is mandatory
        if not st.env.get('SERIAL_NUMBER'):
            st.set_mode('neutral', 'Product Serial Number is required.')
            st.log('Refusing to start: missing SERIAL_NUMBER')
            return
        env = os.environ.copy()
        env.update(st.env)
        for k, v in st.flags.items():
            env[k] = '1' if v else '0'
        args = [SCRIPT_PATH]
        args.append('--enable-rs232-test' if st.flags['ENABLE_RS232_TEST'] else '--disable-rs232-test')
        if st.flags['NO_UPDATE']: args.append('--no-update')
        if st.flags['NO_TIMESHIFT']: args.append('--no-timeshift')
        if st.flags['CLEAR_LOGS']: args.append('--clear-logs')
        if st.flags['NO_NEXSOFT_BKP']: args.append('--no-nexSoft-bkp')
        args.append('--remove-static-ip-service' if st.flags['REMOVE_STATIC_IP_SERVICE'] else '--keep-static-ip-service')
        args.append('--enable-secondary-ip-service' if st.flags['ENABLE_SECONDARY_IP_SERVICE'] else '--disable-secondary-ip-service')
        if st.flags['OVERWRITE_IDS']: args.append('--overwrite-ids')
        if st.flags['NON_INTERACTIVE']: args.append('--non-interactive')

        st.set_mode('work', 'Running…')
        st.log('Starting updater…')

        def _run():
            try:
                self.state.proc = subprocess.Popen(
                    args, env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True,
                )
                assert self.state.proc.stdout is not None
                for line in self.state.proc.stdout:
                    self.state.log(line.rstrip('\n'))
                rc = self.state.proc.wait()
                if rc == 0:
                    st.set_mode('ok', 'Completed successfully')
                    st.log('Job finished: OK')
                else:
                    st.set_mode('neutral', f'Finished with errors (rc={rc})')
                    st.log(f'Job finished: ERR rc={rc}')
            except FileNotFoundError:
                st.set_mode('neutral', 'Shell script not found. Check SCRIPT_PATH.')
                st.log(f'ERROR: {SCRIPT_PATH} not found')
            except Exception as e:
                st.set_mode('neutral', f'Exception: {e}')
                st.log(f'Exception: {e}')
        threading.Thread(target=_run, daemon=True).start()

def run():
    state = UIState()
    def _main(stdscr):
        ui = TUI(stdscr, state)
        while True:
            ui.draw()
            action = ui.handle_input()
            if action == 'quit':
                break
            if action == 'start' and (state.proc is None or state.proc.poll() is not None):
                ui.start_job()
    curses.wrapper(_main)

if __name__ == '__main__':
    run()